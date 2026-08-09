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

Both are tuned from **one** reader's log. Treat the thresholds as hardware-specific
until someone else confirms them.

## How debug.sh works

Writes `/tmp/goodix-fp-debug.log` and echoes it between BEGIN/END markers so the user
can paste one block. Sections: system, reader on the USB bus, installed state, the
52XD PSK patch, OpenSSL, fprintd, read-only firmware probe, a libfprint enroll capture
with `G_MESSAGES_DEBUG=all`, a goodix-fp-dump control test, and the installer log tail.
Flags: `-o/--out`, `-t/--timeout` (default 45), `--no-capture`, `--no-print`, `-h`, `-V`.

Two invariants that must survive edits:

- **`guard()` wraps every section.** Under `set -Eeuo pipefail` any section returning
  non-zero would kill the run before the report printed — that bug shipped once in
  v1.0.0 (a trailing `[[ -n "$x" ]] && info …` returning 1). Never end a collector
  function on a bare test; use explicit `if`/`else` and `return 0`.
- **The control test refuses to run unless firmware is already the target and the PSK
  patch is present.** A diagnostic run must never risk a reflash.

`fprintd` is stopped and masked for the duration and restored by a
`trap on_exit EXIT INT TERM`.

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

- **`Failed to detect minutiae: No minutiae found`** recurs in the fprintd journal.
  NBIS coping badly with 64×80 images. Intermittent, not fatal — enrollment succeeds.
- **SIGFM** (`goodix-fp-linux-dev/sigfm`) is the right answer to that: a SIFT matcher
  written specifically for 64×80 sensors. **Not usable today** — no published branch
  combines `libfprint/sigfm/` with the goodixtls 52xd driver. The org's `sigfm`
  branches carry only `goodixmoc`; its `goodixtls` branch carries only `goodix511`.
  Repo last pushed 2022-11-13. A port means grafting `libfprint/sigfm/` into djnz00's
  fork, adding `opencv4 >= 4.5.0` + `doctest` to meson *and* to install.sh's per-distro
  dep lists, and forward-porting ~59 refs across `fpi-print.c` (21), `fp-image.c` (26),
  `fp-print.c` (12) from 1.94.5 → 1.94.10. It also changes the stored print format
  (SIFT descriptors vs NBIS minutiae), invalidating existing enrollments.
  Gate on evidence: only worth it if `fprintd-verify` shows frequent false rejects.
- **Both patched bugs are upstream bugs** in `djnz00/libfprint` (missing 10019 PSK;
  unreachable `5100` threshold) and are worth reporting there. Not yet filed.
- v1.0.4 has **not** been confirmed on hardware yet.
