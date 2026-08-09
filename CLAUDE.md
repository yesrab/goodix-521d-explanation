# goodix-521d-explanation

Makes Goodix `27c6:*` fingerprint readers (primarily the **521d**) work on Linux.
The repo is two shell scripts plus the original manual guide.

| File | What it is |
| --- | --- |
| `install.sh` | The deliverable. One-shot automated installer, currently **v1.0.4**. |
| `debug.sh` | One-shot diagnostic collector, currently **v1.0.1**. Read-only. |
| `readme.md` | User-facing docs: automated path first, original manual guide below. |
| `goodix-fp-dump/` | Submodule — the Python firmware flasher from the Goodix Linux Dev Discord. |
| `usbreset/` | The `usbreset.c` helper referenced by the manual guide. |

Both scripts are consumed as `curl … | sudo bash`, so **everything the user runs comes
from `main` on GitHub**, not from their disk.

## How install.sh works

Order of operations: detect distro → install deps → find the reader on USB (vendor
`27c6`) → read current firmware → flash only if needed → build patched libfprint into
a private prefix → point *only* fprintd at it via a systemd drop-in → restart and
verify over D-Bus, rolling back if fprintd won't start.

Key facts:

- Everything lands under `/opt/goodix-fp-setup` (`src/`, `venv/`, `bin/`, `libfprint/`).
  `--uninstall` removes it all. Log at `/var/log/goodix-fp-setup.log`.
- The distro's own libfprint is **never** touched. Scoping is via
  `/etc/systemd/system/fprintd.service.d/10-goodix-libfprint.conf` setting
  `LD_LIBRARY_PATH` for the fprintd unit alone.
