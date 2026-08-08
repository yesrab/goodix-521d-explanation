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
| `--pam` | Also enable fingerprint login through your distro's PAM tool. |
| `--uninstall` | Remove everything the script installed. |

Run `... \| sudo bash -s -- --help` for the full list. The log is at `/var/log/goodix-fp-setup.log`.

**Which libfprint does it build?** By default, [`djnz00/libfprint`](https://github.com/djnz00/libfprint) — libfprint 1.94.10, actively maintained, and it accepts the **stock** `GFUSB_GM168SEC_APP_10034` firmware as well as the downgraded `10019`. That means a 521d on stock firmware often needs no flashing at all. `--legacy-driver` switches to [`infinytum/libfprint`](https://github.com/infinytum/libfprint), which is what the AUR package `libfprint-goodix-521d` builds from — libfprint 1.94.1, last updated in 2021, and it only accepts `10019`.

**Windows broke the reader again?** The script installs `goodix-fp-fix`; just run `sudo goodix-fp-fix`.

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
