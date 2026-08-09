#!/usr/bin/env bash
#
# goodix-fp-setup — fully automated Goodix fingerprint reader setup for Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/install.sh | sudo bash
#
# What it does, in order:
#   1. Detects your distro and installs every build/runtime dependency.
#   2. Detects your Goodix reader over USB (vendor 27c6) and picks the matching
#      goodix-fp-dump script for you.
#   3. Reads the reader's current firmware. Flashes the supported firmware only
#      if the firmware you have is not already usable.
#   4. Builds a patched libfprint (with the Goodix TLS drivers) into a private
#      prefix and points fprintd at it via a systemd drop-in — your distro's
#      libfprint package is left untouched.
#   5. Restarts fprintd and verifies the reader shows up on D-Bus, rolling the
#      change back automatically if fprintd fails to start.
#
# Everything lives under /opt/goodix-fp-setup and `--uninstall` removes it all.
#
# The whole script is wrapped in functions and invoked at the very bottom so
# that `curl | bash` cannot execute a half-downloaded file.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.4"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

readonly STATE_DIR="/opt/goodix-fp-setup"
readonly SRC_DIR="$STATE_DIR/src"
readonly VENV_DIR="$STATE_DIR/venv"
readonly BIN_DIR="$STATE_DIR/bin"
readonly PREFIX="$STATE_DIR/libfprint"
readonly LIBDIR="$PREFIX/lib"
readonly DROPIN_DIR="/etc/systemd/system/fprintd.service.d"
readonly DROPIN="$DROPIN_DIR/10-goodix-libfprint.conf"
readonly LDSOCONF="/etc/ld.so.conf.d/000-goodix-fp-setup.conf"
readonly HELPER="/usr/local/bin/goodix-fp-fix"
readonly LOG_FILE="/var/log/goodix-fp-setup.log"

# ---------------------------------------------------------------------------
# Sources (override with environment variables if you need to)
# ---------------------------------------------------------------------------

# goodix-fp-dump, pinned to the commit this repo's submodule points at.
FPDUMP_REPO="${GOODIX_FPDUMP_REPO:-https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git}"
FPDUMP_REF="${GOODIX_FPDUMP_REF:-cc43bb3b3154a0bccc0412ae024013c7e1923139}"

# Patched libfprint. Default is the actively maintained fork (libfprint 1.94.10,
# also accepts the stock 521d firmware). --legacy-driver switches to the older
# fork the AUR package `libfprint-goodix-521d` builds from (libfprint 1.94.1).
LIBFPRINT_REPO="${GOODIX_LIBFPRINT_REPO:-https://github.com/djnz00/libfprint.git}"
LIBFPRINT_REF="${GOODIX_LIBFPRINT_REF:-master}"
readonly LEGACY_LIBFPRINT_REPO="https://github.com/infinytum/libfprint.git"
readonly LEGACY_LIBFPRINT_REF="unstable"

readonly GOODIX_VID="27c6"
# Overridable so the detection logic can be exercised against a fake tree.
SYSFS_USB="${GOODIX_SYSFS_USB:-/sys/bus/usb/devices}"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

ASSUME_YES=0
DO_FLASH=1
DO_DRIVER=1
FORCE_FLASH=0
LEGACY_DRIVER=0
GLOBAL_LIB=0
SETUP_PAM=0
SKIP_DEPS=0
STATUS_ONLY=0
UNINSTALL=0
VERBOSE=0
FLASH_ATTEMPTS=5
FORCED_PID=""

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

OS_ID=""
OS_NAME=""
PKG_MGR=""
DEV_PID=""
DEV_BUS=""
DEV_NUM=""
DEV_NAME=""
DRIVER_MODULE=""
RUN_SCRIPT=""
TARGET_FW=""
EXTRA_FW=""
LIBFPRINT_OK=0
FPRINTD_MASKED=0
TTY_FD_OPEN=0
MESON_BIN="meson"
FLASH_PERFORMED=0
FLASH_SKIPPED_REASON=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '  %sx%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
dbg()  { (( VERBOSE )) && printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET" || true; }

die() {
    err "$*"
    printf '\n%sSetup aborted.%s Full log: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$LOG_FILE" >&2
    exit 1
}

# Prompts always go to the terminal, never to the pipe we may have been
# launched from, so `curl | sudo bash` stays interactive.
tty_open() {
    if [[ -e /dev/tty ]] && exec 3<>/dev/tty 2>/dev/null; then
        TTY_FD_OPEN=1
    fi
}

confirm() {
    local prompt="$1" reply=""
    if (( ASSUME_YES )); then
        info "$prompt [auto-yes]"
        return 0
    fi
    if (( ! TTY_FD_OPEN )); then
        die "No terminal available for confirmation. Re-run with --yes (e.g. 'curl ... | sudo bash -s -- --yes')."
    fi
    printf '\n%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET" >&3
    read -r reply <&3 || reply=""
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

# ver_ge A B -> true when A >= B
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

on_error() {
    local rc=$? line=${BASH_LINENO[0]:-?}
    err "Unexpected failure (exit $rc) near line $line."
    cleanup
    printf '\n%sSetup aborted.%s Full log: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$LOG_FILE" >&2
    exit "$rc"
}

cleanup() {
    if (( FPRINTD_MASKED )); then
        systemctl unmask fprintd.service >/dev/null 2>&1 || true
        FPRINTD_MASKED=0
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
goodix-fp-setup ${SCRIPT_VERSION} — automated Goodix fingerprint setup for Linux

Usage:
  curl -fsSL <raw-url>/install.sh | sudo bash
  curl -fsSL <raw-url>/install.sh | sudo bash -s -- [options]
  sudo ./install.sh [options]

Options:
  -y, --yes             Don't ask for confirmation (required when non-interactive).
      --status          Report device / firmware / driver state and exit.
      --flash-only      Only flash the reader firmware; skip libfprint and fprintd.
      --driver-only     Only build/install libfprint and fprintd; skip flashing.
      --force-flash     Flash even when the current firmware is already supported.
      --legacy-driver   Build the older infinytum libfprint fork (1.94.1) instead
                        of the maintained one (1.94.10).
      --global-lib      Register the patched libfprint in /etc/ld.so.conf.d instead
                        of scoping it to fprintd. Only needed without systemd.
      --pam             Also enable fingerprint login via your distro's PAM tool.
      --device PID      Skip USB detection and assume this product id (e.g. 521d).
      --attempts N      Firmware flash attempts before giving up (default ${FLASH_ATTEMPTS}).
      --skip-deps       Don't touch the package manager; assume deps are present.
      --uninstall       Remove everything this script installed.
  -v, --verbose         Verbose output.
  -h, --help            Show this help.
      --version         Show version.

Environment overrides:
  GOODIX_FPDUMP_REPO / GOODIX_FPDUMP_REF
  GOODIX_LIBFPRINT_REPO / GOODIX_LIBFPRINT_REF

After a Windows dual-boot breaks the reader again, just run: sudo goodix-fp-fix
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -y|--yes)        ASSUME_YES=1 ;;
            --status)        STATUS_ONLY=1 ;;
            --flash-only)    DO_DRIVER=0 ;;
            --driver-only)   DO_FLASH=0 ;;
            --force-flash)   FORCE_FLASH=1 ;;
            --legacy-driver) LEGACY_DRIVER=1 ;;
            --global-lib)    GLOBAL_LIB=1 ;;
            --pam)           SETUP_PAM=1 ;;
            --skip-deps)     SKIP_DEPS=1 ;;
            --uninstall)     UNINSTALL=1 ;;
            -v|--verbose)    VERBOSE=1 ;;
            --device)        shift; FORCED_PID="${1:-}"; [[ -n "$FORCED_PID" ]] || die "--device needs a product id" ;;
            --attempts)      shift; FLASH_ATTEMPTS="${1:-}"; [[ "$FLASH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "--attempts needs a positive number" ;;
            -h|--help)       usage; exit 0 ;;
            --version)       echo "goodix-fp-setup $SCRIPT_VERSION"; exit 0 ;;
            *)               usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    if (( LEGACY_DRIVER )); then
        LIBFPRINT_REPO="${GOODIX_LIBFPRINT_REPO:-$LEGACY_LIBFPRINT_REPO}"
        LIBFPRINT_REF="${GOODIX_LIBFPRINT_REF:-$LEGACY_LIBFPRINT_REF}"
    fi
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

