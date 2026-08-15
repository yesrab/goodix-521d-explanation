# goodix-521d-explanation

Makes Goodix `27c6:*` fingerprint readers (primarily the **521d**) work on Linux.
The repo is two shell scripts plus the original manual guide.

| File | What it is |
| --- | --- |
| `install.sh` | The deliverable. One-shot automated installer, currently **v1.4.0**. |
| `debug.sh` | One-shot diagnostic collector, currently **v1.3.0**. Read-only. |
| `readme.md` | User-facing docs: automated path first, original manual guide below. |
| `patches/` | `sigfm-libfprint-1.94.10.patch`, applied only by `--sigfm`. |
| `tests/` | `run-pipeline-test.sh` + `test_pipeline.c` — see "Testing" below. |
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

3. **`patch_libfprint_52xd_background()`** → `drivers/goodixtls/goodix52xd.c`.
   The root-cause fix for the false accepts, added in v1.2.0. Subtracts an idle
   frame from every capture before the contrast stretch. Details in
   "The false-accept problem" below. Knobs:
   `GOODIX_KEEP_STOCK_IMAGE_PIPELINE=1` opts out entirely,
   `GOODIX_52XD_STRETCH_CLIP_PERMILLE` (default 20) sets how far into the
   histogram's tails the black and white points are taken.
   Guard: `grep -q '52xd-background'`.

   Design points worth not re-litigating:
   - The background is **not** freed in `goodix52xd_reset_state()`, which runs
     on every deactivate. fprintd deactivates between operations and a verify
     is a single scan that starts with the finger already coming down, so a
     verify would never see an idle frame of its own — and a template enrolled
     with subtraction cannot match a verify captured without it. It is freed in
     `dev_deinit()` (img_close) and `finalize()` only.
   - Idle frames are folded in with a **per-pixel maximum**, not "last one
     wins". `goodix52xd_frame_is_empty()` is a heuristic and a light touch can
     slip past it; a finger only pulls readings down, so max ignores those. The
     window restarts after each capture (`background_used`) so the estimate
     follows sensor drift instead of latching.
   - With no background yet, output is **byte-identical** to the stock
     pipeline. `tests/` asserts this.

