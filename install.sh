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

readonly SCRIPT_VERSION="1.3.0"

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

# SIGFM: a SIFT-based matcher meant for low-resolution sensors, ported here from
# goodix-fp-linux-dev/libfprint@sigfm onto djnz00's 1.94.10. The patch is a
# rebase, not a copy — see patches/ and the readme. Because it is a rebase it is
# pinned to the commit it was generated against; --sigfm ignores
# GOODIX_LIBFPRINT_REF unless you override this too.
readonly SIGFM_PATCH_NAME="sigfm-libfprint-1.94.10.patch"
SIGFM_PATCH_URL="${GOODIX_SIGFM_PATCH_URL:-https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/patches/$SIGFM_PATCH_NAME}"
SIGFM_LIBFPRINT_REF="${GOODIX_SIGFM_LIBFPRINT_REF:-72cacc37ca6524390a112e7df7bf2c6972be8217}"

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
SIGFM=0
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
SIGFM_PATCH_FILE=""

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
      --sigfm           Match with SIGFM (SIFT) instead of NBIS. Experimental; for
                        readers where a wrong finger verifies. Needs OpenCV >= 4.5,
                        pins libfprint to the commit the port targets, and makes
                        existing enrollments unreadable — you must re-enroll.
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
            --sigfm)         SIGFM=1 ;;
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

    if (( SIGFM )); then
        (( LEGACY_DRIVER )) && die "--sigfm and --legacy-driver are mutually exclusive: the port targets 1.94.10."
        # The port is a rebase against one commit, so master moving would break
        # it in ways that look like a compiler error rather than a version skew.
        LIBFPRINT_REF="$SIGFM_LIBFPRINT_REF"
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
    # SIGFM is C++ and needs OpenCV's development headers; NBIS builds need
    # neither, so they are only pulled in for --sigfm.
    local sigfm_pkgs=""
    case "$PKG_MGR" in
        pacman)
            (( SIGFM )) && sigfm_pkgs=" opencv"
            echo "python git curl base-devel meson ninja pkgconf glib2 glib2-devel libgusb libgudev openssl pixman nss libusb systemd-libs fprintd$sigfm_pkgs"
            ;;
        apt)
            (( SIGFM )) && sigfm_pkgs=" libopencv-dev"
            echo "python3 python3-venv python3-dev python3-pip build-essential git curl meson ninja-build pkg-config libglib2.0-dev libgusb-dev libgudev-1.0-dev libssl-dev libpixman-1-dev libnss3-dev libusb-1.0-0-dev libsystemd-dev openssl fprintd$sigfm_pkgs"
            ;;
        dnf|yum)
            (( SIGFM )) && sigfm_pkgs=" gcc-c++ opencv-devel"
            echo "python3 python3-devel gcc make git curl meson ninja-build pkgconf-pkg-config glib2-devel libgusb-devel libgudev-devel openssl-devel pixman-devel nss-devel libusb1-devel systemd-devel openssl fprintd$sigfm_pkgs"
            ;;
        zypper)
            (( SIGFM )) && sigfm_pkgs=" gcc-c++ opencv-devel"
            echo "python3 python3-devel python3-pip gcc make git curl meson ninja pkg-config glib2-devel libgusb-devel libgudev-1_0-devel libopenssl-devel libpixman-1-0-devel mozilla-nss-devel libusb-1_0-devel systemd-devel openssl fprintd$sigfm_pkgs"
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
    local mod mods=("glib-2.0 >= 2.68" "gio-unix-2.0" "gobject-2.0" "gusb >= 0.2.0" "openssl" "pixman-1" "gudev-1.0")

    if (( SIGFM )); then
        have c++ || have g++ || missing_bin+=("g++")
        mods+=("opencv4 >= 4.5.0")
    fi

    for mod in "${mods[@]}"; do
        # shellcheck disable=SC2086
        if ! "$pcbin" --exists $mod 2>/dev/null; then
            missing_pc+=("$mod")
        fi
    done

    if (( ${#missing_bin[@]} )); then
        err "Missing required programs: ${missing_bin[*]}"
        die "Install them with your package manager, then re-run with --skip-deps."
    fi

    if (( ${#missing_pc[@]} )); then
        err "Missing development libraries (pkg-config): ${missing_pc[*]}"
        if printf '%s\n' "${missing_pc[@]}" | grep -q 'opencv4'; then
            err "--sigfm needs OpenCV >= 4.5 development files (libopencv-dev / opencv-devel)."
            err "Note it is the 'opencv4' pkg-config module specifically; OpenCV 5 ships 'opencv5'."
        fi
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

# The SIGFM port is a real patch file rather than an inline heredoc so it can be
# reviewed and reapplied by hand. Prefer a copy sitting next to the script (a
# git clone of this repo) and fall back to downloading it.
locate_sigfm_patch() {
    local candidate here=""

    [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in "${GOODIX_SIGFM_PATCH_FILE:-}" \
                     ${here:+"$here/patches/$SIGFM_PATCH_NAME"} \
                     "$PWD/patches/$SIGFM_PATCH_NAME"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            SIGFM_PATCH_FILE="$candidate"
            info "Using local patch $candidate"
            return 0
        fi
    done

    SIGFM_PATCH_FILE="$SRC_DIR/$SIGFM_PATCH_NAME"
    info "Downloading $SIGFM_PATCH_NAME"
    curl -fsSL "$SIGFM_PATCH_URL" -o "$SIGFM_PATCH_FILE" \
        || die "Could not download the SIGFM patch from $SIGFM_PATCH_URL"
    [[ -s "$SIGFM_PATCH_FILE" ]] || die "The downloaded SIGFM patch is empty."
    return 0
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
        (( SIGFM )) && locate_sigfm_patch
    fi
    return 0
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

# The 52XD driver sets the bozorth3 match threshold to 24, well under
# libfprint's own default of 40, and it feeds the matcher a *single* 64x80
# frame: goodix52xd_image_from_frame() contrast-stretches one raw frame and
# nearest-neighbour doubles it to 128x160. There is no calibration frame
# subtracted and no frame stitching — the sibling goodix511 driver captures 40
# frames and runs fpi_assemble_frames() over them, and the 52XD driver has
# neither. NBIS therefore extracts very few minutiae, mostly from the sensor's
# fixed pattern rather than from ridges, so unrelated fingers clear a score of
# 24 and the reader authenticates anybody.
#
# 24 -> 40 makes it fail closed rather than fail open. That is the right
# direction for an authentication device even if it costs some genuine matches.
# Set GOODIX_BZ3_THRESHOLD=<n> to build a different value once you have
# measured your own scores with `debug.sh --match-test`.
#
# sync_repo() checks out --force, so this is re-applied on every run.
patch_libfprint_52xd_bz3() {
    local file="$1/libfprint/drivers/goodixtls/goodix52xd.c"
    local want envname="GOODIX_BZ3_THRESHOLD"

    # Under --sigfm this same field is the SIGFM score threshold, which counts
    # agreeing keypoint-pair geometries rather than bozorth3 points — a totally
    # different scale, so it gets its own knob.
    if (( SIGFM )); then
        envname="GOODIX_SIGFM_THRESHOLD"
        want="${GOODIX_SIGFM_THRESHOLD:-${GOODIX_BZ3_THRESHOLD:-40}}"
    else
        want="${GOODIX_BZ3_THRESHOLD:-40}"
    fi

    [[ -f "$file" ]] || return 0
    if [[ ! "$want" =~ ^[0-9]+$ ]]; then
        warn "$envname='$want' is not a number; leaving the driver's own value."
        return 0
    fi
    if grep -q 'bz3-threshold' "$file"; then
        dbg "goodix52xd.c match threshold already adjusted."
        return 0
    fi

    if python3 - "$file" "$want" <<'PYEOF'
import sys

path, want = sys.argv[1], sys.argv[2]
with open(path) as handle:
    source = handle.read()

old = "  img_dev_class->bz3_threshold = 24;\n"

new = """  /* bz3-threshold: raised from the driver's 24 by goodix-fp-setup. The 52XD
     matcher sees one contrast-stretched 64x80 frame with no calibration frame
     subtracted, so NBIS finds few real minutiae and unrelated fingers clear a
     score of 24. Failing closed beats authenticating anybody. */
  img_dev_class->bz3_threshold = %s;
""" % want

if source.count(old) != 1:
    sys.exit(1)

with open(path, "w") as handle:
    handle.write(source.replace(old, new))
PYEOF
    then
        if (( SIGFM )); then
            ok "Set the 52XD SIGFM score threshold to $want."
            warn "That number is a guess until you measure it: run debug.sh --match-test"
            warn "and set $envname to sit in the gap between your two score groups."
        else
            ok "Raised the 52XD match threshold to $want (driver ships 24)."
            if (( want < 40 )); then
                warn "$want is below libfprint's default of 40; unrelated fingers may still match."
            fi
        fi
    else
        warn "Could not adjust the 52XD match threshold — the driver may have changed."
        warn "Do not use fingerprint login until you have verified a wrong finger is rejected."
    fi
}

# The root cause behind both failure modes we see on the 521d: the image the
# driver hands the matcher is mostly sensor, not finger.
#
# goodix52xd_image_from_frame() contrast-stretches ONE raw 64x80 frame and
# nearest-neighbour doubles it. The idle sensor reads near saturation (mean
# ~3900 of 4095) and every pixel carries its own offset, so that fixed pattern
# survives the stretch and is identical for every finger. NBIS then logs "No
# minutiae found" and unrelated fingers score alike; SIGFM finds too few SIFT
# keypoints and enrolling fails outright with "Not enough keypoints found".
#
# The sibling goodix511 driver has always subtracted a calibration frame
# (goodix5xx.c, linear_subtract_inplace) and the same fix keeps turning up
# elsewhere in the ecosystem: goodix-fp-dump PR #33 ("subtracts background from
# raw image ... enough to make sigfm happy with 5395") and libfprint PR #37,
# which added contrast normalisation to goodix511 for exactly this reason.
#
# Here it costs no extra USB traffic at all. The driver already polls frames
# while waiting for a finger and throws away the ones it classifies as empty —
# the last of those *is* a calibration frame, captured moments before the scan
# rather than once per activation.
#
# Set GOODIX_KEEP_STOCK_IMAGE_PIPELINE=1 to build the driver's own single-frame
# stretch instead. GOODIX_52XD_STRETCH_CLIP_PERMILLE tunes how much of the
# histogram's tails are clipped when picking the black and white points; 0 is a
# true min/max stretch, which lets one hot pixel own the whole output range.
#
# sync_repo() checks out --force, so this is re-applied on every run.
patch_libfprint_52xd_background() {
    local file="$1/libfprint/drivers/goodixtls/goodix52xd.c"
    local clip="${GOODIX_52XD_STRETCH_CLIP_PERMILLE:-20}"

    [[ -f "$file" ]] || return 0
    if [[ -n "${GOODIX_KEEP_STOCK_IMAGE_PIPELINE:-}" ]]; then
        info "Keeping the driver's own single-frame image pipeline."
        warn "Without background subtraction the matcher cannot tell fingers apart."
        return 0
    fi
    if [[ ! "$clip" =~ ^[0-9]+$ ]] || (( clip > 400 )); then
        warn "GOODIX_52XD_STRETCH_CLIP_PERMILLE='$clip' is not a permille under 400; using 20."
        clip=20
    fi
    # patch_libfprint_52xd_psk() writes "goodix-fp-setup" and
    # patch_libfprint_52xd_bz3() writes "bz3-threshold" into this same file, so
    # this guard has to be a string only this patch produces.
    if grep -q '52xd-background' "$file"; then
        dbg "goodix52xd.c already subtracts a background frame."
        return 0
    fi

    if python3 - "$file" "$clip" <<'PYEOF'
import sys

path, clip = sys.argv[1], sys.argv[2]
with open(path) as handle:
    source = handle.read()

edits = []

# 1. Somewhere to keep the calibration frame between the poll and the capture.
edits.append((
    """  GSList* frames;
  FpiSsm* scan_ssm;
""",
    """  GSList* frames;
  /* 52xd-background: an idle frame, kept so the next capture can have the
     sensor's fixed pattern subtracted out. See goodix52xd_note_idle_frame(). */
  Goodix52xdPix* background;
  gboolean background_used;
  FpiSsm* scan_ssm;
""",
))

# 2. The subtraction itself, in front of the stretch it feeds.
edits.append((
    """/**
 * @brief Squashes the 12 bit pixels of a raw frame into the 4 bit pixels used
""",
    """/* 52xd-background: 12-bit sensor, so this is the saturation point. */
#define GOODIX52XD_PIX_MAX 4095

/* A min/max stretch lets a single hot pixel own the whole output range, so the
   black and white points are taken this far into the histogram's tails
   instead. 0 restores a true min/max stretch. Set at install time with
   GOODIX_52XD_STRETCH_CLIP_PERMILLE. */
#define GOODIX52XD_STRETCH_CLIP_PERMILLE %(clip)s

/**
 * @brief Replaces the sensor's dead border with its nearest live neighbour.
 *
 * @details Column 0, column 63, row 0 and row 79 are guard pixels: on a real
 * 521d they read ~600 while the interior reads ~4000, and in the sensor's
 * dark mode they read a flat 0. They carry no ridge data, but they are
 * identical in every capture, so left alone they become a maximum-contrast
 * rectangle around every image — a feature NBIS and SIFT both latch onto, and
 * the same one in everybody's print. goodix511 sidesteps this by cropping
 * (crop_frame in goodix511.c); extending the interior outwards costs nothing
 * and keeps the image dimensions the driver advertises.
 */
static void goodix52xd_repair_border(Goodix52xdPix* frame)
{
    guint x, y;

    for (x = 0; x != GOODIX52XD_WIDTH; ++x) {
        guint sx = CLAMP(x, 1, GOODIX52XD_WIDTH - 2);

        frame[x] = frame[sx + GOODIX52XD_WIDTH];
        frame[x + (GOODIX52XD_HEIGHT - 1) * GOODIX52XD_WIDTH] =
            frame[sx + (GOODIX52XD_HEIGHT - 2) * GOODIX52XD_WIDTH];
    }

    for (y = 0; y != GOODIX52XD_HEIGHT; ++y) {
        frame[y * GOODIX52XD_WIDTH] = frame[y * GOODIX52XD_WIDTH + 1];
        frame[y * GOODIX52XD_WIDTH + GOODIX52XD_WIDTH - 1] =
            frame[y * GOODIX52XD_WIDTH + GOODIX52XD_WIDTH - 2];
    }
}

/**
 * @brief Folds an idle frame into the background estimate. Takes ownership.
 *
 * @details goodix52xd_frame_is_empty() is a heuristic, and a light touch can
 * slip past it — that frame would otherwise become the background and get
 * subtracted from the next real capture. A finger can only pull a reading
 * down, though, so taking the per-pixel maximum across the idle frames of one
 * scan cycle ignores any that were not really idle.
 *
 * The window restarts after every capture rather than accumulating forever,
 * so the background follows the sensor's drift instead of latching onto the
 * brightest reading it has ever seen.
 */
static void goodix52xd_note_idle_frame(FpiDeviceGoodixTls52XD* self,
                                       Goodix52xdPix* frame)
{
    guint i;

    goodix52xd_repair_border(frame);

    if (!self->background || self->background_used) {
        g_free(self->background);
        self->background = frame;
        self->background_used = FALSE;
        return;
    }

    for (i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
        if (frame[i] > self->background[i])
            self->background[i] = frame[i];

    g_free(frame);
}

/**
 * @brief Cancels the sensor's fixed pattern out of a raw frame, in place.
 *
 * @details The idle sensor reads near saturation and each pixel carries its
 * own offset. Stretching a single frame therefore yields an image whose
 * structure is mostly sensor rather than ridges, which is why NBIS reports no
 * minutiae and unrelated fingers match. goodix511 solves this with a
 * calibration frame (goodix5xx.c, linear_subtract_inplace); the empty frames
 * this driver already polls while waiting for a finger serve the same purpose.
 *
 * A finger presses the reading down, so the signal is background - frame. It
 * is written back inverted so that squash_frame_linear() still produces
 * libfprint's convention of dark ridges on a light background.
 *
 * @param frame the captured frame, rewritten in place
 * @param background the last idle frame, or NULL if none has been seen yet
 */
static void goodix52xd_apply_background(Goodix52xdPix* frame,
                                        const Goodix52xdPix* background)
{
    guint hist[GOODIX52XD_PIX_MAX + 1] = { 0 };
    guint clip = (GOODIX52XD_FRAME_SIZE * GOODIX52XD_STRETCH_CLIP_PERMILLE)
                 / 1000;
    guint lo = 0, hi = GOODIX52XD_PIX_MAX;
    guint seen, i;

    if (!background) {
        fp_dbg("no Goodix 52xd background frame yet; using the frame as captured");
        return;
    }

    for (i = 0; i != GOODIX52XD_FRAME_SIZE; ++i) {
        gint signal = (gint) background[i] - (gint) frame[i];

        if (signal < 0)
            signal = 0;
        if (signal > GOODIX52XD_PIX_MAX)
            signal = GOODIX52XD_PIX_MAX;

        frame[i] = (Goodix52xdPix) signal;
        hist[signal]++;
    }

    for (seen = 0, i = 0; i <= GOODIX52XD_PIX_MAX; ++i) {
        seen += hist[i];
        if (seen > clip) {
            lo = i;
            break;
        }
    }
    for (seen = 0, i = GOODIX52XD_PIX_MAX + 1; i-- > 0;) {
        seen += hist[i];
        if (seen > clip) {
            hi = i;
            break;
        }
    }
    /* Every pixel inside the clipped tails, i.e. a frame with no contrast. */
    if (hi <= lo) {
        lo = 0;
        hi = GOODIX52XD_PIX_MAX;
    }

    fp_dbg("Goodix 52xd background subtracted; signal window %%u-%%u", lo, hi);

    for (i = 0; i != GOODIX52XD_FRAME_SIZE; ++i) {
        guint signal = frame[i];

        if (signal < lo)
            signal = lo;
        if (signal > hi)
            signal = hi;

        frame[i] = (Goodix52xdPix) (GOODIX52XD_PIX_MAX - signal);
    }
}

/**
 * @brief Squashes the 12 bit pixels of a raw frame into the 4 bit pixels used
""" % {"clip": clip},
))

# 3./4. Keep the empty frames instead of dropping them. g_steal_pointer leaves
#       frame NULL, so the g_free that followed becomes a no-op.
edits.append((
    """        if (empty) {
            g_free(frame);
            g_slist_free_full(g_steal_pointer(&self->frames), g_free);
            self->scan_frame_count = 0;
            if (self->image_frame_count < GOODIX52XD_EMPTY_POLL_FRAMES) {
""",
    """        if (empty) {
            /* 52xd-background: an idle frame is the calibration frame the next
               capture needs, so keep it rather than throwing it away. */
            goodix52xd_note_idle_frame(self, g_steal_pointer(&frame));
            g_slist_free_full(g_steal_pointer(&self->frames), g_free);
            self->scan_frame_count = 0;
            if (self->image_frame_count < GOODIX52XD_EMPTY_POLL_FRAMES) {
""",
))

edits.append((
    """        g_free(frame);

        if (empty) {
            gboolean report_finger_off = self->finger_reported;
""",
    """        /* 52xd-background: the finger has just come off, so this frame is
           idle too and is the freshest calibration frame available. */
        if (empty)
            goodix52xd_note_idle_frame(self, g_steal_pointer(&frame));
        g_free(frame);

        if (empty) {
            gboolean report_finger_off = self->finger_reported;
""",
))

# 5. The capture itself.
edits.append((
    """        fpi_image_device_report_finger_status(FP_IMAGE_DEVICE(dev), TRUE);
        self->finger_reported = TRUE;

        img = goodix52xd_image_from_frame(frame);
""",
    """        fpi_image_device_report_finger_status(FP_IMAGE_DEVICE(dev), TRUE);
        self->finger_reported = TRUE;

        goodix52xd_repair_border(frame);
        goodix52xd_apply_background(frame, self->background);
        self->background_used = TRUE;
        img = goodix52xd_image_from_frame(frame);
""",
))

# 6. Lifetime. Deliberately NOT freed in goodix52xd_reset_state(), which runs
#    on every deactivate: fprintd deactivates the device between operations,
#    and a verify is a single scan that begins with the finger already coming
#    down, so it would never get to see an idle frame of its own. Enrolled
#    templates and verify scans have to come out of the same pipeline or
#    nothing matches. The pattern is a property of the silicon, and it is
#    refreshed at every finger-off, so carrying it across an activation is
#    safe. It only goes when the device is closed.
edits.append((
    """static void dev_deinit(FpImageDevice *img_dev) {
  FpDevice *dev = FP_DEVICE(img_dev);
  GError *error = NULL;

  goodix52xd_cancel_scan(FPI_DEVICE_GOODIXTLS52XD(img_dev));
  goodix52xd_reset_state(FPI_DEVICE_GOODIXTLS52XD(img_dev));
""",
    """static void dev_deinit(FpImageDevice *img_dev) {
  FpDevice *dev = FP_DEVICE(img_dev);
  FpiDeviceGoodixTls52XD *self = FPI_DEVICE_GOODIXTLS52XD(img_dev);
  GError *error = NULL;

  goodix52xd_cancel_scan(self);
  goodix52xd_reset_state(self);
  /* 52xd-background: kept across deactivations, dropped when we close. */
  g_clear_pointer(&self->background, g_free);
""",
))

edits.append((
    """    goodix52xd_reset_state(self);
    g_clear_pointer(&self->otp, g_free);
""",
    """    goodix52xd_reset_state(self);
    g_clear_pointer(&self->background, g_free);
    g_clear_pointer(&self->otp, g_free);
""",
))

edits.append((
    """    self->frames = NULL;
    self->finger_reported = FALSE;
""",
    """    self->frames = NULL;
    self->background = NULL;
    self->background_used = FALSE;
    self->finger_reported = FALSE;
""",
))

for old, _ in edits:
    if source.count(old) != 1:
        sys.stderr.write("anchor not found exactly once:\n%s\n" % old)
        sys.exit(1)

for old, new in edits:
    source = source.replace(old, new)

with open(path, "w") as handle:
    handle.write(source)
PYEOF
    then
        ok "52XD captures now have the sensor's background frame subtracted."
        (( clip != 20 )) && info "Stretch clip: $clip permille."
    else
        warn "Could not add background subtraction to goodix52xd.c — the driver has changed."
        warn "The reader will still enrol, but the matcher may not tell fingers apart."
    fi
    return 0
}

# Grafts SIGFM onto the tree. The patch adds libfprint/sigfm/ and rebases the
# core matcher hooks from goodix-fp-linux-dev/libfprint@sigfm (libfprint 1.94.5)
# onto 1.94.10. sync_repo() checks out --force, so this reapplies every run.
apply_sigfm_patch() {
    local src="$1"
    local marker="$src/libfprint/fpi-image-device.h"

    [[ -n "$SIGFM_PATCH_FILE" ]] || die "The SIGFM patch was never located."

    # Guard on a *tracked* file. sync_repo() runs `git checkout --force`, which
    # reverts every tracked change but leaves libfprint/sigfm/ in place because
    # it is untracked. Keying off that directory made a re-run skip the patch
    # while the core hooks it needs had already been reverted, and the build
    # then failed with "FpImageDeviceClass has no member named 'algorithm'".
    if grep -q 'FPI_DEVICE_ALGO_SIGFM' "$marker" 2>/dev/null \
       && [[ -d "$src/libfprint/sigfm" ]]; then
        dbg "SIGFM port already applied."
        return 0
    fi

    # Half-applied either way round: start from the pristine checkout. This runs
    # before the other three patches, so nothing else is lost.
    git -C "$src" checkout --force -- . >/dev/null 2>&1 || true
    rm -rf "$src/libfprint/sigfm"

    if ! git -C "$src" apply --whitespace=nowarn "$SIGFM_PATCH_FILE"; then
        err "The SIGFM patch did not apply to this libfprint checkout."
        err "It is pinned to $SIGFM_LIBFPRINT_REF; HEAD is $(git -C "$src" rev-parse --short HEAD)."
        die "Re-run without --sigfm, or report this with the log at $LOG_FILE."
    fi
    ok "Applied the SIGFM port ($(grep -c '^diff --git' "$SIGFM_PATCH_FILE") files)."
    return 0
}

# Opts the 52XD driver into the SIGFM matcher. Nothing else changes matcher, so
# every other driver keeps NBIS.
patch_libfprint_52xd_sigfm() {
    local file="$1/libfprint/drivers/goodixtls/goodix52xd.c"

    [[ -f "$file" ]] || return 0
    if grep -q 'FPI_DEVICE_ALGO_SIGFM' "$file"; then
        dbg "goodix52xd.c already selects SIGFM."
        return 0
    fi

    if python3 - "$file" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as handle:
    source = handle.read()

old = "  dev_class->scan_type = FP_SCAN_TYPE_PRESS;\n"

new = """  dev_class->scan_type = FP_SCAN_TYPE_PRESS;

  /* Selected by goodix-fp-setup --sigfm. NBIS finds too few minutiae in this
     sensor's 64x80 frames to tell fingers apart; SIGFM matches SIFT keypoints
     instead. bz3_threshold below is reused as the SIGFM score threshold, and
     the two are on completely different scales. */
  img_dev_class->algorithm = FPI_DEVICE_ALGO_SIGFM;
"""

if source.count(old) != 1:
    sys.exit(1)

with open(path, "w") as handle:
    handle.write(source.replace(old, new))
PYEOF
    then
        ok "Switched the 52XD driver to the SIGFM matcher."
    else
        die "Could not switch the 52XD driver to SIGFM — the driver has changed."
    fi
}

# Prints the part of a failed build that actually says what went wrong. ninja
# ends with a summary of its own, so the real diagnostics are the compiler lines
# above it; show those rather than the last 40 lines of progress output.
show_build_failure() {
    local clog="$1"

    err "libfprint failed to build. The compiler said:"
    printf '\n'
    if grep -nE "error:|Error [0-9]|FAILED:|fatal error" "$clog" >/dev/null 2>&1; then
        grep -E -B2 -A6 "error:|fatal error|FAILED:" "$clog" | tail -n 60
    else
        tail -n 40 "$clog"
    fi
    printf '\n'
    if (( SIGFM )); then
        err "This build used --sigfm, which is experimental. Re-run without it to get a"
        err "working reader, and please report the errors above."
    fi
    die "Full build log: $clog (also copied into $LOG_FILE)"
}

build_libfprint() {
    step "Building patched libfprint"

    local src="$SRC_DIR/libfprint" build="$SRC_DIR/libfprint/build-goodix"
    rm -rf "$build"

    if (( SIGFM )); then
        apply_sigfm_patch "$src"
        patch_libfprint_52xd_sigfm "$src"
    fi

    patch_libfprint_52xd_psk "$src"
    patch_libfprint_52xd_finger_off "$src"
    patch_libfprint_52xd_background "$src"
    patch_libfprint_52xd_bz3 "$src"

    local optfile="" candidate
    for candidate in meson_options.txt meson.options; do
        if [[ -f "$src/$candidate" ]]; then optfile="$src/$candidate"; break; fi
    done

    # GCC 14+ turns incompatible-pointer-types into an error; these forks
    # predate that. Same workaround the AUR package applies.
    local cargs="-Wno-incompatible-pointer-types"

    if (( SIGFM )); then
        # SIFT on a 64x80 sensor yields far fewer keypoints than the port's
        # upstream default of 25 assumes. Lower this if every scan fails with
        # "Not enough keypoints found".
        local minkp="${GOODIX_SIGFM_MIN_KEYPOINTS:-25}"
        [[ "$minkp" =~ ^[0-9]+$ ]] || die "GOODIX_SIGFM_MIN_KEYPOINTS must be a number."
        cargs+=" -DSIGFM_MIN_KEYPOINTS=$minkp"
        info "SIGFM minimum keypoints: $minkp"
    fi

    local opts=(
        --prefix="$PREFIX"
        --libdir=lib
        --buildtype=release
        -Dc_args="$cargs"
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

    # meson prints compiler errors on stdout, not stderr, so both streams have to
    # be captured or a failed build reports nothing at all.
    local clog="$build/compile.log"

    info "Compiling (this takes a minute or two)"
    if ! "$MESON_BIN" compile -C "$build" >"$clog" 2>&1; then
        warn "Build failed; retrying with the compatibility patch applied to meson.build."
        if grep -q "common_cflags = cc.get_supported_arguments(\[" "$src/meson.build" \
           && ! grep -q "Wno-incompatible-pointer-types" "$src/meson.build"; then
            sed -i "/common_cflags = cc.get_supported_arguments(\[/a \    '-Wno-incompatible-pointer-types'," "$src/meson.build"
            rm -rf "$build"
            "$MESON_BIN" setup "$build" "$src" "${opts[@]}" >/dev/null || die "meson setup failed after patching."
            "$MESON_BIN" compile -C "$build" >"$clog" 2>&1 || show_build_failure "$clog"
        else
            show_build_failure "$clog"
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
        if (( SIGFM )); then
            info "Matcher         : SIGFM (SIFT) — experimental, re-enrolment required"
        else
            info "Matcher         : NBIS (libfprint default)"
        fi
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