require_root() {
    [[ "$(id -u)" == "0" ]] || die "This script must run as root (pipe it into 'sudo bash', or use 'sudo ./install.sh')."
}

require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || die "This only works on Linux (detected $(uname -s))."
    [[ -d /sys/bus/usb/devices ]] || die "/sys/bus/usb/devices is missing — is usbcore loaded?"
}

start_logging() {
    if : >>"$LOG_FILE" 2>/dev/null; then
        exec > >(tee -a "$LOG_FILE") 2>&1
        printf '\n===== goodix-fp-setup %s @ %s =====\n' "$SCRIPT_VERSION" "$(date -Is 2>/dev/null || date)" >>"$LOG_FILE"
    fi
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
        local like="${ID_LIKE:-}"
    else
        OS_ID="unknown"; OS_NAME="unknown"; local like=""
    fi

    if   have pacman;  then PKG_MGR="pacman"
    elif have apt-get; then PKG_MGR="apt"
    elif have dnf;     then PKG_MGR="dnf"
    elif have zypper;  then PKG_MGR="zypper"
    elif have yum;     then PKG_MGR="yum"
    else                    PKG_MGR="none"
    fi

    info "Distribution : $OS_NAME"
    info "Package tool : $PKG_MGR"
    dbg  "ID=$OS_ID ID_LIKE=${like:-none}"

    if have rpm-ostree || [[ -f /run/ostree-booted ]]; then
        warn "This looks like an image-based/immutable system (ostree)."
        warn "Package installation and /usr changes will not persist. Consider a toolbox or layered install."
    fi
    if ! have systemctl; then
        warn "systemd not found — fprintd integration will fall back to --global-lib."
        GLOBAL_LIB=1
    fi
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

pkg_list() {
    case "$PKG_MGR" in
        pacman)
            echo "python git curl base-devel meson ninja pkgconf glib2 glib2-devel libgusb libgudev openssl pixman nss libusb systemd-libs fprintd"
            ;;
        apt)
            echo "python3 python3-venv python3-dev python3-pip build-essential git curl meson ninja-build pkg-config libglib2.0-dev libgusb-dev libgudev-1.0-dev libssl-dev libpixman-1-dev libnss3-dev libusb-1.0-0-dev libsystemd-dev openssl fprintd"
            ;;
        dnf|yum)
            echo "python3 python3-devel gcc make git curl meson ninja-build pkgconf-pkg-config glib2-devel libgusb-devel libgudev-devel openssl-devel pixman-devel nss-devel libusb1-devel systemd-devel openssl fprintd"
            ;;
        zypper)
            echo "python3 python3-devel python3-pip gcc make git curl meson ninja pkg-config glib2-devel libgusb-devel libgudev-1_0-devel libopenssl-devel libpixman-1-0-devel mozilla-nss-devel libusb-1_0-devel systemd-devel openssl fprintd"
            ;;
        *) echo "" ;;
    esac
}

install_packages() {
    step "Installing dependencies"

    if (( SKIP_DEPS )); then
        info "--skip-deps given, not touching the package manager."
        return 0
    fi

    local pkgs; pkgs="$(pkg_list)"
    if [[ -z "$pkgs" ]]; then
        warn "No package recipe for this system. Skipping automatic installation."
        warn "The preflight check below will tell you exactly what is missing."
        return 0
    fi

    # shellcheck disable=SC2086
    case "$PKG_MGR" in
        pacman)
            if ! pacman -S --needed --noconfirm $pkgs; then
                info "Refreshing package databases and retrying..."
                pacman -Sy --noconfirm
                pacman -S --needed --noconfirm $pkgs
            fi
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || warn "apt-get update reported problems; continuing."
            apt-get install -y --no-install-recommends $pkgs
            ;;
        dnf)  dnf install -y $pkgs ;;
        yum)  yum install -y $pkgs ;;
        zypper)
            zypper --non-interactive refresh || warn "zypper refresh reported problems; continuing."
            zypper --non-interactive install --no-recommends $pkgs
            ;;
    esac
    ok "Dependencies installed."
}

