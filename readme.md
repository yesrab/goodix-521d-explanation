## Please see the [Goodix Linux Development Discord](https://discord.gg/tqxCu3986U) for more information and help if you need it.

# Goodix 521d Configuration Instructions

## Automated install (any distro)

```sh
curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/install.sh | sudo bash
```

`install.sh` does the whole manual guide below for you, on Arch, Debian/Ubuntu, Fedora/RHEL and openSUSE:

1. Installs every build and runtime dependency using your distro's package manager.
2. Finds your reader on the USB bus and picks the matching `goodix-fp-dump` script itself — no need to know whether you have a 5110, a 521d or a 538d.
3. Reads the firmware that's actually on the reader and **only flashes if it has to**. Timeouts are retried automatically with a USB reset (the `usbreset.c` step below, done with the same ioctl).
4. Builds a patched libfprint into `/opt/goodix-fp-setup` and points *only* fprintd at it with a systemd drop-in, so your distro's own libfprint package is never touched or downgraded.
5. Installs fprintd, restarts it, and checks over D-Bus that the reader actually showed up. If fprintd can't start with the patched library it undoes the change automatically.

Useful flags (`... | sudo bash -s -- --flag`):

| Flag | What it does |
| --- | --- |
| `-y, --yes` | Don't prompt. Required if you have no terminal attached. |
| `--status` | Just report device, firmware and driver state. Changes nothing. |
| `--flash-only` / `--driver-only` | Run only one half of the process. |
| `--force-flash` | Downgrade even when the current firmware is already usable. |
| `--legacy-driver` | Build the older libfprint fork the AUR package uses (see below). |
| `--sigfm` | Match with SIGFM (SIFT) instead of NBIS. Experimental — see below. |
| `--pam` | Also enable fingerprint login through your distro's PAM tool. |
| `--uninstall` | Remove everything the script installed. |

Run `... \| sudo bash -s -- --help` for the full list. The log is at `/var/log/goodix-fp-setup.log`.

