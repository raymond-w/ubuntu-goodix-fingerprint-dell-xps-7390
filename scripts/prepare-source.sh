#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# prepare-source.sh
#
# Prepares a libfprint source tree that includes the Goodix HTK32 driver:
#
#   1. clones the third-party driver into  work/goodix53x5-libfprint
#   2. fetches Ubuntu's libfprint source (`apt source libfprint`) into work/
#   3. copies the driver into that tree and integrates it into the meson build
#   4. verifies the integration
#
# Afterwards run ./scripts/build-deb.sh.
#
# Requires deb-src entries to be enabled (see README) and: git, patch,
# python3, dpkg-dev.
#
# Environment variables (all optional):
#   DRIVER_URL   driver repository   (default: https://github.com/AndyHazz/goodix53x5-libfprint)
#   DRIVER_REF   commit/tag/branch of the driver to use (default: remote HEAD)
#   WORK_DIR     working directory   (default: <repo>/work)
#
# The exact driver commit used is recorded in work/DRIVER_COMMIT.
#
# Only tested against Ubuntu's libfprint 1.95.2+tod1. Other versions may need
# manual meson edits (see README).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORK="${WORK_DIR:-$REPO_ROOT/work}"
DRIVER_URL="${DRIVER_URL:-https://github.com/AndyHazz/goodix53x5-libfprint}"
DRIVER_REF="${DRIVER_REF:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in git patch python3 dpkg-source apt; do
    command -v "$tool" >/dev/null || die "missing tool: $tool (try: sudo apt install git patch python3 dpkg-dev)"
done

mkdir -p "$WORK"
cd "$WORK"

# --- 1. driver ---------------------------------------------------------------
if [[ -d goodix53x5-libfprint/.git ]]; then
    log "Updating driver checkout"
    git -C goodix53x5-libfprint fetch --quiet origin
else
    log "Cloning driver from $DRIVER_URL"
    git clone --quiet "$DRIVER_URL" goodix53x5-libfprint
fi
git -C goodix53x5-libfprint checkout --quiet --detach "${DRIVER_REF:-origin/HEAD}"
DRIVER_COMMIT="$(git -C goodix53x5-libfprint rev-parse HEAD)"
echo "$DRIVER_COMMIT" > DRIVER_COMMIT
log "Driver commit: $DRIVER_COMMIT"

# --- 2. libfprint source -----------------------------------------------------
shopt -s nullglob
src_dirs=(libfprint-*/)
if (( ${#src_dirs[@]} == 0 )); then
    log "Fetching Ubuntu's libfprint source (apt source libfprint)"
    apt source libfprint \
        || die "'apt source libfprint' failed. Enable deb-src entries first (see README), then run 'sudo apt update'."
    src_dirs=(libfprint-*/)
fi
(( ${#src_dirs[@]} == 1 )) \
    || die "expected exactly one libfprint-*/ directory in $WORK, found ${#src_dirs[@]}; remove the extras"
SRC="$(cd "${src_dirs[0]}" && pwd)"

SRC_VER="$(grep -m1 -oP "version:\s*'\K[^']+" "$SRC/meson.build" || true)"
INSTALLED_VER="$(dpkg-query -W -f='${Version}' libfprint-2-2 2>/dev/null || true)"
log "libfprint source: ${SRC_VER:-unknown} (installed libfprint-2-2: ${INSTALLED_VER:-none})"

# --- 3. integrate the driver -------------------------------------------------
log "Copying driver sources into the tree"
# install.sh copies the files and tries to patch meson; on 1.95.x the patch is
# rejected in part, which is handled below, so its exit status is ignored.
"$WORK/goodix53x5-libfprint/install.sh" "$SRC" || true

log "Applying meson-integration.patch (rejected or already-applied hunks are expected)"
(
    cd "$SRC"
    patch -p1 --forward --batch --no-backup-if-mismatch -r - \
        < "$WORK/goodix53x5-libfprint/meson-integration.patch"
) || true

log "Applying the remaining meson edits"
python3 "$SCRIPT_DIR/apply-meson-edits.py" "$SRC"

# --- 4. verify ---------------------------------------------------------------
log "Verifying integration"
check() {   # check <extended-regex> <file> <description>
    grep -qE "$1" "$2" || die "integration incomplete: $3 (in $2)"
}
check "'goodix53x5': files\(" "$SRC/libfprint/meson.build" "driver_sources entry missing"
check "libsigfm"              "$SRC/libfprint/meson.build" "SIGFM static library missing"
check "opencv_dep"            "$SRC/libfprint/meson.build" "OpenCV dependency missing"
check "^[[:space:]]*'goodix53x5',[[:space:]]*$" "$SRC/meson.build" "not in default_drivers"
check "'goodix53x5' : \[ 'openssl' \]"          "$SRC/meson.build" "driver_helper_mapping entry missing"
[[ -f "$SRC/libfprint/drivers/goodix53x5/goodix53x5.c" ]] || die "driver sources were not copied"
[[ -f "$SRC/libfprint/sigfm/sigfm.cpp" ]] || die "SIGFM sources were not copied"

log "Source tree ready: $SRC"
echo "Next: ./scripts/build-deb.sh"
