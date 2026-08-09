#!/usr/bin/env bash
#
# goodix-fp-debug — collects everything needed to diagnose a Goodix reader.
#
#   curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/debug.sh | sudo bash
#
# It changes nothing on your system. It reads state, then runs two capture
# tests against the reader and records exactly what they print:
#
#   1. libfprint's own `enroll` example, with all driver debugging on. This is
#      the code path fprintd uses, minus D-Bus and polkit.
#   2. goodix-fp-dump's capture demo, which implements the same TLS handshake
#      independently (it shells out to `openssl s_server -psk`). If this one
#      works and libfprint doesn't, the bug is in libfprint. It is skipped
#      unless the reader is already on the target firmware with a valid PSK,
#      so it can never trigger a reflash.
#
# fprintd is stopped for the duration (it holds the USB interface) and
# restarted on the way out, including on Ctrl-C.
#
# The report is written to /tmp/goodix-fp-debug.log and printed at the end so
# you can copy it straight out of the terminal.
#
# The whole script is wrapped in functions and invoked at the very bottom so
# that `curl | bash` cannot execute a half-downloaded file.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.1"

# ---------------------------------------------------------------------------
# Paths — must match install.sh
# ---------------------------------------------------------------------------

readonly STATE_DIR="/opt/goodix-fp-setup"
readonly SRC_DIR="$STATE_DIR/src"
readonly VENV_DIR="$STATE_DIR/venv"
readonly BIN_DIR="$STATE_DIR/bin"
readonly PREFIX="$STATE_DIR/libfprint"
readonly LIBDIR="$PREFIX/lib"
readonly DROPIN="/etc/systemd/system/fprintd.service.d/10-goodix-libfprint.conf"
readonly LDSOCONF="/etc/ld.so.conf.d/000-goodix-fp-setup.conf"
readonly SETUP_LOG="/var/log/goodix-fp-setup.log"
readonly BUILD_DIR="$SRC_DIR/libfprint/build-goodix"
readonly FPDUMP_DIR="$SRC_DIR/goodix-fp-dump"

readonly GOODIX_VID="27c6"
SYSFS_USB="${GOODIX_SYSFS_USB:-/sys/bus/usb/devices}"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

REPORT="${GOODIX_DEBUG_OUT:-/tmp/goodix-fp-debug.log}"
CAPTURE_SECS=45
DO_CAPTURE=1
DO_PRINT=1

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

DEV_PID=""
DEV_NAME=""
DRIVER_MODULE=""
TARGET_FW=""
EXTRA_FW=""
FPRINTD_MASKED=0
PROBE_FIRMWARE=""
PROBE_PSK=""

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

die() { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Report helpers
# ---------------------------------------------------------------------------

rep() { printf '%s\n' "$*" >>"$REPORT"; }

sec() {
    { printf '\n\n========== %s ==========\n' "$*"; } >>"$REPORT"
    info "$*"
}

# run "label" cmd args...  — records the command, its output and its exit code.
run() {
    local label="$1"; shift
    { printf '\n--- %s ---\n$ %s\n' "$label" "$*"; } >>"$REPORT"
    if ! have "$1"; then
        rep "[skipped: $1 not installed]"
        return 0
    fi
    local rc=0
    "$@" >>"$REPORT" 2>&1 || rc=$?
    rep "[exit $rc]"
    return 0
}

# runsh "label" 'shell snippet' — same, for anything needing a pipeline.
runsh() {
    local label="$1" snippet="$2"
    { printf '\n--- %s ---\n$ %s\n' "$label" "$snippet"; } >>"$REPORT"
    local rc=0
    bash -c "$snippet" >>"$REPORT" 2>&1 || rc=$?
    rep "[exit $rc]"
    return 0
}

note() { { printf '\n[note] %s\n' "$*"; } >>"$REPORT"; }

# Diagnostics must survive a broken system: a section that fails is recorded
# and skipped, never fatal. Calling through this also relaxes `set -e` inside
# the section, so one bad command doesn't discard the rest of it.
guard() {
    local rc=0
    "$@" || rc=$?
    if (( rc )); then
        note "section '$1' stopped early (exit $rc); everything else still ran."
        warn "Section '$1' failed (exit $rc); continuing."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
goodix-fp-debug ${SCRIPT_VERSION} — collect Goodix fingerprint diagnostics

  curl -fsSL https://raw.githubusercontent.com/yesrab/goodix-521d-explanation/main/debug.sh | sudo bash

Options (pass as: ... | sudo bash -s -- --flag):
  -o, --out FILE     Write the report here (default: $REPORT).
  -t, --timeout N    Seconds to keep each capture test running (default: $CAPTURE_SECS).
      --no-capture   Collect state only; don't touch the reader.
      --no-print     Don't echo the report at the end, just write the file.
  -h, --help         This text.
  -V, --version      Print the version and exit.

Changes nothing. Stops fprintd while the capture tests run, restarts it after.
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -o|--out)      REPORT="${2:?--out needs a path}"; shift ;;
            -t|--timeout)  CAPTURE_SECS="${2:?--timeout needs a number}"; shift ;;
            --no-capture)  DO_CAPTURE=0 ;;
            --no-print)    DO_PRINT=0 ;;
            -h|--help)     usage; exit 0 ;;
            -V|--version)  echo "goodix-fp-debug $SCRIPT_VERSION"; exit 0 ;;
            *)             usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done

    [[ "$CAPTURE_SECS" =~ ^[0-9]+$ ]] || die "--timeout takes a whole number of seconds."
}