preflight() {
    step "Checking the build environment"

    local missing_bin=() missing_pc=()

    have git       || missing_bin+=("git")
    have python3   || missing_bin+=("python3")
    have pkg-config || have pkgconf || missing_bin+=("pkg-config")
    have cc || have gcc || missing_bin+=("gcc")
    have ninja || have ninja-build || missing_bin+=("ninja")

    if (( ${#missing_bin[@]} )); then
        err "Missing required programs: ${missing_bin[*]}"
        die "Install them with your package manager, then re-run with --skip-deps."
    fi

    # Everything below is only needed to compile libfprint.
    if (( ! DO_DRIVER )); then
        ok "Toolchain present (libfprint checks skipped, nothing to build)."
        return 0
    fi

    local pcbin="pkg-config"; have pkg-config || pcbin="pkgconf"
    local mod
    for mod in "glib-2.0 >= 2.68" "gio-unix-2.0" "gobject-2.0" "gusb >= 0.2.0" "openssl" "pixman-1" "gudev-1.0"; do
        # shellcheck disable=SC2086
        if ! "$pcbin" --exists $mod 2>/dev/null; then
            missing_pc+=("$mod")
        fi
    done

    if (( ${#missing_pc[@]} )); then
        err "Missing development libraries (pkg-config): ${missing_pc[*]}"
        if printf '%s\n' "${missing_pc[@]}" | grep -q 'glib-2.0'; then
            err "libfprint needs glib >= 2.68. Very old releases (Debian 11, Ubuntu 20.04) cannot build this."
        fi
        die "Install the corresponding -dev/-devel packages and re-run."
    fi
    ok "All development libraries present."

    # meson >= 0.59 — fall back to a pip-installed meson if the distro's is old.
    local mv=""
    if have meson; then mv="$(meson --version 2>/dev/null || true)"; fi
    if [[ -z "$mv" ]] || ! ver_ge "$mv" "0.59.0"; then
        warn "meson ${mv:-not found} is too old (need >= 0.59); a private copy will be installed with pip."
        MESON_BIN=""
    else
        ok "meson $mv"
    fi
}

python_ok_for_flashing() {
    local v
    v="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0.0)"
    ver_ge "$v" "3.10"
}

# ---------------------------------------------------------------------------
# Device detection
# ---------------------------------------------------------------------------

device_table() {
    # Fills DRIVER_MODULE / RUN_SCRIPT / TARGET_FW / EXTRA_FW / LIBFPRINT_OK.
    DRIVER_MODULE=""; RUN_SCRIPT=""; TARGET_FW=""; EXTRA_FW=""; LIBFPRINT_OK=0
    case "$1" in
        5110) DRIVER_MODULE="driver_51x0"; RUN_SCRIPT="run_5110.py"; TARGET_FW="GF_ST411SEC_APP_12117";    LIBFPRINT_OK=1 ;;
        5117) DRIVER_MODULE="driver_51x7"; RUN_SCRIPT="run_5117.py"; TARGET_FW="GF_ST411SEC_APP_12109" ;;
        521d) DRIVER_MODULE="driver_52xd"; RUN_SCRIPT="run_521d.py"; TARGET_FW="GFUSB_GM168SEC_APP_10019"; LIBFPRINT_OK=1
              (( LEGACY_DRIVER )) || EXTRA_FW="GFUSB_GM168SEC_APP_10034" ;;
        532d) DRIVER_MODULE="driver_53xd"; RUN_SCRIPT="run_532d.py"; TARGET_FW="GF5298_GM168SEC_APP_13016" ;;
        538d) DRIVER_MODULE="driver_53xd"; RUN_SCRIPT="run_538d.py"; TARGET_FW="GF5298_GM168SEC_APP_13016"; LIBFPRINT_OK=1 ;;
        5503) DRIVER_MODULE="driver_5503"; RUN_SCRIPT="run_5503.py"; TARGET_FW="GF3208_RTSEC_APP_10062" ;;
        55a4) DRIVER_MODULE="driver_55x4"; RUN_SCRIPT="run_55a4.py"; TARGET_FW="GF3268_RTSEC_APP_10041" ;;
        55b4) DRIVER_MODULE="driver_55x4"; RUN_SCRIPT="run_55b4.py"; TARGET_FW="GF3268_RTSEC_APP_10041" ;;
        *)    return 1 ;;
    esac
    return 0
}