4. **`patch_libfprint_52xd_bz3()`** → `drivers/goodixtls/goodix52xd.c`.
   The driver sets `bz3_threshold = 24` (libfprint's own default is 40) and
   unrelated fingers cleared it — a confirmed false-accept on real hardware.
   Raised to 40 so it fails closed. `GOODIX_BZ3_THRESHOLD=<n>` overrides.
   Guard: `grep -q 'bz3-threshold'` — note the PSK patch also writes the string
   `goodix-fp-setup` into this same file, so the guards must stay distinct.

Patches 2 and 4 are tuned from **one** reader. Treat the values as
hardware-specific until someone else confirms them.

### The false-accept problem

A finger that was never enrolled verifies successfully. The threshold was only
half of it — the root cause is the image the driver produces:

- `goodix52xd_image_from_frame()` takes **one** raw 64×80 frame,
  `squash_frame_linear()` stretches its own min/max to 0–255, and it is
  nearest-neighbour doubled to 128×160. That is the entire image pipeline.
- No calibration/background frame was subtracted. The 52XD driver has no
  `empty_img` field at all, whereas `goodix511` has one, captures
  `GOODIX511_CAP_FRAMES 40` frames per scan, and runs
  `fpi_do_movement_estimation()` + `fpi_assemble_frames()` over them.
- `self->frames` exists on the 52XD device struct but is only ever freed —
  dead code, no accumulation.
- Consequence: NBIS extracts few minutiae (hence `No minutiae found` in the
  journal) and those it finds are partly the sensor's fixed pattern, which is
  the same for every finger. So any two prints score alike. Under `--sigfm` the
  same cause shows up as enroll failing with `Not enough keypoints found`.

**v1.2.0 subtracts a background frame** (`patch_libfprint_52xd_background()`).
The driver already polls frames while waiting for a finger and discards the
empty ones — those *are* calibration frames, so this costs no extra USB
traffic and needs no SSM changes. Reference implementation is the org's
`goodix5xx.c` (`linear_subtract_inplace`, called from `scan_on_read_img`
after a dedicated `SCAN_STAGE_CALIBRATE`); ours differs in taking the frames
opportunistically rather than adding a state.

Signal is `background - frame` (a finger presses the reading down), written
back inverted so `squash_frame_linear()` still yields dark ridges. Note the
org's version has an unsigned wrap bug there — `max - ((max - src) - (max -
by))` goes badly when `src > by`; ours clamps.

**Unverified on hardware.** Still not done, in rough order of expected value:
pick the best of several frames after finger-down instead of the first
non-empty one (`self->frames` is already there for it, but it needs SSM work
and the poll loop's behaviour with a finger down is unknown); prime a
background during activation so the very first scan after `img_open` has one
(today it falls back to the stock pipeline and logs `no Goodix 52xd background
frame yet`); stitching.

### Testing

`tests/run-pipeline-test.sh` is the only automated check in the repo. It clones
the pinned libfprint fork, sources `install.sh` with `main` neutered, runs
`patch_libfprint_52xd_background()` against the tree, slices the patched
pipeline back out of the driver, and compiles `tests/test_pipeline.c` over it —
so it tests the shipped code, not a copy. Covers idempotency across
`git checkout --force`, both env knobs, and the pipeline's numerics including
the byte-identity property when no background is available.

Runs on macOS (needs git, python3, a C compiler, glib-2.0). **Add to it rather
than writing a throwaway harness** — the previous three (`scratchpad/check.sh`,
`port.py`, `idem.sh`, all referenced below) were never committed and are gone.

## How debug.sh works

Writes `/tmp/goodix-fp-debug.log` and echoes it between BEGIN/END markers so the user
can paste one block. Sections: system, reader on the USB bus, installed state, the
52XD PSK patch, the 52XD image pipeline, the matcher in use, OpenSSL, fprintd,
read-only firmware probe, a libfprint enroll capture with `G_MESSAGES_DEBUG=all`,
frame statistics, a goodix-fp-dump control test, and the installer log tail.
Flags: `-o/--out`, `-t/--timeout` (default 45), `--no-capture`, `--no-print`, `-h`, `-V`.

Both capture modes set `GOODIX52XD_DUMP_DIR=/tmp/goodix-fp-frames`
(`GOODIX_DEBUG_FRAME_DIR` overrides) and `GOODIX52XD_DUMP_RAW=1`, so the driver
writes every frame it decoded as a 16-bit big-endian P5 PGM with maxval 4095.
`summarise_frames()` puts min/max/mean/high-pixels and an idle-vs-FINGER verdict
per frame into the report — **the frames themselves deliberately stay out of it**,
because the report is meant to be pasted in public and they are fingerprint
images. The report tells the user how to tar them up or delete them.

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

**Do not trust the `.rej` files to tell you what did *not* apply.** `fp-image.c`
has **six** hunks and the sixth — the public `fp_image_get_sigfm_info()` /
`fp_image_extract_sigfm_info()` definitions — lands cleanly on 1.94.10 while the
other five reject. Reading only the reject and re-adding those two functions
produced `error: redefinition of 'fp_image_get_sigfm_info'` on the first real
build. Count hunks (`grep -c '^@@'` over that file's slice of the patch) against
rejects before assuming a file is untouched.

**Local compile check.** `scratchpad/check.sh` syntax-checks all six patched C
files **including `drivers/goodixtls/goodix52xd.c`** plus `sigfm.cpp`, with
Ubuntu's flags (`-std=gnu99 -Wall -Werror=implicit …`). It works because
`mkenums.py` fakes meson's `gnome.mkenums_simple()` output and
`stub/{config.h,gusb.h,gusb/gusb-device.h}` stand in for the Linux-only pieces;
`fpi-image.c` is excluded since the port does not touch it and it needs pixman.
Run it after any change — it catches redefinitions, missing declarations and
enum mismatches, which is most of what goes wrong here. It does **not** check
linking.

**Idempotency: guard on tracked files only.** `sync_repo()` runs
`git checkout --force`, which reverts tracked changes but leaves the *untracked*
`libfprint/sigfm/` behind. `apply_sigfm_patch()` originally keyed its
already-applied check off that directory, so a second run skipped the patch while
the core hooks had been reverted — the build then failed with
`FpImageDeviceClass has no member named 'algorithm'`. It now requires both a
tracked marker (`FPI_DEVICE_ALGO_SIGFM` in `fpi-image-device.h`) *and* the
directory, and resets to pristine if only one is present. `scratchpad/idem.sh`
exercises all four states (pristine, already-applied, and both half-applied
directions).

**Verification status.** libfprint as a whole cannot be built on this machine
(gudev/udev). What *is* checked: the patch applies clean to pristine 1.94.10 and
the result passes `check.sh`; `sigfm.cpp` compiles clean against OpenCV 5.0 (its
API use is stable 4.5→5.0); all 7 `sigfm_*` functions are declared, defined and
`extern "C"`; the install-time patches are idempotent.

**Hardware result (2026-08-15, user's 521d):** it builds, installs, and fprintd
starts — but **enrolling fails**. No logs captured. Near-certain cause:
`fp_image_extract_sigfm_info()` errors with `Not enough keypoints found: N of
25`, because the pre-1.2.0 image is mostly fixed pattern and SIFT has nothing
to key on. `fpi_image_device_minutiae_detected()` turns any non-cancel error
into `FP_DEVICE_RETRY_GENERAL`, so `priv->enroll_stage` never advances and
enroll spins until it gives up — it does not surface the real message.
Retry `--sigfm` on top of v1.2.0's background subtraction before touching
`GOODIX_SIGFM_MIN_KEYPOINTS`; lowering the gate past a genuinely featureless
image just stores a print that matches anybody.

The `< 25` gate is upstream's, not ours — `fp-image.c:319` on the org's `sigfm`
branch has the same constant hardcoded. Our patch only made it a
`-DSIGFM_MIN_KEYPOINTS` define.

## Hardware session, 2026-08-15 (Mint 22.3 live, real 27c6:521d over SSH)

First time any of this ran on the device. Everything below is measured, not
inferred. Frames and prints are gone (live boot), the findings are not.

**The reader was not usable at all at first, for a reason nothing predicted.**
Activation died at `Unsupported device PSK hash`. The unit was on stock
`GFUSB_GM168SEC_APP_10034` whose PSK hash is
`4ad0df80af65fe22b1491b7cd726dab503162626b21fa35a33bc5835f012a86d` — neither
sha256(32 zero bytes) (the 10019 value) nor djnz00's embedded 10034 hash
(`8b20e9bf…`). It is an OEM key, and a hash is one-way. `goodix-fp-fix
--force-flash` to 10019 fixed it (`Valid PSK: True`).

**install.sh bug this exposed, still unfixed:** `device_table()`'s `EXTRA_FW`
accepts 10034 on the firmware *string* alone. The driver additionally requires
the PSK hash to match, so the installer happily skips the flash and leaves a
reader that cannot activate. The probe must compare the PSK hash too, and
`--force-flash` should not be needed for this. Second, smaller bug: running
`install.sh` from `$STATE_DIR` makes the self-copy step do
`install foo foo` → `are the same file` → exit 1 after the work is done.

**Measured, NBIS with background subtraction (v1.2.0):** enrol 5/5, verify
`verify-match` **score 74/40**. No `No minutiae found` anywhere — the
subtraction did what it was meant to. But an unrelated finger scored **91**,
*higher* than the enrolled one. Threshold tuning cannot fix that ordering.

**Four more defects in the SIGFM port, all found on hardware, all now fixed**
(numbering continues from the four in "The SIGFM port"):
5. `fp_image_extract_sigfm_info()` set no GTask source tag, so the shared
   callback ran `fp_image_detect_minutiae_finish()`, whose
   `g_return_val_if_fail` on the tag returns FALSE **without setting `error`** —
   and the caller then reads `error->message`. **SIGSEGV on the first scan.**
   Fixed with a tagged task, a matching `fp_image_extract_sigfm_info_finish()`,
   and a NULL-error guard at the call site.
6. `fpi_print_add_from_image()` put the *image's* `sigfm_info` into
   `print->prints` without transferring ownership. That array frees elements
   with `sigfm_free_info` and so does `fp_image_finalize` (defect 2's leak fix),
   so **double free** — `SIGSEGV in free()` under `fp_print_finalize`, visible
   in `coredumpctl`. Fixed with `fp_image_steal_sigfm_info()`.
7. `fp-image-device.c` hardcoded `fpi_print_set_type (enroll_print,
   FPI_PRINT_NBIS)`. Every SIGFM stage then failed
   `fpi_print_add_print`'s `add->type == print->type` assertion, and enrolment
   stored a **52-byte print with an empty payload**; verify answered
   `Cannot call sigfm match with non-sigfm print data, type was 2`. Now follows
   `priv->algorithm`. A correct SIGFM enrolment stores ~440 KB.
8. (not a defect, a symptom) SIGFM's `< 25` keypoint gate is upstream's own
   (`fp-image.c` on the org's `sigfm` branch), not ours. Pre-v1.2.0 images gave
   ~fewer than that, which is why `--sigfm` could not enrol at all. With
   background subtraction it is 180–220, and with border repair 280–340.

**Where it actually stands: the captures are not reproducible press to press.**
This is the finding that matters, and it is measured, not guessed. Scoring the
driver's own assembled images against each other with `sigfm_match_score`:

| | self-match | different press, same finger |
| --- | --- | --- |
| ratio-test keypoint pairs | 190–340 | **0–26 of ~200** |
| score | 2.4M–5.3M | 0–2000, frequently exactly 0 |

Serialization is not the culprit — a round trip through
`sigfm_serialize_binary`/`deserialize_binary` preserves all 468 keypoints and
reproduces the score exactly. The images themselves do not repeat.

**Why, in the sensor's own numbers:**
- The idle frame is **saturated**: 279 of 279 idle frames had mean 3852–3904
  with 4836/5120 pixels over 2800, i.e. railed near the 12-bit ceiling. A
  clipped background carries no per-pixel gain information, so subtracting it
  removes an offset and little else. Finger frames run 1388–3680, in the
  linear range. Calibrating against a saturated reference is the core
  limitation of the current approach.
- Odd/even column split is **-3.9 counts on an idle frame** but **-142 on a
  finger frame** — the readout artifact scales with signal, so it is a gain
  effect that additive subtraction cannot touch.
- There is a 1-pixel dead border (cols 0/63, rows 0/79, ~600 against a ~4000
  interior). v1.3.0's `goodix52xd_repair_border()` handles this one.

**Post-processing does not rescue it.** Replaying real frames through
destriping (per-column and per-row mean removal) and then local contrast
normalisation raised keypoints 193 → 280 → 335 and left cross-press agreement
at 0–15 pairs. More keypoints, none of them reproducible.

**Multi-frame averaging helped, and is implemented in v1.4.0.** Presses run
3–7 frames and the driver used only the first; it now averages
`GOODIX52XD_CAPTURE_FRAMES` (default 4) of them. Offline this took cross-press
keypoint agreement from 1–26 pairs (with many exact zeros) to 5–30 (no zeros).
On hardware it is the difference between SIGFM **never** matching and SIGFM
matching: before averaging every genuine verify scored 0 against every stored
template; after it, genuine verifies score in the hundreds.

**And then the measurement that settles it.** 18 attempts on the real reader,
SIGFM with background subtraction, border repair and 4-frame averaging:

| | scores |
| --- | --- |
| genuine (right index, enrolled) | 37, 87, 108, 154, 220, 302, 330, 513, 521, 607 |
| impostor (left thumb / other) | 0, 0, 0, 0, 10, 88, 175, 838 |

They overlap, and not narrowly:

| threshold | false reject | false accept |
| --- | --- | --- |
| 40 (the shipped default) | 10% | **38%** |
| 200 | 40% | **12%** |
| 600 | 90% | **12%** |
| 900 | 100% | 0% |

There is no usable threshold. The impostor at 838 was **confirmed by the
operator as a right ring/middle finger that slipped during the press** — a
different finger, not a mis-press of the enrolled one, so it counts. It had a
perfectly ordinary 210 keypoints, and it beat every genuine attempt. The
default is now 250 so it fails closed rather than open, and the installer says
so out loud.

That it was a *slipped* press is a lead rather than an excuse. A finger moving
across the sensor smears ridges into long streaks, and long streaks generate a
lot of collinear keypoint pairs — exactly what a matcher counting agreeing
pair geometries rewards. The five clean, deliberate left-thumb presses topped
out at 88; the one that slipped scored 838. Worth testing whether motion during
a press is what produces the high impostor scores, and whether rejecting it
fixes the overlap: the four frames of a press are already in hand, so the
frame-to-frame difference is free to compute and a press that moves too much
could be rejected outright rather than averaged into a smear.

**Why it still fails, most likely:** `sigfm_match_score()` returns a raw count
of agreeing keypoint-pair geometries. It is not normalised by how many
keypoints or matches went in, so it scales with the size of the match set
rather than with similarity — which is exactly the property that lets an
unrelated pair with many keypoints outscore a genuine pair with few. Dividing
by the number of candidate pairs (a *fraction* consistent, not a count) is the
obvious next experiment and can be tried offline against stored frames.

**Do not tell anyone this reader is safe for login.** NBIS demonstrably
false-accepts on this unit; SIGFM has not been shown to separate fingers at
all.

### Working on the hardware

Mint live at `mint@192.168.1.218` (password `mint99`, sudo passwordless).
Live boot: everything under `/opt` and `/tmp` is RAM and vanishes on reboot,
including the firmware-independent state — but the **firmware flash persists**,
so a reflashed reader stays reflashed.

- fprintd has `PrivateTmp=yes`, so `GOODIX52XD_DUMP_DIR=/tmp/...` lands in
  `/tmp/systemd-private-*-fprintd.service-*/tmp/...`, and **restarting fprintd
  gets a new private tmp and drops the old frames**. Copy them out first.
- fprintd needs an active local seat; over SSH polkit denies everything. A rule
  in `/etc/polkit-1/rules.d/` returning `polkit.Result.YES` for
  `net.reactivated.fprint.*` is enough for testing. Remove it afterwards.
- Prints live in `/var/lib/fprint/<user>/<driver>/<dev>/<finger>`, **not** under
  `~/.local/share`. Clearing the wrong one wastes an enrolment cycle.
- `pkill -f fprintd-enroll` over SSH matches the ssh command line itself and
  kills the session. Use `pkill -x`.
- The examples (`build-goodix/examples/{enroll,verify}`) exit during deactivate
  without saving a print. Drive fprintd instead; it stores properly.
- `coredumpctl debug --debugger-arguments="-batch -ex bt"` gets a backtrace and
  is far faster than reasoning about which pointer died.

## Upstream ecosystem (from the Discord `#github` export, 2021-07 → 2026-08)