**Which libfprint does it build?** By default, [`djnz00/libfprint`](https://github.com/djnz00/libfprint) — libfprint 1.94.10, actively maintained, and it accepts the **stock** `GFUSB_GM168SEC_APP_10034` firmware as well as the downgraded `10019`. That means a 521d on stock firmware often needs no flashing at all. `--legacy-driver` switches to [`infinytum/libfprint`](https://github.com/infinytum/libfprint), which is what the AUR package `libfprint-goodix-521d` builds from — libfprint 1.94.1, last updated in 2021, and it only accepts `10019`.

Four patches are applied to that fork before building:

1. Its 52XD driver ships the TLS pre-shared key for `10034` but not for `10019`, so a reader on `10019` opens fine and then fails every enroll with `Goodix TLS PSK is not configured`. The `10019` key is 32 zero bytes — the value `goodix-fp-dump` writes to the sensor, and the one whose sha256 is the driver's own `goodix_52xd_pmk_hash_10019` — so the script puts it back.
2. Its "sensor is empty again" test can never match on some 521d units, which makes the reader appear to hang for tens of seconds between enroll scans. The saturated-frame rule wants `high_pixels >= 5100` out of 64×80 pixels, but ~284 of them never cross the threshold, so it tops out at 4836. The script lowers that cut to where the hardware actually separates. `GOODIX_KEEP_STOCK_EMPTY_THRESHOLDS=1` builds the stock values instead.
3. **Its captures have the sensor's own fixed pattern in them, and nothing removes it.** `goodix52xd_image_from_frame()` contrast-stretches a single raw frame; the idle sensor reads near saturation with a per-pixel offset that is several times larger than the ridge signal, so what reaches the matcher is mostly sensor and only slightly finger. The script subtracts an idle frame first. The driver already polls frames while waiting for a finger and throws the empty ones away — those *are* calibration frames, so this costs no extra traffic. `GOODIX_KEEP_STOCK_IMAGE_PIPELINE=1` builds the stock single-frame stretch instead.
4. Its 52XD driver sets the match threshold to 24, well under libfprint's own default of 40, so fingers that were never enrolled could clear it. The script raises it to 40. `GOODIX_BZ3_THRESHOLD=<n>` builds a different value. See the warning below.

Patch 3 is the same fix the rest of the ecosystem converged on independently: the sibling `goodix511` driver has always subtracted a calibration frame (`goodix5xx.c`, `linear_subtract_inplace`), `goodix-fp-dump` PR #33 added background subtraction because it was *"enough to make sigfm happy with 5395"*, and libfprint PR #37 added contrast normalisation to `goodix511` for the same reason.

### ⚠ This reader may accept the wrong finger

On at least one 521d, an enrolled finger and a completely different one both verified successfully. The root cause was the image, not the threshold: with no calibration frame subtracted, NBIS finds few real minutiae — you will see `Failed to detect minutiae: No minutiae found` in the fprintd journal — and what it does find comes partly from the sensor's fixed pattern, which is identical no matter whose finger is on it.

Patch 3 above addresses that directly, and patch 4 makes the reader fail closed rather than open in the meantime. **Neither has been confirmed on hardware yet, so test your own reader before trusting it with a login:**

```sh
curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/debug.sh | sudo bash -s -- --match-test
```

That enrolls a finger into a scratch directory, asks you to scan the same finger and then a different one, and prints the match score of every attempt alongside an ASCII rendering of each captured image. If a finger you never enrolled reaches the threshold, the report says so in as many words. Nothing is written to your account and the scratch directory is deleted on exit.

If the two groups of scores overlap, no threshold setting can separate them and the reader is not usable for authentication as things stand.

Both capture modes also leave the raw frames the driver decoded in `/tmp/goodix-fp-frames`, with per-frame statistics in the report. Those files are fingerprint images and are deliberately *not* included in the pasteable report — send them only if you mean to, and `sudo rm -rf /tmp/goodix-fp-frames` otherwise.

### `--sigfm`: the SIFT matcher

Raising the threshold only helps if NBIS can separate your fingers at all. When it can't, the problem is that NBIS wants minutiae — ridge endings and bifurcations — and a 64×80 frame barely has enough resolution to contain any. [SIGFM](https://github.com/goodix-fp-linux-dev/sigfm) exists for exactly this case: it matches SIFT keypoints instead, and its README says it is *"meant to work with 64x80 images"*.

```sh
curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/install.sh | sudo bash -s -- --driver-only --sigfm
```

**This is experimental and you should read the whole of this section before using it.**

- **No published branch shipped this for the 521d.** SIGFM lives on `goodix-fp-linux-dev/libfprint@sigfm`, which is libfprint 1.94.5 and whose only Goodix driver is `goodixmoc`; no branch there carries the 52XD driver at all. Open pull requests do combine SIGFM with `goodixtls` drivers ([#34](https://github.com/goodix-fp-linux-dev/libfprint/pull/34) for 5e0a, [#36](https://github.com/goodix-fp-linux-dev/libfprint/pull/36) for 5f10, [#37](https://github.com/goodix-fp-linux-dev/libfprint/pull/37) for 511), but none of them for 521d, and none are merged. `patches/sigfm-libfprint-1.94.10.patch` rebases SIGFM onto djnz00's 1.94.10 and wires the 52XD driver to it.
- **Enrolling can fail outright with `Not enough keypoints found`.** SIFT needs detail to key on, and until patch 3 above there was none: the fixed pattern is the same in every frame, so it produces no distinguishing keypoints. If you hit this, the image is the problem — lowering `GOODIX_SIGFM_MIN_KEYPOINTS` past it just stores a print that will match anybody.
- **Three defects in that branch's code are fixed in the patch**, all of which would bite immediately: serialising a print called `g_clear_object()` on a `GPtrArray`; every scan leaked its `SigfmImgInfo`; and verify could read an uninitialised match result. The patch also keeps `sigfm.hpp` out of the installed public headers, which upstream did not.
- **Needs OpenCV ≥ 4.5** development files — specifically the `opencv4` pkg-config module; OpenCV 5 ships `opencv5` and will not be found. `--sigfm` adds the right package for your distro automatically.
- **Existing enrollments stop working.** SIGFM stores SIFT descriptors where NBIS stored minutiae. Delete and re-enroll (`fprintd-delete $USER`, then `fprintd-enroll`). Going back to NBIS means re-enrolling again.
- **libfprint is pinned.** The patch is a rebase against one commit, so `--sigfm` ignores `GOODIX_LIBFPRINT_REF` and builds `djnz00/libfprint@72cacc37`.

Two numbers need tuning to your hardware, and the defaults are inherited guesses, not measurements:

| Variable | Default | Raise it if… | Lower it if… |
| --- | --- | --- | --- |
| `GOODIX_SIGFM_THRESHOLD` | 40 | a wrong finger still verifies | your own finger never verifies |
| `GOODIX_SIGFM_MIN_KEYPOINTS` | 25 | — | scans fail with `Not enough keypoints found` |

Measure before you change them — `debug.sh --match-test` prints every score, and under SIGFM those are `sigfm score N/M` lines on a completely different scale from bozorth3:

```sh
curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/debug.sh | sudo bash -s -- --match-test
```

Then rebuild with the threshold sitting in the gap between the two groups, e.g. `... | sudo GOODIX_SIGFM_THRESHOLD=120 bash -s -- --driver-only --sigfm`.

**Windows broke the reader again?** The script installs `goodix-fp-fix`; just run `sudo goodix-fp-fix`.

**Something not working?** `debug.sh` collects everything needed to diagnose it — device and firmware state, the built library, OpenSSL's security level, fprintd's journal, and two capture tests run against the reader with full driver debugging on. It changes nothing, and prints a report you can paste into an issue or the Discord.

```sh
curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/debug.sh | sudo bash
```

Add `--match-test` to measure whether the matcher can actually tell your fingers apart — see the warning above.

Everything is still experimental. Read the warning in the next section — it applies just as much to the automated path.

---

## Manual install

Tested on Arch and Manjaro. If you don't have access to the AUR, it's still possible to install this, you'll just need to build it by hand. Join the Discord if you need help.

### First Install
To download this repo: `git clone --recurse-submodules https://github.com/knauth/goodix-521d-explanation.git`

Follow this guide at your own risk. This software is experimental and not guaranteed to do anything. It might break stuff; I'm not responsible for that. Ensure you understand every command you run on your system before you execute it. **Don't use this in secure situations or as your only authentication method.**

You'll need all of the following things, which should be in this git repo:

- A simple C program to reset the reader
- The goodix-fp-dump folder provided by the good people at [Goodix Linux Development Discord](https://discord.gg/tqxCu3986U), with some modifications by [infinytum](https://github.com/infinytum)

### Part 1: Flashing the firmware
We need to flash the firmware of the sensor with an earlier version. Enter the `goodix-fp-dump` directory and run `sudo python run_521d.py` to flash the firmware. It might fail with a timeout error. In this case, go to the usbreset directory and do the following:

1. Compile the code with `gcc usbreset.c -o usbreset.out`
2. Run `lsusb | grep FingerPrint` to find the usb address of the reader. Look specifically at the "bus" and "device" fields.
3. Run `sudo ./usbreset.out /dev/bus/usb/<bus>/<device>`, substituting <bus\> and <device\> with the values from the last command, for example `sudo ./usbreset.out /dev/bus/usb/003/002`

Then run the Python code again. Eventually it should flash successfully. Now we can move on to step 2.

### Part 2: Installing fprintd
Install the latest version of fprintd by running `sudo pacman -S fprintd`.

### Part 3: Installing patched libfprint
The final step! Install the AUR package `libfprint-goodix-521d`.

Now, finally, run `systemctl restart fprintd` to restart the fingerprint service. You should be done! Use `fprintd-enroll` to enroll a new finger.

For getting this working for authentication, checkout [this](https://wiki.archlinux.org/title/Fprint) Arch Wiki page.

As of version 5.24, KDE Plasma supports fingerprint authentication natively using libfprint as a backend. This *should be* painless once libfprint itself is configured. The setup is located in Settings > Users.

Thanks to everyone who got this code working, especially Infinytum (NilaTheDragon on Discord) who did amazing work to complete the driver and helped me get it installed as well :).

## Subsequent Restarts and Dual Booting
Windows is kinda like those seagulls from Finding Nemo when it comes to hardware. It aggressively installs and updates drivers without user intervention. For this reason, you may find your reader breaking after using Windows. To fix this issue you'll need to muddle with the config a bit before you can reflash.

If you used the automated installer, that's just `sudo goodix-fp-fix`. Otherwise, here's how to do it by hand:

1. Stop the fprintd service: `sudo systemctl stop fprintd`
2. Reset the reader (follow the instructions above)
3. Flash the firmware (instructions above)
4. Start the service again: `sudo systemctl start fprintd`

And you should be good to go.