# ---------------------------------------------------------------------------
# fprintd handling
# ---------------------------------------------------------------------------

fprintd_unit_exists() {
    have systemctl && systemctl cat fprintd.service >/dev/null 2>&1
}

hold_fprintd() {
    fprintd_unit_exists || return 0
    systemctl stop fprintd.service >/dev/null 2>&1 || true
    # fprintd is D-Bus activated; mask it so nothing wakes it mid-capture.
    if systemctl mask fprintd.service >/dev/null 2>&1; then
        FPRINTD_MASKED=1
    fi
}

release_fprintd() {
    (( FPRINTD_MASKED )) || return 0
    systemctl unmask fprintd.service >/dev/null 2>&1 || true
    systemctl start fprintd.service >/dev/null 2>&1 || true
    FPRINTD_MASKED=0
}

cleanup() {
    # goodix-fp-dump leaves an openssl TLS server behind if it dies mid-capture.
    pkill -f 'openssl s_server -nocert -psk' >/dev/null 2>&1 || true
    release_fprintd
}

on_exit() { cleanup; }

# ---------------------------------------------------------------------------
# Device detection
# ---------------------------------------------------------------------------

detect_device() {
    local dir vid pid
    for dir in "$SYSFS_USB"/*; do
        [[ -r "$dir/idVendor" && -r "$dir/idProduct" ]] || continue
        vid="$(<"$dir/idVendor")"; pid="$(<"$dir/idProduct")"
        [[ "${vid,,}" == "$GOODIX_VID" ]] || continue
        DEV_PID="${pid,,}"
        [[ -r "$dir/product" ]] && DEV_NAME="$(<"$dir/product")"
        return 0
    done
    return 1
}

# Mirrors install.sh's table so the probe knows what to expect.
select_driver() {
    case "$DEV_PID" in
        5110) DRIVER_MODULE="driver_51x0"; TARGET_FW="GF_ST411SEC_APP_12117" ;;
        521d) DRIVER_MODULE="driver_52xd"; TARGET_FW="GFUSB_GM168SEC_APP_10019"
              EXTRA_FW="GFUSB_GM168SEC_APP_10034" ;;
        538d) DRIVER_MODULE="driver_53xd"; TARGET_FW="GF5298_GM168SEC_APP_13016" ;;
        *)    return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

collect_header() {
    : >"$REPORT"
    rep "goodix-fp-debug $SCRIPT_VERSION"
    rep "generated: $(date -Is 2>/dev/null || date)"
    rep "reader:    ${DEV_PID:-none found}${DEV_NAME:+ ($DEV_NAME)}"
    rep "target fw: ${TARGET_FW:-unknown}"

    sec "System"
    runsh "distro" 'cat /etc/os-release 2>/dev/null | head -n 6'
    run "kernel" uname -a
    runsh "secure boot / lockdown" 'cat /sys/kernel/security/lockdown 2>/dev/null || echo "(no lockdown file)"'
}

collect_hardware() {
    sec "Reader on the USB bus"
    runsh "goodix devices" "lsusb 2>/dev/null | grep -i '${GOODIX_VID}:' || echo '(lsusb found no ${GOODIX_VID} device)'"
    runsh "sysfs" "for d in ${SYSFS_USB}/*; do
        [ -r \"\$d/idVendor\" ] || continue
        v=\$(cat \"\$d/idVendor\"); [ \"\$v\" = '${GOODIX_VID}' ] || continue
        echo \"\$d  \$v:\$(cat \"\$d/idProduct\")  \$(cat \"\$d/product\" 2>/dev/null)\"
        echo \"  busnum=\$(cat \"\$d/busnum\" 2>/dev/null) devnum=\$(cat \"\$d/devnum\" 2>/dev/null) speed=\$(cat \"\$d/speed\" 2>/dev/null)\"
    done"
    runsh "kernel messages" "dmesg 2>/dev/null | grep -iE '${GOODIX_VID}|goodix|fingerprint' | tail -n 25 || true"
}

collect_install_state() {
    sec "Installed state"
    runsh "tree" "ls -la '$STATE_DIR' 2>/dev/null || echo '(no $STATE_DIR — install.sh has not run)'"
    runsh "installer version" "'$STATE_DIR/install.sh' --version 2>/dev/null || echo '(no saved installer)'"
    runsh "built library" "ls -la '$LIBDIR'/libfprint-2.so* 2>/dev/null || echo '(no built libfprint)'"
    runsh "libfprint commit" "git -C '$SRC_DIR/libfprint' log -1 --oneline 2>/dev/null; git -C '$SRC_DIR/libfprint' remote get-url origin 2>/dev/null"
    runsh "goodix-fp-dump commit" "git -C '$FPDUMP_DIR' log -1 --oneline 2>/dev/null"
    runsh "systemd drop-in" "cat '$DROPIN' 2>/dev/null || echo '(no drop-in)'"
    runsh "extra drop-ins" "ls -la /etc/systemd/system/fprintd.service.d/ 2>/dev/null || true"
    runsh "ld.so.conf" "cat '$LDSOCONF' 2>/dev/null || echo '(not registered system-wide)'"
    runsh "example binaries" "ls '$BUILD_DIR/examples/' 2>/dev/null || echo '(no build tree)'"

    # The fix for "Goodix TLS PSK is not configured" lives in this function.
    sec "52XD TLS PSK patch"
    local drv="$SRC_DIR/libfprint/libfprint/drivers/goodixtls/goodix52xd.c"
    if [[ -f "$drv" ]]; then
        if grep -q 'psk_10019' "$drv"; then
            rep "PATCH PRESENT — goodix52xd.c supplies the 10019 PSK."
        else
            rep "PATCH MISSING — goodix52xd.c has no 10019 PSK; enroll will fail with"
            rep "'Goodix TLS PSK is not configured'. Re-run install.sh 1.0.3 or newer."
        fi
        runsh "goodix52xd_get_tls_psk()" "sed -n '/^goodix52xd_get_tls_psk (FpDevice/,/^}/p' '$drv'"
    else
        rep "(no libfprint checkout at $drv)"
    fi
}

collect_openssl() {
    sec "OpenSSL"
    # The driver asks for exactly one ciphersuite. If the distro's security
    # level filters it out, the handshake has nothing to negotiate with.
    run "version" openssl version -a
    runsh "system security level" "grep -nE 'SECLEVEL|CipherString|MinProtocol' /etc/ssl/openssl.cnf 2>/dev/null || echo '(no SECLEVEL pin)'"
    runsh "driver ciphersuite, as configured" "openssl ciphers -s -v 'PSK-AES128-CBC-SHA256' 2>&1 || echo 'NOT AVAILABLE at the system security level'"
    runsh "driver ciphersuite, at SECLEVEL=0" "openssl ciphers -s -v 'PSK-AES128-CBC-SHA256:@SECLEVEL=0' 2>&1 || true"
    runsh "what the built library links against" "ldd '$LIBDIR'/libfprint-2.so.2 2>/dev/null | grep -iE 'ssl|crypto' || true"
}

collect_fprintd() {
    sec "fprintd"
    runsh "package version" "(dpkg -l fprintd 2>/dev/null | tail -n1) || (rpm -q fprintd 2>/dev/null) || (pacman -Q fprintd 2>/dev/null) || echo '(unknown)'"
    runsh "unit state" "systemctl status fprintd.service --no-pager 2>&1 | head -n 15 || true"
    runsh "unit environment" "systemctl show fprintd.service -p Environment 2>/dev/null || true"
    runsh "enrolled prints" "ls -laR /var/lib/fprint 2>/dev/null || echo '(nothing enrolled)'"
    runsh "recent journal" "journalctl -u fprintd.service -n 200 --no-pager 2>/dev/null || echo '(no journal)'"
}

collect_firmware_probe() {
    sec "Firmware probe (read-only)"

    if [[ ! -x "$VENV_DIR/bin/python" || ! -f "$BIN_DIR/gfp_flash.py" ]]; then
        rep "(no python environment — run install.sh first)"
        return 0
    fi
    if [[ -z "$DRIVER_MODULE" ]]; then
        rep "(unknown reader $DEV_PID — no driver mapping)"
        return 0
    fi

    local out="" rc=0
    out="$("$VENV_DIR/bin/python" "$BIN_DIR/gfp_flash.py" \
        --source-dir "$FPDUMP_DIR" --module "$DRIVER_MODULE" \
        --product "0x$DEV_PID" --extra-ok "$EXTRA_FW" --probe-only 2>&1)" || rc=$?

    { printf '\n--- probe ---\n'; printf '%s\n' "$out"; printf '[exit %d]\n' "$rc"; } >>"$REPORT"

    PROBE_FIRMWARE="$(sed -n 's/^GFP_FIRMWARE=//p' <<<"$out" | tail -n1)"
    PROBE_PSK="$(sed -n 's/^GFP_PSK_VALID=//p' <<<"$out" | tail -n1)"

    if [[ -n "$PROBE_FIRMWARE" ]]; then
        info "Firmware: $PROBE_FIRMWARE (PSK valid: ${PROBE_PSK:-?})"
    else
        warn "The probe reported no firmware (exit $rc); the report has its output."
    fi
    return 0
}

# The main event: libfprint's own enroll, with every driver message on.
capture_libfprint() {
    sec "libfprint enroll capture"

    local bin="$BUILD_DIR/examples/enroll"
    if [[ ! -x "$bin" ]]; then
        rep "(no $bin — the libfprint build tree is gone; re-run install.sh)"
        warn "libfprint's enroll example is missing; skipping this test."
        return 0
    fi

    note "Ran: G_MESSAGES_DEBUG=all $bin, answering '6' (right index) and 'y',"
    note "for ${CAPTURE_SECS}s. Watch for 'TLS server waiting to accept...' and"
    note "whether 'TLS server accept done' ever follows it."

    printf '\n'
    printf '  %sTouch the sensor now.%s Press and lift your finger repeatedly for the\n' "$C_BOLD" "$C_RESET"
    printf '  next %s seconds. Starting in 3...\n' "$CAPTURE_SECS"
    sleep 3

    local rc=0
    printf '6\ny\n' | timeout -k 5 -s INT "${CAPTURE_SECS}s" \
        env G_MESSAGES_DEBUG=all "$bin" >>"$REPORT" 2>&1 || rc=$?
    rep "[exit $rc]"
    if (( rc == 124 || rc == 130 )); then
        rep "[timed out after ${CAPTURE_SECS}s — it hung rather than failing]"
        warn "The enroll test hung (this is the symptom we're chasing)."
    else
        ok "Enroll test finished on its own (exit $rc)."
    fi
}

# Independent implementation of the same handshake, as a control.
capture_fpdump() {
    sec "goodix-fp-dump capture (control test)"

    if [[ ! -x "$VENV_DIR/bin/python" || ! -d "$FPDUMP_DIR" ]]; then
        rep "(no goodix-fp-dump checkout)"
        return 0
    fi
    # Refuse to run unless the reader is already where it should be. Upstream's
    # main() only erases and reflashes when the firmware or the PSK is wrong;
    # this guard means it will always take the run_driver() branch instead.
    if [[ "$PROBE_FIRMWARE" != "$TARGET_FW" || "$PROBE_PSK" != "True" ]]; then
        rep "SKIPPED — firmware is '${PROBE_FIRMWARE:-unknown}' and PSK valid is"
        rep "'${PROBE_PSK:-unknown}'; upstream's driver would try to reflash, so this"
        rep "test is not safe to run. Expected '$TARGET_FW' with PSK valid True."
        warn "Skipping the control test (it would risk a reflash)."
        return 0
    fi

    local wrapper
    wrapper="$(mktemp /tmp/goodix-fp-capture-XXXXXX.py)"
    cat >"$wrapper" <<'PYEOF'
# Runs goodix-fp-dump's real capture demo, answering its anti-automation
# prompt. Unlike the installer's flashing wrapper this does NOT stub
# run_driver(), so the full TLS handshake and image capture actually happen.
import builtins
import importlib
import os
import re
import sys

source, module, product = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
sys.path.insert(0, source)
os.chdir(source)


def auto_input(prompt=""):
    text = str(prompt)
    sys.stdout.write(text)
    match = re.search(r"(\d+)", text)
    answer = match.group(1) if match else ""
    sys.stdout.write(answer + "    [answered by goodix-fp-debug]\n")
    sys.stdout.flush()
    return answer


builtins.input = auto_input
importlib.import_module(module).main(product)
PYEOF

    note "Ran goodix-fp-dump's own run_driver() for ${CAPTURE_SECS}s. It performs the"
    note "TLS handshake with 'openssl s_server -psk <32 zero bytes>' on port 4433."

    printf '\n'
    printf '  %sTouch the sensor again%s for the next %s seconds. Starting in 3...\n' \
        "$C_BOLD" "$C_RESET" "$CAPTURE_SECS"
    sleep 3

    local rc=0
    timeout -k 5 -s INT "${CAPTURE_SECS}s" \
        "$VENV_DIR/bin/python" -u "$wrapper" "$FPDUMP_DIR" "$DRIVER_MODULE" "0x$DEV_PID" \
        >>"$REPORT" 2>&1 </dev/null || rc=$?
    rep "[exit $rc]"
    rm -f "$wrapper"

    if (( rc == 124 || rc == 130 )); then
        rep "[timed out after ${CAPTURE_SECS}s]"
        warn "The control test hung too — that points below libfprint."
    else
        ok "Control test finished on its own (exit $rc)."
    fi
}

collect_tail() {
    sec "Installer log (tail)"
    runsh "goodix-fp-setup.log" "tail -n 150 '$SETUP_LOG' 2>/dev/null || echo '(no installer log)'"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    [[ "$(id -u)" == "0" ]] || die "Run this with sudo — it needs raw USB access and has to stop fprintd."

    trap on_exit EXIT INT TERM

    printf '%sgoodix-fp-debug %s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"

    if detect_device; then
        select_driver || warn "Reader ${DEV_PID} is not one this script knows about."
        info "Reader: ${DEV_PID}${DEV_NAME:+ — $DEV_NAME}"
    else
        warn "No Goodix (${GOODIX_VID}) reader found on the USB bus."
    fi

    step "Collecting state"
    guard collect_header
    guard collect_hardware
    guard collect_install_state
    guard collect_openssl
    guard collect_fprintd

    if (( DO_CAPTURE )); then
        step "Testing the reader"
        info "Stopping fprintd so it releases the device"
        hold_fprintd
        guard collect_firmware_probe
        guard capture_libfprint
        guard capture_fpdump
        release_fprintd
        ok "fprintd restarted."
    else
        step "Skipping the capture tests (--no-capture)"
        note "Capture tests were skipped with --no-capture."
    fi

    guard collect_tail

    chmod 0644 "$REPORT" 2>/dev/null || true

    step "Done"
    ok "Report written to $REPORT ($(wc -l <"$REPORT" | tr -d ' ') lines)"

    if (( DO_PRINT )); then
        printf '\n%s----- BEGIN goodix-fp-debug report — copy everything below -----%s\n\n' \
            "$C_DIM" "$C_RESET"
        cat "$REPORT"
        printf '\n%s----- END goodix-fp-debug report -----%s\n' "$C_DIM" "$C_RESET"
    fi
}

main "$@"