detect_device() {
    step "Looking for a Goodix reader"

    if [[ -n "$FORCED_PID" ]]; then
        DEV_PID="${FORCED_PID,,}"; DEV_PID="${DEV_PID#0x}"
        DEV_NAME="(forced with --device)"
        info "Using product id $DEV_PID as instructed."
    else
        local found=() d vid pid
        for d in "$SYSFS_USB"/*; do
            [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
            vid="$(<"$d/idVendor")"
            [[ "${vid,,}" == "$GOODIX_VID" ]] || continue
            pid="$(<"$d/idProduct")"
            found+=("${pid,,}|$d")
        done

        if (( ${#found[@]} == 0 )); then
            err "No USB device with vendor id $GOODIX_VID (Goodix) found."
            info "If your reader is on the SPI bus, or is disabled in the BIOS, this script cannot help."
            info "Check with: lsusb | grep -i goodix"
            die "No Goodix reader detected."
        fi
        if (( ${#found[@]} > 1 )); then
            warn "Several Goodix devices found; using the first one."
        fi

        local entry="${found[0]}" sys
        DEV_PID="${entry%%|*}"
        sys="${entry#*|}"
        DEV_BUS="$(cat "$sys/busnum" 2>/dev/null || echo "")"
        DEV_NUM="$(cat "$sys/devnum" 2>/dev/null || echo "")"
        DEV_NAME="$(cat "$sys/product" 2>/dev/null || echo "Goodix fingerprint reader")"
    fi

    ok "Found $GOODIX_VID:$DEV_PID — $DEV_NAME"
    [[ -n "$DEV_BUS" ]] && dbg "USB bus $DEV_BUS device $DEV_NUM"

    if ! device_table "$DEV_PID"; then
        err "Product id $DEV_PID is not handled by goodix-fp-dump."
        info "Known ids: 5110 5117 521d 532d 538d 5503 55a4 55b4"
        die "Unsupported Goodix model."
    fi

    info "Flashing script : goodix-fp-dump/$RUN_SCRIPT"
    info "Target firmware : $TARGET_FW"
    [[ -n "$EXTRA_FW" ]] && info "Also accepted   : $EXTRA_FW (stock firmware, no flashing needed)"

    if (( ! LIBFPRINT_OK )); then
        warn "The patched libfprint has no driver for $DEV_PID — only 5110, 521d and 538d are covered."
        warn "Firmware flashing will still run, but fprintd will not be able to use this reader."
        DO_DRIVER=0
    fi
}

# ---------------------------------------------------------------------------
# Helper programs written to disk
# ---------------------------------------------------------------------------

write_helpers() {
    mkdir -p "$BIN_DIR"

    cat >"$BIN_DIR/gfp_usb.py" <<'PYEOF'
#!/usr/bin/env python3
"""USB helpers for goodix-fp-setup. Standard library only."""
import argparse
import fcntl
import glob
import os
import sys
import time

VENDOR = "27c6"
# usbdevice_fs.h: #define USBDEVFS_RESET _IO('U', 20)
USBDEVFS_RESET = (ord("U") << 8) | 20


def _read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def find_devices():
    devices = []
    for sysdir in sorted(glob.glob("/sys/bus/usb/devices/*")):
        if _read(os.path.join(sysdir, "idVendor")).lower() != VENDOR:
            continue
        devices.append(
            {
                "pid": _read(os.path.join(sysdir, "idProduct")).lower(),
                "bus": _read(os.path.join(sysdir, "busnum")),
                "dev": _read(os.path.join(sysdir, "devnum")),
                "name": _read(os.path.join(sysdir, "product")) or "Goodix fingerprint reader",
                "sys": sysdir,
            }
        )
    return devices


def node_for(device):
    return "/dev/bus/usb/%03d/%03d" % (int(device["bus"]), int(device["dev"]))


def reset(device):
    """Same USBDEVFS_RESET ioctl as usbreset/usbreset.c in this repo."""
    node = node_for(device)
    try:
        fd = os.open(node, os.O_WRONLY)
    except OSError as error:
        return "cannot open %s: %s" % (node, error)
    try:
        fcntl.ioctl(fd, USBDEVFS_RESET, 0)
        return None
    except OSError as error:
        return "ioctl on %s failed: %s" % (node, error)
    finally:
        os.close(fd)


def deauthorize_cycle(device):
    """Stronger fallback: make the kernel drop and re-enumerate the device."""
    path = os.path.join(device["sys"], "authorized")
    try:
        with open(path, "w") as handle:
            handle.write("0")
        time.sleep(1.0)
        with open(path, "w") as handle:
            handle.write("1")
        time.sleep(1.5)
        return None
    except OSError as error:
        return "authorized toggle failed: %s" % error


def wait_for(pid, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for device in find_devices():
            if device["pid"] == pid:
                return device
        time.sleep(0.5)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["list", "reset", "wait"])
    parser.add_argument("--pid", default="")
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    devices = find_devices()
    if args.pid:
        devices = [d for d in devices if d["pid"] == args.pid.lower()]

    if args.action == "list":
        for device in devices:
            print("pid=%s bus=%s dev=%s name=%s" % (device["pid"], device["bus"], device["dev"], device["name"]))
        return 0 if devices else 1

    if args.action == "wait":
        return 0 if wait_for(args.pid.lower(), args.timeout) else 1

    if not devices:
        print("no matching Goodix device present", file=sys.stderr)
        return 1

    device = devices[0]
    problem = reset(device)
    if problem is None:
        print("reset %s" % node_for(device))
    else:
        print("%s; falling back to re-enumeration" % problem, file=sys.stderr)
        problem = deauthorize_cycle(device)
        if problem is not None:
            print(problem, file=sys.stderr)
            return 1
        print("re-enumerated %s" % device["sys"])

    # Give udev time to recreate the device node.
    return 0 if wait_for(device["pid"], 15.0) else 1


if __name__ == "__main__":
    sys.exit(main())
PYEOF

    cat >"$BIN_DIR/gfp_flash.py" <<'PYEOF'
#!/usr/bin/env python3
"""Run a goodix-fp-dump driver unattended.

goodix-fp-dump's driver `main()` does three things: a random-code "are you a
bot" prompt, the firmware flash loop, and finally an image-capture demo that
needs an openssl PSK server and a real finger on the sensor. We only want the
middle part, so this wrapper answers the prompt automatically and replaces the
demo with a stub. Everything that actually touches the firmware is upstream's
own, unmodified code.
"""
import argparse
import builtins
import importlib
import os
import re
import sys

TARGET_ATTR = "TARGET_FIRMWARE"

# Exit codes the installer distinguishes.
EXIT_OK = 0
EXIT_PROBE_FAILED = 2
EXIT_ABORTED = 3
EXIT_NO_FLASH_PATH = 4
EXIT_ENVIRONMENT = 5     # nothing a USB reset and a retry could fix
EXIT_NEEDS_FLASH = 10


def auto_input(prompt=""):
    """Answer upstream's anti-automation prompt by echoing back its own code."""
    text = str(prompt)
    sys.stdout.write(text)
    match = re.search(r"(\d+)", text)
    answer = match.group(1) if match else ""
    sys.stdout.write(answer + "    [answered by goodix-fp-setup]\n")
    sys.stdout.flush()
    return answer


def release(device):
    """Close the USB handle.

    goodix.Device.disconnect() is *not* this: it blocks polling until the reader
    physically detaches, which is what upstream wants after a reset. It never
    frees the libusb handle, so calling it here would leave the interface
    claimed and the next open in this process would fail with EBUSY.
    """
    try:
        import usb.util
        handle = getattr(getattr(device, "protocol", None), "device", None)
        if handle is not None:
            usb.util.dispose_resources(handle)
    except Exception:
        pass


def probe(driver, product):
    """Return (firmware, psk_valid). Either may be None if unreadable."""
    device = None
    try:
        device = driver.init_device(product)
        firmware = device.firmware_version()
        try:
            psk = driver.check_psk(device)
        except Exception:
            psk = None
        return firmware, psk
    finally:
        if device is not None:
            release(device)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module", required=True, help="e.g. driver_52xd")
    parser.add_argument("--product", required=True, help="e.g. 0x521d")
    parser.add_argument("--extra-ok", default="", help="comma separated extra acceptable firmware strings")
    parser.add_argument("--source-dir", required=True, help="the goodix-fp-dump checkout")
    parser.add_argument("--probe-only", action="store_true",
                        help="report the firmware and exit; never opens the device twice")
    args = parser.parse_args()

    # This script lives outside the goodix-fp-dump checkout, and Python seeds
    # sys.path with the *script's* directory rather than the working directory,
    # so the driver modules have to be put on the path explicitly. The drivers
    # also open firmware/<family>/*.bin by relative path, hence the chdir.
    source = os.path.abspath(args.source_dir)
    if not os.path.isdir(source):
        print("GFP_ERROR=source directory %s does not exist" % source, file=sys.stderr)
        return EXIT_ENVIRONMENT
    sys.path.insert(0, source)
    os.chdir(source)

    product = int(args.product, 16)
    try:
        driver = importlib.import_module(args.module)
    except ImportError as error:
        print("GFP_ERROR=cannot import %s from %s: %s" % (args.module, source, error), file=sys.stderr)
        return EXIT_ENVIRONMENT

    # Probing and flashing must never share a process. USBProtocol claims the
    # interface and nothing in goodix-fp-dump releases it, so a second
    # init_device() in the same interpreter dies with EBUSY. The installer
    # already runs the probe as its own process and decides from its exit code
    # whether to invoke us again to flash.
    if args.probe_only:
        acceptable = [getattr(driver, TARGET_ATTR, "")]
        acceptable += [f for f in args.extra_ok.split(",") if f]

        try:
            firmware, psk = probe(driver, product)
        except Exception as error:
            print("GFP_PROBE_ERROR=%s" % error)
            return EXIT_PROBE_FAILED

        print("GFP_FIRMWARE=%s" % firmware)
        print("GFP_PSK_VALID=%s" % psk)

        target = getattr(driver, TARGET_ATTR, "")
        # The target firmware still needs the driver PSK written, otherwise
        # upstream's own loop would erase and re-flash it anyway.
        if (firmware in acceptable) and (firmware != target or psk is not False):
            print("GFP_STATUS=ALREADY_SUPPORTED")
            return EXIT_OK

        print("GFP_STATUS=NEEDS_FLASH")
        return EXIT_NEEDS_FLASH

    # Flash path. upstream's main() reads the firmware itself and drives the
    # erase / PSK / flash loop, so there is nothing for us to check first.
    if not hasattr(driver, "run_driver"):
        print("GFP_STATUS=NO_FLASH_PATH")
        return EXIT_NO_FLASH_PATH

    state = {"reached": False}

    def stub_run_driver(device, *rest, **kwargs):
        state["reached"] = True
        print("GFP: target firmware is active and the PSK is valid.")
        print("GFP: skipping upstream's image-capture demo (fprintd does that job).")

    builtins.input = auto_input
    driver.run_driver = stub_run_driver

    driver.main(product)

    if state["reached"]:
        print("GFP_STATUS=FLASHED")
        return EXIT_OK

    print("GFP_STATUS=ABORTED")
    return EXIT_ABORTED


if __name__ == "__main__":
    sys.exit(main())
PYEOF

    chmod 0755 "$BIN_DIR/gfp_usb.py" "$BIN_DIR/gfp_flash.py"
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

sync_repo() {
    local url="$1" ref="$2" dest="$3" recurse="${4:-0}"

    if [[ -d "$dest/.git" ]]; then
        dbg "Updating $dest"
        git -C "$dest" remote set-url origin "$url"
        git -C "$dest" fetch --tags --force origin || warn "Could not reach $url; using the local copy."
    else
        rm -rf "$dest"
        git clone "$url" "$dest"
    fi

    # Prefer the remote branch when a branch name was given, fall back to a raw
    # ref so pinned commit hashes work too.
    if git -C "$dest" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
        git -C "$dest" -c advice.detachedHead=false checkout --force "origin/$ref" >/dev/null
    else
        git -C "$dest" -c advice.detachedHead=false checkout --force "$ref" >/dev/null
    fi

    if (( recurse )); then
        git -C "$dest" submodule sync --recursive >/dev/null
        git -C "$dest" submodule update --init --recursive
    fi
    dbg "$dest is at $(git -C "$dest" rev-parse --short HEAD)"
}

fetch_sources() {
    step "Fetching sources"
    mkdir -p "$SRC_DIR"

    if (( DO_FLASH )); then
        info "goodix-fp-dump ($FPDUMP_REF)"
        sync_repo "$FPDUMP_REPO" "$FPDUMP_REF" "$SRC_DIR/goodix-fp-dump" 1
        [[ -f "$SRC_DIR/goodix-fp-dump/$RUN_SCRIPT" ]] || die "$RUN_SCRIPT is missing from goodix-fp-dump."
        ok "goodix-fp-dump ready."
    fi

    if (( DO_DRIVER )); then
        info "libfprint ($LIBFPRINT_REPO @ $LIBFPRINT_REF)"
        sync_repo "$LIBFPRINT_REPO" "$LIBFPRINT_REF" "$SRC_DIR/libfprint" 0
        [[ -d "$SRC_DIR/libfprint/libfprint/drivers/goodixtls" ]] || die "That libfprint checkout has no goodixtls drivers."
        ok "libfprint ready ($(grep -m1 -oE "version: *'[^']+'" "$SRC_DIR/libfprint/meson.build" | grep -oE "[0-9.]+"))."
    fi
}

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------

setup_venv() {
    step "Preparing the Python environment"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        python3 -m venv "$VENV_DIR" || die "Could not create a virtualenv. On Debian/Ubuntu install python3-venv."
    fi
    "$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip wheel setuptools \
        || warn "Could not upgrade pip; continuing with the bundled version."

    if (( DO_FLASH )); then
        # spidev is the only dependency without a prebuilt wheel and it is only
        # ever used by the SPI drivers. Install it if it builds, stub it if not,
        # because protocol.py imports it unconditionally.
        info "Installing pyusb, crcmod, pycryptodome, crccheck, python-periphery"
        "$VENV_DIR/bin/python" -m pip install --quiet pyusb crcmod pycryptodome crccheck python-periphery \
            || die "Could not install the Python dependencies (no network?)."

        if "$VENV_DIR/bin/python" -m pip install --quiet spidev 2>/dev/null; then
            ok "spidev installed."
        else
            warn "spidev could not be built; installing a stub (SPI readers are not supported here)."
            local site
            site="$("$VENV_DIR/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
            cat >"$site/spidev.py" <<'PYEOF'
"""Stub written by goodix-fp-setup.

goodix-fp-dump imports spidev unconditionally even for USB readers. The real
package needs a C toolchain that was not available here, so importing works but
any actual use fails loudly.
"""


def SpiDev(*args, **kwargs):
    raise RuntimeError(
        "spidev is not installed; SPI Goodix readers are not supported by "
        "goodix-fp-setup. Install python3-dev and a C compiler, then re-run."
    )
PYEOF
        fi
    fi

    if (( DO_DRIVER )) && [[ -z "$MESON_BIN" ]]; then
        info "Installing a private meson + ninja"
        "$VENV_DIR/bin/python" -m pip install --quiet "meson>=1.0" ninja \
            || die "Could not install meson with pip."
        MESON_BIN="$VENV_DIR/bin/meson"
        export PATH="$VENV_DIR/bin:$PATH"
    fi
    ok "Python environment ready."
}

# ---------------------------------------------------------------------------
# fprintd control
# ---------------------------------------------------------------------------

fprintd_unit_exists() {
    have systemctl && systemctl list-unit-files fprintd.service >/dev/null 2>&1 \
        && systemctl cat fprintd.service >/dev/null 2>&1
}

hold_fprintd() {
    fprintd_unit_exists || return 0
    info "Stopping fprintd so it releases the reader"
    systemctl stop fprintd.service >/dev/null 2>&1 || true
    # fprintd is D-Bus activated; mask it so nothing wakes it mid-flash.
    if systemctl mask fprintd.service >/dev/null 2>&1; then
        FPRINTD_MASKED=1
    fi
}

release_fprintd() {
    (( FPRINTD_MASKED )) || return 0
    systemctl unmask fprintd.service >/dev/null 2>&1 || true
    FPRINTD_MASKED=0
}

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------

probe_firmware() {
    # Prints the driver's report; returns 0 = supported, 10 = flash needed, other = error.
    "$VENV_DIR/bin/python" "$BIN_DIR/gfp_flash.py" \
        --source-dir "$SRC_DIR/goodix-fp-dump" \
        --module "$DRIVER_MODULE" --product "0x$DEV_PID" --extra-ok "$EXTRA_FW" --probe-only
}

usb_reset() {
    info "Resetting the USB device"
    python3 "$BIN_DIR/gfp_usb.py" reset --pid "$DEV_PID" || warn "USB reset did not complete cleanly."
    sleep 2
}

flash_firmware() {
    step "Firmware"

    if ! python_ok_for_flashing; then
        die "Flashing needs Python >= 3.10 (found $(python3 -V 2>&1)). Use --driver-only to skip it."
    fi

    hold_fprintd

    local probe_out probe_rc=0
    probe_out="$(probe_firmware 2>&1)" || probe_rc=$?
    dbg "$probe_out"

    local current
    current="$(sed -n 's/^GFP_FIRMWARE=//p' <<<"$probe_out" | tail -n1)"
    if [[ -n "$current" ]]; then info "Current firmware: $current"; fi

    if (( probe_rc == 0 )) && ! (( FORCE_FLASH )); then
        FLASH_SKIPPED_REASON="firmware '$current' is already supported by the patched libfprint"
        ok "No flashing needed — $FLASH_SKIPPED_REASON."
        release_fprintd
        return 0
    fi
    if (( probe_rc != 0 && probe_rc != 10 )); then
        warn "Could not read the current firmware; attempting to flash anyway."
    fi

    if (( FORCE_FLASH )) && (( probe_rc == 0 )); then
        warn "--force-flash: running the flasher even though the current firmware is usable."
    fi

    echo
    warn "About to write firmware $TARGET_FW to your reader."
    warn "This is experimental. It can leave the reader unusable. Do not do this on a machine"
    warn "where the fingerprint reader is your only way in."
    if ! confirm "Flash the reader now?"; then
        release_fprintd
        die "Firmware flashing declined."
    fi

    local attempt rc
    for (( attempt = 1; attempt <= FLASH_ATTEMPTS; attempt++ )); do
        info "Flash attempt $attempt of $FLASH_ATTEMPTS (running $RUN_SCRIPT)"
        rc=0
        "$VENV_DIR/bin/python" -u "$BIN_DIR/gfp_flash.py" \
            --source-dir "$SRC_DIR/goodix-fp-dump" \
            --module "$DRIVER_MODULE" --product "0x$DEV_PID" || rc=$?

        if (( rc == 0 )); then
            FLASH_PERFORMED=1
            ok "Firmware is now $TARGET_FW."
            release_fprintd
            sleep 2
            return 0
        fi

        # 3/4/5 are "no amount of retrying will help" — a broken checkout, a
        # driver with no flash path, or upstream bailing out. Only USB-level
        # failures are worth resetting and retrying.
        if (( rc == 3 || rc == 4 || rc == 5 )); then
            release_fprintd
            err "The flashing tool could not run (exit $rc); retrying would not help."
            die "Firmware flashing failed."
        fi

        warn "Attempt $attempt failed (exit $rc)."
        if (( attempt < FLASH_ATTEMPTS )); then
            # This is the usbreset step from the README, done with an ioctl
            # instead of compiling usbreset.c.
            usb_reset
        fi
    done

    release_fprintd
    err "The reader did not accept the firmware after $FLASH_ATTEMPTS attempts."
    info "Try unplugging/replugging the machine's power, a cold reboot, or run again with --attempts 10."
    info "If it keeps timing out, ask in the Goodix Linux Development Discord: https://discord.gg/tqxCu3986U"
    die "Firmware flashing failed."
}

# ---------------------------------------------------------------------------
# libfprint
# ---------------------------------------------------------------------------

# True when the libfprint checkout declares the given meson option. The forks
# differ (the 1.94.1 one has no 'installed-tests'), and meson hard-errors on
# options it doesn't know about.
meson_has_option() {
    local optfile="$1" name="$2"
    [[ -n "$optfile" ]] || return 1
    grep -qE "^[[:space:]]*option\([[:space:]]*'${name}'" "$optfile"
}

# The 52XD driver carries the TLS PSK for the stock 10034 firmware but not for
# the 10019 firmware this script flashes, even though it knows 10019's PMK hash
# and verifies the sensor against it. A reader on 10019 therefore activates
# cleanly and then dies at the handshake with "Goodix TLS PSK is not
# configured". The missing PSK is 32 zero bytes: goodix-fp-dump writes exactly
# that (driver_52xd.py PSK) and feeds it to `openssl s_server -psk` for its own
# handshake, and sha256 of it is the driver's own goodix_52xd_pmk_hash_10019.
#
# sync_repo() checks out --force, so this is re-applied on every run.
patch_libfprint_52xd_psk() {
    local file="$1/libfprint/drivers/goodixtls/goodix52xd.c"

    [[ -f "$file" ]] || return 0
    if grep -q 'psk_10019' "$file"; then
        dbg "goodix52xd.c already supplies the 10019 PSK."
        return 0
    fi

    if python3 - "$file" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    source = handle.read()

old = """  if (!self->firmware_10034)
    {
      if (length)
        *length = 0;
      return NULL;
    }
"""

new = """  if (!self->firmware_10034)
    {
      /* The 10019 firmware uses an all-zero PSK. goodix-fp-dump writes it, and
         sha256 of it is goodix_52xd_pmk_hash_10019 above. Patched in by
         goodix-fp-setup. */
      static const guint8 psk_10019[32] = { 0 };

      if (length)
        *length = sizeof (psk_10019);

      return psk_10019;
    }