The export is a GitHub webhook feed, not conversation: 1198 messages, 1194 of
them bot notifications. Useful as a commit/PR/issue index. It is **not
committed** — it was dropped into the working tree locally, and publishing a
Discord export is the user's call, not ours. Everything load-bearing from it is
summarised here.
`goodix-fp-dump` and `libfprint` are still getting PRs in 2026, but a
maintainer said in April 2026 that *"there isn't any work being done on this
whole project at this moment ... the lead maintainer"* is absent, so PRs sit
open.

Facts worth carrying:

- **Nobody upstream has a 52XD driver.** `goodix-fp-linux-dev/libfprint`
  branches (`master`, `goodixtls`, `sigfm`, `buildpackage`, two wip sigfm
  branches) carry `goodix511` and `goodix5xx` only. The 521d driver exists in
  exactly two places: `djnz00/libfprint` (1.94.10, our default) and
  `infinytum/libfprint@unstable` (1.94.1, our `--legacy-driver`).
- **The whole ecosystem converged on the same two fixes we needed**: background
  subtraction and SIGFM instead of NBIS. `goodix-fp-dump` PR #33 (2023),
  libfprint PRs #34 (5e0a), #36 (5f10), #37 (511, 2026-06) — #37's root-cause
  paragraph is our symptom verbatim: *"enrollment completes successfully but
  `fprintd-verify` always returns `verify-no-match` ... NBIS performs poorly on
  the sensor's low-resolution 80×64 images."*