- Default libfprint fork is [`djnz00/libfprint`](https://github.com/djnz00/libfprint)
  (1.94.10, accepts stock `10034` *and* downgraded `10019`).
  `--legacy-driver` builds `infinytum/libfprint@unstable` (1.94.1, `10019` only) —
  that's what the AUR `libfprint-goodix-521d` uses.
- `device_table()` maps PID → flasher script + expected firmware. 521d →
  `run_521d.py` / `driver_52xd` / target `GFUSB_GM168SEC_APP_10019`, with
  `GFUSB_GM168SEC_APP_10034` accepted as `EXTRA_FW` on the non-legacy driver.
- Python helpers (`gfp_flash.py`, `gfp_usb.py`) are embedded as heredocs in
  `write_helpers()` and written to `/opt/goodix-fp-setup/bin/`.
- The whole script is functions + a `main` call at the very bottom, so a truncated
  `curl` can't half-execute.

### The two libfprint patches

Applied in `build_libfprint()` before meson runs. `sync_repo()` does
`git checkout --force`, so both must be **idempotent and re-applied every run**.

1. **`patch_libfprint_52xd_psk()`** → `drivers/goodixtls/goodix52xd.c`.
   The fork ships the TLS pre-shared key for `10034` but returns `NULL` for `10019`,
   so a downgraded reader activates fine then dies at the handshake with
   `Goodix TLS PSK is not configured` → `enroll-unknown-error`.
   The missing PSK is **32 zero bytes**, confirmed two independent ways:
   `goodix-fp-dump`'s `driver_52xd.py` writes exactly that and feeds it to
   `openssl s_server -psk`, and its sha256 equals the driver's own
   `goodix_52xd_pmk_hash_10019`. Guard: `grep -q 'psk_10019'`.

2. **`patch_libfprint_52xd_finger_off()`** → `drivers/goodixtls/goodix52xd_proto.h`.
   `goodix52xd_frame_is_empty()` rule B wants `mean >= 4000 && high_pixels >= 5100`
   out of 64×80 = 5120 pixels. On real 521d units ~284 pixels never cross the high
   threshold, so `high_pixels` tops out at **4836** and the rule can never fire —
   finger-off is never detected and the reader appears to hang for tens of seconds
   (users report minutes) between enroll scans. Lowered to `3600` / `4500`.
   Verified by replaying 88 frames from a real capture: stock first matched at frame
   87, patched at frame 16; only the `mean 3874–3905 / high 4836` cluster
   reclassifies, and the nearest still-non-empty frame is `mean=3510 high=4189`
   (margins 90 and 311). Opt out with `GOODIX_KEEP_STOCK_EMPTY_THRESHOLDS=1`.
   Guard: `grep -q 'goodix-fp-setup'`.

3. **`patch_libfprint_52xd_bz3()`** → `drivers/goodixtls/goodix52xd.c`.
   The driver sets `bz3_threshold = 24` (libfprint's own default is 40) and
   unrelated fingers cleared it — a confirmed false-accept on real hardware.
   Raised to 40 so it fails closed. `GOODIX_BZ3_THRESHOLD=<n>` overrides.
   Guard: `grep -q 'bz3-threshold'` — note the PSK patch also writes the string
   `goodix-fp-setup` into this same file, so the guards must stay distinct.

Patches 2 and 3 are tuned from **one** reader. Treat the values as
hardware-specific until someone else confirms them.

### The false-accept problem (the important open issue)

A finger that was never enrolled verifies successfully. The threshold was only
half of it — the root cause is the image the driver produces:

- `goodix52xd_image_from_frame()` takes **one** raw 64×80 frame,
  `squash_frame_linear()` stretches its own min/max to 0–255, and it is
  nearest-neighbour doubled to 128×160. That is the entire image pipeline.
- No calibration/background frame is subtracted. The 52XD driver has no
  `empty_img` field at all, whereas `goodix511` has one, captures
  `GOODIX511_CAP_FRAMES 40` frames per scan, and runs
  `fpi_do_movement_estimation()` + `fpi_assemble_frames()` over them.
- `self->frames` exists on the 52XD device struct but is only ever freed —
  dead code, no accumulation.
- Consequence: NBIS extracts few minutiae (hence `No minutiae found` in the
  journal) and those it finds are partly the sensor's fixed pattern, which is
  the same for every finger. So any two prints score alike.

Raising the threshold cannot manufacture ridge detail. The real fixes, roughly
in order of effort: subtract a background frame (the last frame
`goodix52xd_frame_is_empty()` accepted while waiting *is* a background frame,
so this is tractable); pick the best of several frames after finger-down instead
of the first non-empty one; or port SIGFM. None are done.

## How debug.sh works

Writes `/tmp/goodix-fp-debug.log` and echoes it between BEGIN/END markers so the user
can paste one block. Sections: system, reader on the USB bus, installed state, the
52XD PSK patch, OpenSSL, fprintd, read-only firmware probe, a libfprint enroll capture
with `G_MESSAGES_DEBUG=all`, a goodix-fp-dump control test, and the installer log tail.
Flags: `-o/--out`, `-t/--timeout` (default 45), `--no-capture`, `--no-print`, `-h`, `-V`.

`--match-test` (v1.1.0) measures whether the matcher separates fingers at all:
enrol into a `mktemp -d`, then N verifies with the same finger and N with a
different one, recording each `score N/M` that `fpi_print_bz3_match()` logs. It
drives `$BUILD_DIR/examples/{enroll,verify}` rather than fprintd — no D-Bus, no
polkit, and the user's real enrollments are neither read nor written. Those
examples store to `test-storage.variant` in the **cwd** and write
`enrolled.pgm` / `verify.pgm`, which `render_pgm_ascii()` turns into ASCII so
the images land in the pasteable report. The driver can also dump frames
itself via `GOODIX52XD_DUMP_DIR` + `GOODIX52XD_DUMP_RAW=1`.

Three invariants that must survive edits:

- **`guard()` wraps every section.** Under `set -Eeuo pipefail` any section returning
  non-zero would kill the run before the report printed — that bug shipped once in
  v1.0.0 (a trailing `[[ -n "$x" ]] && info …` returning 1). Never end a collector
  function on a bare test; use explicit `if`/`else` and `return 0`.
- **The control test refuses to run unless firmware is already the target and the PSK
  patch is present.** A diagnostic run must never risk a reflash.
- **`--match-test` never claims safety from absent data.** If the user aborts, or
  no score is logged, it prints the partial numbers and no verdict. Only an
  unenrolled finger actually reaching the threshold produces the FAIL OPEN text.

`fprintd` is stopped and masked for the duration and restored by a
`trap on_exit EXIT INT TERM`.

## The SIGFM port

`patches/sigfm-libfprint-1.94.10.patch` (15 files, ~950 insertions) grafts SIGFM
onto djnz00's tree. Applied only by `--sigfm`; the default build is untouched.

**Provenance.** SIGFM's core comes from `goodix-fp-linux-dev/libfprint@sigfm`
(libfprint **1.94.5**). Extract the upstream diff with
`git diff v1.94.5 HEAD -- <files>` against the `v1.94.5` tag fetched from
`gitlab.freedesktop.org/libfprint/libfprint`. Do **not** blanket-diff the branch:
it also carries an unrelated `fp-device`/`fpi-device` refactor and a
`HAVE_PIXMAN` change that must not be taken. 7 of 9 core files apply cleanly to
1.94.10; `fp-image.c` and `fpi-image.h` reject on whitespace churn only.

**The patch is pinned** to `djnz00/libfprint@72cacc37ca6524390a112e7df7bf2c6972be8217`
because it is a rebase — `--sigfm` overrides `LIBFPRINT_REF` for that reason. If
djnz00 moves and you regenerate, the pin in install.sh must move with it.

**Architecture.** Opt-in per driver: `FpImageDeviceClass.algorithm`
(`FPI_DEVICE_ALGO_NBIS` / `_SIGFM`), defaulted to NBIS in
`fp_image_device_constructed()`. `fpi-image-device.c` branches to
`fp_image_extract_sigfm_info()` / `fpi_print_sigfm_match()`. Only goodix52xd is
switched over, by `patch_libfprint_52xd_sigfm()`. `bz3_threshold` is reused as
the SIGFM threshold, but SIGFM's score counts agreeing keypoint-pair geometries —
a different scale entirely, hence `GOODIX_SIGFM_THRESHOLD`.

**Four defects in the upstream branch are fixed in our patch** — worth knowing
about if you ever re-derive it:
1. `fp_print_serialize()` called `g_clear_object()` on a `GPtrArray`. Replaced
   with `g_autoptr(GPtrArray)` + `g_ptr_array_new_with_free_func (free)` —
   `free`, because `binary.hpp`'s `copy_buffer()` uses `malloc`.
2. `fp_image_finalize()` never freed `sigfm_info` — a leaked OpenCV `Mat` plus
   keypoint vector on every single scan.
3. Verify left `FpiMatchResult result` uninitialised when `algorithm` was
   neither value — unreachable now, but it decided an auth result.
4. The branch put `#include "sigfm/sigfm.hpp"` in the *installed* `fp-image.h`.
   Both new functions are internal, so they were moved to `fpi-image.h`; this
   also means `fpi-image-device.c` needs an explicit `#include "fpi-image.h"`.

**Regenerating.** `scratchpad/build-port.sh` + `port.py` rebuild it from clean:
clone both repos, apply `sigfm-core.patch` with `--reject`, then `port.py`
applies 13 anchored edits and fails loudly if any anchor is missing.

**Verification status.** No compiler on this machine can build libfprint
(needs gudev/udev). What *was* checked: the patch applies clean to pristine
1.94.10; the new SIGFM C block compiles with `-Wall -Wextra` against real glib
with stubbed libfprint types; `sigfm.cpp` compiles clean against OpenCV 5.0 (so
its API use is stable 4.5→5.0); all 7 `sigfm_*` functions are declared, defined
and `extern "C"`; all five install-time patches are idempotent across runs.
**Never compiled as a whole, never run.**

## Conventions

- Bash, `set -Eeuo pipefail`, functions only, `main` at the bottom.
- Output helpers: `step` / `info` / `ok` / `warn` / `err` / `dbg`. Colours disabled
  when not a TTY or `NO_COLOR` is set.
- Comments explain *why* (the evidence, the failure it prevents), not *what*.
- Bump `SCRIPT_VERSION` in the same commit as any behaviour change.
- Sources overridable via env (`GOODIX_FPDUMP_REPO/REF`, `GOODIX_LIBFPRINT_REPO/REF`,
  `GOODIX_SYSFS_USB`) so logic can be exercised against fakes.

## Working on this repo

- **Fixes must be committed and pushed**, not applied locally — the user runs from
  `raw.githubusercontent.com`.
- **GitHub's raw CDN caches ~5 minutes.** After pushing, hand the user a
  commit-pinned raw URL (`.../raw/<sha>/install.sh`) or they'll re-run the old
  version and you'll both chase a fixed bug. This already cost one round trip.
- The user tests on **Linux Mint 22.3**; this machine is macOS, so nothing here can be
  run end to end locally. Verify logic in harnesses / by replaying captured data.
- `install.sh` never shows goodix-fp-dump's anti-bot prompt — intentional, `auto_input`
  replaces `builtins.input`.

## Open items

- **False accepts are unresolved.** See "The false-accept problem" above. The
  threshold bump is a mitigation, not a fix. Waiting on `--match-test` numbers
  from the user's reader to know whether the score distributions overlap.
- **`--sigfm` is built but unverified on hardware.** See "The SIGFM port" below.
- **SIGFM background** (`goodix-fp-linux-dev/sigfm`): a SIFT matcher
  written specifically for 64×80 sensors. **Not usable today** — no published branch
  combines `libfprint/sigfm/` with the goodixtls 52xd driver. The org's `sigfm`
  branches carry only `goodixmoc`; its `goodixtls` branch carries only `goodix511`.
  Repo last pushed 2022-11-13. A port means grafting `libfprint/sigfm/` into djnz00's
  fork, adding `opencv4 >= 4.5.0` + `doctest` to meson *and* to install.sh's per-distro
  dep lists, and forward-porting ~59 refs across `fpi-print.c` (21), `fp-image.c` (26),
  `fp-print.c` (12) from 1.94.5 → 1.94.10. It also changes the stored print format
  (SIFT descriptors vs NBIS minutiae), invalidating existing enrollments.
  Gate on evidence: only worth it if `fprintd-verify` shows frequent false rejects.
- **Three upstream bugs** in `djnz00/libfprint` worth reporting, none filed: the
  missing 10019 PSK, the unreachable `5100` threshold, and the false accepts
  (single-frame image + no background subtraction + `bz3_threshold = 24`, which
  the 511 and 53xd drivers share).
- install.sh v1.0.5 / debug.sh v1.1.0 have **not** been confirmed on hardware.
  The finger-off fix in 1.0.4 was — scanning is fast now.