"""

if source.count(old) != 1:
    sys.exit(1)

with open(path, "w") as handle:
    handle.write(source.replace(old, new))
PYEOF
    then
        ok "Gave the 52XD driver its 10019 TLS PSK."
    else
        warn "Could not patch the 10019 TLS PSK into goodix52xd.c — the driver may have changed."
        warn "If enrolling fails with 'Goodix TLS PSK is not configured', report it at"
        warn "https://github.com/yesrab/goodix-521d-explanation/issues"
    fi
}

# After each capture the 52XD driver polls frames until one looks like an empty
# sensor, and only then accepts the next finger. goodix52xd_frame_is_empty()
# calls a frame empty on either of two rules:
#
#   A  mean in [1900,2200] and high_pixels <= 16      (a quiet, unlit sensor)
#   B  mean >= 4000 and high_pixels >= 5100           (a saturated sensor)
#
# Rule B cannot fire on at least some 521d units. The frame is 64x80 = 5120
# pixels, but ~284 of them never rise above the 2800 "high" threshold, so
# high_pixels saturates at 4836 and can never reach 5100. Their saturated
# frames also read mean ~3905, just under 4000. With rule B unreachable the
# driver falls back to rule A alone, whose window such a sensor only wanders
# into every few seconds — the reader appears to hang for tens of seconds, or
# minutes, between enroll stages.
#
# The replacements sit in the gap the hardware actually leaves. On the reader
# this was measured from, frames cluster into "saturated" (mean 3757-3905,
# high 4627-4836) and "in between" (mean <= 3566, high <= 4217); 3600/4500
# separates them cleanly. Set GOODIX_KEEP_STOCK_EMPTY_THRESHOLDS=1 to skip
# this and build the driver's own values.
#
# sync_repo() checks out --force, so this is re-applied on every run.
patch_libfprint_52xd_finger_off() {
    local file="$1/libfprint/drivers/goodixtls/goodix52xd_proto.h"

    [[ -f "$file" ]] || return 0
    if [[ -n "${GOODIX_KEEP_STOCK_EMPTY_THRESHOLDS:-}" ]]; then
        info "Keeping the driver's own empty-frame thresholds."
        return 0
    fi
    if grep -q 'goodix-fp-setup' "$file"; then
        dbg "goodix52xd_proto.h thresholds already adjusted."
        return 0
    fi

    if python3 - "$file" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    source = handle.read()

old = """#define GOODIX52XD_EMPTY_SATURATED_MEAN_MIN 4000
#define GOODIX52XD_EMPTY_SATURATED_HIGH_PIXEL_MIN 5100
"""

new = """/* Lowered by goodix-fp-setup: high_pixels tops out at 4836 on real 521d
   sensors (5120 pixels, ~284 of which never cross the high threshold), so
   the stock 5100 could never match and finger-off detection stalled. */