- **PR #34 is the closest analogue to the 521d.** 27c6:5e0a, firmware
  `GFUSB_GM168SEC_APP_10034` — the *same* firmware family string as 521d — with
  dual TLS-PSK and SIGFM. Its commit log walks the exact arc we are on:
  `Debug minutiae: enrollment 3.1 avg minutiae, verify 0-1, score always 0/5` →
  `SIGFM integrated, calibration disabled` → `WORKING: enrollment 20/20,
  verify-match on first attempt!`. Worth reading before the next iteration.
  Caveat: several of these 2026 PRs are self-described as vibe-coded, and #34
  is unreviewable by its own maintainer's admission.
- **PR #37 also carries two build fixes** we may want: `dependency('udev')` →
  `dependency('libudev')` in `meson.build` (Debian pkg-config name), and making
  `doctest` optional in `libfprint/sigfm/meson.build`. Our patch already drops
  doctest and `tests.cpp` entirely, so only the udev one might matter.
- **The AUR package gives Arch users nothing we do not build.**
  `libfprint-goodix-521d` is `infinytum/libfprint@unstable` (1.94.1) built with
  plain `arch-meson`, `conflicts=(libfprint)`, installed system-wide as a
  replacement — i.e. exactly our `--legacy-driver`, minus every patch, and with
  a *worse* scoping story than our fprintd-only `LD_LIBRARY_PATH` drop-in. It
  is at pkgrel 9, last touched 2024-12-29, 2 votes. There is no newer or better
  Goodix 521d package on the AUR. Nothing to port from it. (Its one real trick,
  `-Wno-incompatible-pointer-types`, install.sh already applies.)
