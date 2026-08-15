#!/usr/bin/env bash
# Exercises patch_libfprint_52xd_background() end to end, on a machine that
# cannot build libfprint itself (macOS, no gudev/udev).
#
# It clones the pinned libfprint fork, runs the real function out of
# install.sh against it, slices the patched image pipeline straight back out
# of the driver, and compiles and runs test_pipeline.c over it. So what gets
# tested is the code that ships, not a copy of it.
#
# Checks: idempotency across the git checkout --force that sync_repo() does,
# the opt-out and tuning environment variables, and the pipeline's numerical
# behaviour including the equivalence property that a capture with no
# background yet comes out byte for byte as it did before the patch.
#
# Needs: git, python3, a C compiler, glib-2.0 via pkg-config.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="$REPO/install.sh"
WORK="${GOODIX_TEST_WORK:-${TMPDIR:-/tmp}/goodix-pipeline-test}"
TREE="$WORK/libfprint"
DRIVER="$TREE/libfprint/drivers/goodixtls/goodix52xd.c"

# Must match SIGFM_LIBFPRINT_REF in install.sh: the anchors this patch keys on
# only exist in that tree.
REF="${GOODIX_TEST_REF:-72cacc37ca6524390a112e7df7bf2c6972be8217}"
REPO_URL="${GOODIX_LIBFPRINT_REPO:-https://github.com/djnz00/libfprint.git}"

info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
dbg()  { :; }

for tool in git python3 pkg-config; do
    command -v "$tool" >/dev/null || die "$tool is required."
done
pkg-config --exists glib-2.0 || die "glib-2.0 development files are required."
CC="${CC:-cc}"
command -v "$CC" >/dev/null || die "no C compiler ($CC)."

# The real functions, with the entry point neutered so nothing installs.
# shellcheck disable=SC1090
source <(sed 's|^main "\$@" </dev/null$|:|' "$INSTALL")

if [[ ! -d "$TREE/.git" ]]; then
    info "Cloning $REPO_URL (once; kept in $WORK)"
    mkdir -p "$WORK"
    git clone -q "$REPO_URL" "$TREE"
fi
git -C "$TREE" checkout -q --force "$REF"
info "libfprint at $(git -C "$TREE" rev-parse --short HEAD)"

fresh() { git -C "$TREE" checkout -q --force -- .; }

printf '\n== patch application ==\n'
patch_libfprint_52xd_background "$TREE"
grep -q '52xd-background' "$DRIVER" || die "the patch left no marker in the driver."
ok "applies to a pristine tree"

before="$(git -C "$TREE" diff --stat -- "$DRIVER")"
patch_libfprint_52xd_background "$TREE"
[[ "$before" == "$(git -C "$TREE" diff --stat -- "$DRIVER")" ]] \
    || die "a second run changed the driver again."
ok "second run is a no-op"

# What sync_repo() does on every install: tracked changes are reverted, so the
# patch has to notice and re-apply rather than trusting its own marker.
fresh
grep -q '52xd-background' "$DRIVER" && die "checkout --force did not revert the patch."
patch_libfprint_52xd_background "$TREE"
grep -q '52xd-background' "$DRIVER" || die "the patch did not survive a re-run after checkout --force."
ok "re-applies after checkout --force"

fresh
GOODIX_KEEP_STOCK_IMAGE_PIPELINE=1 patch_libfprint_52xd_background "$TREE"
grep -q '52xd-background' "$DRIVER" && die "GOODIX_KEEP_STOCK_IMAGE_PIPELINE did not opt out."
ok "GOODIX_KEEP_STOCK_IMAGE_PIPELINE opts out"

fresh
GOODIX_52XD_STRETCH_CLIP_PERMILLE=5 patch_libfprint_52xd_background "$TREE"
grep -q 'GOODIX52XD_STRETCH_CLIP_PERMILLE 5$' "$DRIVER" \
    || die "GOODIX_52XD_STRETCH_CLIP_PERMILLE did not reach the driver."
ok "GOODIX_52XD_STRETCH_CLIP_PERMILLE reaches the driver"

fresh
GOODIX_52XD_STRETCH_CLIP_PERMILLE=nonsense patch_libfprint_52xd_background "$TREE" >/dev/null
grep -q 'GOODIX52XD_STRETCH_CLIP_PERMILLE 20$' "$DRIVER" \
    || die "a bad clip value was not rejected in favour of the default."
ok "a bad clip value falls back to 20"

printf '\n== pipeline behaviour ==\n'
fresh
patch_libfprint_52xd_background "$TREE" >/dev/null

python3 - "$DRIVER" "$WORK/pipeline.inc" <<'PYEOF'
import sys

driver, out = sys.argv[1], sys.argv[2]
source = open(driver).read()
start = source.index("/* 52xd-background: 12-bit sensor")
# Everything the patch adds, up to the untouched function that consumes it.
end = source.index("static FpImage*\ngoodix52xd_image_from_frame")
open(out, "w").write(source[start:end])
PYEOF

"$CC" -std=gnu99 -Wall -Wextra -Werror=implicit -O1 \
    -I"$WORK" $(pkg-config --cflags glib-2.0) \
    "$HERE/test_pipeline.c" $(pkg-config --libs glib-2.0) \
    -o "$WORK/test_pipeline"
"$WORK/test_pipeline"