#define GOODIX52XD_EMPTY_SATURATED_MEAN_MIN 3600
#define GOODIX52XD_EMPTY_SATURATED_HIGH_PIXEL_MIN 4500
"""

if source.count(old) != 1:
    sys.exit(1)

with open(path, "w") as handle:
    handle.write(source.replace(old, new))
PYEOF
    then
        ok "Adjusted the 52XD empty-frame thresholds so finger-off is detected."
    else
        warn "Could not adjust goodix52xd_proto.h — the driver may have changed."
        warn "Enrolling will still work but may pause a long time between scans."
    fi
}

build_libfprint() {
    step "Building patched libfprint"

    local src="$SRC_DIR/libfprint" build="$SRC_DIR/libfprint/build-goodix"
    rm -rf "$build"

    patch_libfprint_52xd_psk "$src"
    patch_libfprint_52xd_finger_off "$src"

    local optfile="" candidate
    for candidate in meson_options.txt meson.options; do
        if [[ -f "$src/$candidate" ]]; then optfile="$src/$candidate"; break; fi
    done

    local opts=(
        --prefix="$PREFIX"
        --libdir=lib
        --buildtype=release
        # GCC 14+ turns incompatible-pointer-types into an error; these forks
        # predate that. Same workaround the AUR package applies.
        -Dc_args=-Wno-incompatible-pointer-types
    )

    # Trim the build down to what fprintd actually needs, and keep every
    # installed file inside our own prefix.
    local name
    for name in doc gtk-examples introspection installed-tests; do
        if meson_has_option "$optfile" "$name"; then opts+=("-D${name}=false"); fi
    done
    for name in udev_rules udev_hwdb; do
        if meson_has_option "$optfile" "$name"; then opts+=("-D${name}=disabled"); fi
    done
    dbg "meson options: ${opts[*]}"

    info "Configuring"
    "$MESON_BIN" setup "$build" "$src" "${opts[@]}" >/dev/null \
        || { tail -n 40 "$build/meson-logs/meson-log.txt" 2>/dev/null || true; die "meson setup failed."; }

    info "Compiling (this takes a minute or two)"
    if ! "$MESON_BIN" compile -C "$build" >/dev/null 2>"$build/compile.err"; then
        warn "Build failed; retrying with the compatibility patch applied to meson.build."
        if grep -q "common_cflags = cc.get_supported_arguments(\[" "$src/meson.build" \
           && ! grep -q "Wno-incompatible-pointer-types" "$src/meson.build"; then
            sed -i "/common_cflags = cc.get_supported_arguments(\[/a \    '-Wno-incompatible-pointer-types'," "$src/meson.build"
            rm -rf "$build"
            "$MESON_BIN" setup "$build" "$src" "${opts[@]}" >/dev/null || die "meson setup failed after patching."
            "$MESON_BIN" compile -C "$build" >/dev/null 2>"$build/compile.err" \
                || { tail -n 40 "$build/compile.err"; die "libfprint failed to build."; }
        else
            tail -n 40 "$build/compile.err"
            die "libfprint failed to build."
        fi
    fi

    info "Installing to $PREFIX"
    rm -rf "$PREFIX"
    "$MESON_BIN" install -C "$build" >/dev/null || die "meson install failed."

    local sofile
    sofile="$(find "$LIBDIR" -maxdepth 1 -name 'libfprint-2.so.*' -print -quit 2>/dev/null || true)"
    [[ -n "$sofile" ]] || die "libfprint-2.so was not produced — check $LOG_FILE."
    ok "Built $(basename "$sofile")"
}

install_dropin() {
    step "Pointing fprintd at the patched libfprint"

    if (( GLOBAL_LIB )); then
        printf '%s\n' "$LIBDIR" >"$LDSOCONF"
        ldconfig
        ok "Registered $LIBDIR system-wide (/etc/ld.so.conf.d)."
        warn "This shadows your distro's libfprint for every program on the system."
        return 0
    fi

    if ! fprintd_unit_exists; then
        warn "No fprintd.service unit found; falling back to a system-wide library path."
        GLOBAL_LIB=1
        install_dropin
        return
    fi

    mkdir -p "$DROPIN_DIR"
    cat >"$DROPIN" <<EOF
# Installed by goodix-fp-setup ${SCRIPT_VERSION}.
# Makes fprintd — and only fprintd — load the patched libfprint that carries the
# Goodix TLS drivers. The distro's own libfprint package stays untouched.
[Service]
Environment=LD_LIBRARY_PATH=${LIBDIR}
EOF
    systemctl daemon-reload
    ok "Wrote $DROPIN"
}

remove_dropin() {
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    rm -f "$LDSOCONF"
    have ldconfig && ldconfig || true
    have systemctl && systemctl daemon-reload || true
}

restart_fprintd() {
    step "Restarting fprintd"
    fprintd_unit_exists || { warn "fprintd is not installed as a systemd service; skipping."; return 0; }

    systemctl stop fprintd.service >/dev/null 2>&1 || true
    if ! systemctl start fprintd.service; then
        err "fprintd refused to start with the patched libfprint."
        have journalctl && journalctl -u fprintd.service -n 30 --no-pager || true
        warn "Rolling the change back so your system keeps working."
        remove_dropin
        systemctl start fprintd.service >/dev/null 2>&1 || true
        die "fprintd could not start. The patched libfprint has been unlinked; nothing else was changed."
    fi
    ok "fprintd started."
}

verify() {
    step "Verifying"

    local devices=""
    if have busctl; then
        devices="$(busctl --system call net.reactivated.Fprint /net/reactivated/Fprint/Manager \
            net.reactivated.Fprint.Manager GetDevices 2>/dev/null || true)"
    elif have dbus-send; then
        devices="$(dbus-send --system --print-reply --dest=net.reactivated.Fprint \
            /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager.GetDevices 2>/dev/null || true)"
    else
        warn "Neither busctl nor dbus-send is available; cannot query fprintd."
        return 0
    fi

    if [[ -z "$devices" ]]; then
        warn "fprintd did not answer on D-Bus."
        return 1
    fi

    local path
    path="$(grep -oE '/net/reactivated/Fprint/Device/[0-9]+' <<<"$devices" | head -n1)"
    if [[ -z "$path" ]]; then
        err "fprintd is running but reports no fingerprint devices."
        info "The reader is usually missing here when its firmware is not one the driver accepts."
        info "Re-run with --force-flash, or check: sudo G_MESSAGES_DEBUG=all /usr/libexec/fprintd -t"
        return 1
    fi

    local name=""
    if have busctl; then
        name="$(busctl --system get-property net.reactivated.Fprint "$path" \
            net.reactivated.Fprint.Device name 2>/dev/null | sed 's/^s //; s/"//g')"
    fi
    ok "fprintd sees a reader at $path${name:+ — $name}"
    return 0
}

# ---------------------------------------------------------------------------
# PAM (opt-in)
# ---------------------------------------------------------------------------

setup_pam() {
    step "Enabling fingerprint login (PAM)"
    case "$PKG_MGR" in
        apt)
            apt-get install -y --no-install-recommends libpam-fprintd >/dev/null 2>&1 || true
            if have pam-auth-update; then
                pam-auth-update --enable fprintd && ok "Enabled through pam-auth-update."
            else
                warn "pam-auth-update not found; configure PAM manually."
            fi
            ;;
        dnf|yum)
            if have authselect; then
                authselect enable-feature with-fingerprint && authselect apply-changes \
                    && ok "Enabled through authselect."
            else
                warn "authselect not found; configure PAM manually."
            fi
            ;;
        zypper)
            if have pam-config; then
                pam-config -a --fprintd && ok "Enabled through pam-config."
            else
                warn "pam-config not found; configure PAM manually."
            fi
            ;;
        *)
            warn "No supported PAM tool on this distro."
            info "Follow https://wiki.archlinux.org/title/Fprint#Login_configuration — edit PAM by hand,"
            info "and keep a root shell open until you have verified you can still log in."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Convenience command for the dual-boot case
# ---------------------------------------------------------------------------

install_helper_command() {
    cat >"$HELPER" <<EOF
#!/usr/bin/env bash
# Installed by goodix-fp-setup ${SCRIPT_VERSION}.
# Re-flashes the reader after Windows has overwritten its firmware.
set -euo pipefail
[[ "\$(id -u)" == "0" ]] || { echo "Run this with sudo." >&2; exit 1; }
exec "$STATE_DIR/install.sh" --flash-only --yes --skip-deps "\$@"
EOF
    chmod 0755 "$HELPER"

    # Keep a copy of ourselves so the helper (and --uninstall) keep working.
    if [[ -n "${SELF_PATH:-}" && -f "$SELF_PATH" ]]; then
        install -m 0755 "$SELF_PATH" "$STATE_DIR/install.sh"
    else
        # We were piped in from curl and have no file on disk; fetch a copy.
        if have curl && curl -fsSL "${GOODIX_SELF_URL:-https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/install.sh}" \
                -o "$STATE_DIR/install.sh" 2>/dev/null; then
            chmod 0755 "$STATE_DIR/install.sh"
        else
            rm -f "$HELPER"
            warn "Could not save a local copy of this script; 'goodix-fp-fix' was not installed."
            return 0
        fi
    fi
    ok "Installed $HELPER (run it if Windows breaks the reader again)."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
    step "Removing goodix-fp-setup"
    remove_dropin
    rm -f "$HELPER"
    rm -rf "$STATE_DIR"
    if fprintd_unit_exists; then
        systemctl unmask fprintd.service >/dev/null 2>&1 || true
        systemctl restart fprintd.service >/dev/null 2>&1 || true
    fi
    ok "Removed $STATE_DIR, $DROPIN and $HELPER."
    info "Your distro's libfprint and fprintd packages were never modified, so nothing else needs undoing."
    info "The reader keeps whatever firmware it was flashed with; that is not reversible from here."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

do_status() {
    step "Status"
    detect_device

    if [[ -x "$VENV_DIR/bin/python" && -d "$SRC_DIR/goodix-fp-dump" ]]; then
        local out rc=0
        out="$(probe_firmware 2>&1)" || rc=$?
        local fw; fw="$(sed -n 's/^GFP_FIRMWARE=//p' <<<"$out" | tail -n1)"
        info "Firmware        : ${fw:-unreadable}"
        case $rc in
            0)  ok  "Firmware is supported by the patched libfprint." ;;
            10) warn "Firmware needs flashing." ;;
            *)  warn "Could not read the firmware (fprintd may be holding the device)." ;;
        esac
    else
        info "Firmware        : not checked (run the full setup first)"
    fi

    if [[ -d "$LIBDIR" ]]; then
        ok "Patched libfprint installed at $PREFIX"
    else
        warn "Patched libfprint is not installed."
    fi
    if [[ -f "$DROPIN" ]]; then ok "fprintd drop-in present."; else warn "No fprintd drop-in."; fi
    [[ -f "$LDSOCONF" ]] && info "System-wide library path registered." || true

    if fprintd_unit_exists; then
        info "fprintd state   : $(systemctl is-active fprintd.service 2>/dev/null || echo unknown)"
        verify || true
    else
        warn "fprintd is not installed."
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_plan() {
    step "Plan"
    info "Reader          : $GOODIX_VID:$DEV_PID ($DEV_NAME)"
    if (( DO_FLASH )); then
        info "Firmware        : check, and flash $TARGET_FW only if needed"
    else
        info "Firmware        : skipped (--driver-only)"
    fi
    if (( DO_DRIVER )); then
        info "libfprint       : build $LIBFPRINT_REPO@$LIBFPRINT_REF into $PREFIX"
        info "fprintd         : install from your distro and point it at that build"
    else
        info "libfprint       : skipped"
    fi
    (( SETUP_PAM )) && info "PAM             : enable fingerprint login"
    info "Log             : $LOG_FILE"
}

print_summary() {
    printf '\n%s%s Done.%s\n\n' "$C_GREEN$C_BOLD" "✓" "$C_RESET"

    if (( DO_FLASH )); then
        if (( FLASH_PERFORMED )); then
            info "Firmware flashed to $TARGET_FW."
        elif [[ -n "$FLASH_SKIPPED_REASON" ]]; then
            info "Firmware left alone — $FLASH_SKIPPED_REASON."
        fi
    fi
    (( DO_DRIVER )) && info "Patched libfprint installed at $PREFIX and wired into fprintd."

    cat <<EOF

Next steps:
  ${C_BOLD}fprintd-enroll${C_RESET}            enroll a finger (run as your normal user)
  ${C_BOLD}fprintd-verify${C_RESET}            check that it recognises you
  ${C_BOLD}fprintd-list \$USER${C_RESET}        list enrolled fingers

Desktop integration:
  GNOME  Settings > Users > Fingerprint Login
  KDE    Settings > Users  (Plasma 5.24+)

Login/sudo with a fingerprint needs PAM configuration. Re-run this script with
${C_BOLD}--pam${C_RESET} to let your distro's own tool do it, or follow
https://wiki.archlinux.org/title/Fprint

If Windows overwrites the firmware after a dual boot, run: ${C_BOLD}sudo goodix-fp-fix${C_RESET}
To undo everything this script did: ${C_BOLD}sudo $STATE_DIR/install.sh --uninstall${C_RESET}

Log: $LOG_FILE
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    SELF_PATH="${BASH_SOURCE[0]:-}"
    [[ -f "$SELF_PATH" ]] || SELF_PATH=""

    parse_args "$@"
    require_root
    require_linux
    tty_open
    start_logging
    trap on_error ERR
    trap cleanup EXIT

    printf '%sgoodix-fp-setup %s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"

    mkdir -p "$STATE_DIR"
    detect_os

    if (( UNINSTALL )); then
        do_uninstall
        exit 0
    fi

    # An interrupted earlier run (power loss, SIGKILL) can leave fprintd masked.
    if fprintd_unit_exists && [[ "$(systemctl is-enabled fprintd.service 2>/dev/null || true)" == "masked" ]]; then
        warn "fprintd was left masked by an interrupted run; unmasking it."
        systemctl unmask fprintd.service >/dev/null 2>&1 || true
    fi

    write_helpers

    if (( STATUS_ONLY )); then
        do_status
        exit 0
    fi

    if (( ! DO_FLASH && ! DO_DRIVER )); then
        die "Nothing to do: --flash-only and --driver-only cancel each other out."
    fi

    # May clear DO_DRIVER when the patched libfprint has no driver for this model.
    detect_device

    if (( ! DO_FLASH && ! DO_DRIVER )); then
        die "Nothing to do: --driver-only was given but there is no libfprint driver for $DEV_PID."
    fi

    print_plan
    echo
    warn "This is experimental software from a community reverse-engineering effort."
    if (( DO_FLASH )); then
        warn "It writes firmware to your fingerprint reader. It can brick it. There is no warranty."
    else
        warn "There is no warranty."
    fi
    if ! confirm "Continue?"; then
        info "Nothing was changed."
        exit 0
    fi

    install_packages
    preflight
    fetch_sources
    setup_venv

    if (( DO_FLASH )); then flash_firmware; fi

    if (( DO_DRIVER )); then
        build_libfprint
        install_dropin
        restart_fprintd
        verify || warn "Verification was inconclusive — see the hints above."
    elif (( DO_FLASH )) && fprintd_unit_exists; then
        # --flash-only: we stopped fprintd to free the reader, so bring it back.
        restart_fprintd
        verify || true
    fi

    if (( SETUP_PAM )); then setup_pam; fi

    install_helper_command
    print_summary
}

main "$@" </dev/null