- Recurring user-facing issues to recognise: `ValueError: Invalid OTP` on
  `run_521d.py` (issues #16, #41, #44 — PR #68 claims `read_otp()` asks for 0
  bytes and should ask for 0x40, but its own author then reported still
  authenticating with other fingers); `ModuleNotFoundError` from running
  `sudo python` outside the venv; `ConnectionRefusedError` from racing
  `openssl s_server` startup.

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

Ordered by what the hardware session showed actually matters.

- **Fix the `EXTRA_FW` PSK check in install.sh.** Highest priority: it is the
  difference between "reader works" and "reader cannot activate", it bit a real
  user, and the diagnosis is already written down under "Hardware session".
  The probe must compare the device's PSK hash against the driver's table, not
  just the firmware string, and flash when it does not match.
- **Reject presses where the finger moved.** The single false accept that
  defeats every threshold was a confirmed slipped press. The frames of a press
  are already accumulated, so the mean absolute difference between consecutive
  frames costs nothing; above some threshold the press is a smear and should be
  reported as a retry rather than averaged. Needs a measurement of what a
  still press versus a moving one actually looks like numerically — dump frames
  with `GOODIX52XD_DUMP_DIR` while deliberately sliding a finger.
- **Normalise the SIGFM score.** The other promising lead.
  `sigfm_match_score()` counts agreeing keypoint-pair geometries without
  dividing by how many pairs were considered, so it rewards large match sets
  rather than similar ones. That is consistent with the one impostor that
  outscored every genuine attempt. Returning a fraction instead of a count can
  be tested entirely offline against dumped frames with the harness described
  under "Working on the hardware".
- **The saturated background is the deeper problem.** Calibrating against a
  railed reference cannot remove a gain artifact. Worth investigating whether
  the MCU config / OTP DAC values can bias the idle level into the linear
  range, which is presumably what the Windows driver does. This is real
  reverse-engineering, not a patch.
- **Fix the `install foo foo` exit 1** when install.sh runs from `$STATE_DIR`.
  Cosmetic, but it makes a successful run look like a failure.
- **Four upstream bugs** in `djnz00/libfprint` worth reporting, none filed: the
  missing 10019 PSK, the unreachable `5100` threshold, no background
  subtraction, and `bz3_threshold = 24` (the latter two shared with the 511 and
  53xd drivers). Plus the four SIGFM-port defects against
  `goodix-fp-linux-dev/libfprint@sigfm`, three of which are crashes.
- install.sh v1.3.0 is confirmed to **build, install and enrol** on hardware.
  It is **not** confirmed to match safely, and on the evidence it does not.
