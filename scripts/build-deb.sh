#!/usr/bin/env bash
#
# build-deb.sh
#
# Builds a .deb that installs libfprint (Ubuntu's source, patched with the
# goodix53x5 driver) under /opt/libfprint-goodix and activates it for fprintd
# through a systemd drop-in. It does NOT replace the system libfprint.
#
# Prerequisites:
#   - run ./scripts/prepare-source.sh first (fetches Ubuntu's libfprint source
#     and integrates the goodix53x5 driver into it)
#   - build deps installed (meson, ninja, libopencv-dev, libssl-dev, ...)
#   - dpkg-dev (for dpkg-shlibdeps)
#
# Usage:
#   ./scripts/build-deb.sh
#   REVISION=2 ./scripts/build-deb.sh
#   SRC_DIR=/path/to/libfprint-source ./scripts/build-deb.sh
#
# Environment variables (all optional):
#   SRC_DIR     libfprint source tree   (default: <repo>/work/libfprint-*)
#   BUILD_DIR   meson build directory   (default: $SRC_DIR/build-goodix)
#   OUT_DIR     where the .deb is put   (default: <repo>/out)
#   REVISION    packaging revision      (default: 1)
#   PREFIX      install prefix          (default: /opt/libfprint-goodix)
#   RECONFIGURE set to 1 to wipe and reconfigure the meson build dir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PKG_NAME="libfprint-goodix53x5-opt"
PREFIX="${PREFIX:-/opt/libfprint-goodix}"
REVISION="${REVISION:-1}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
RECONFIGURE="${RECONFIGURE:-0}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- locate source tree ------------------------------------------------------
if [[ -z "${SRC_DIR:-}" ]]; then
    SRC_DIR="$(find "$REPO_ROOT/work" -maxdepth 1 -type d -name 'libfprint-*' 2>/dev/null | sort | tail -n1 || true)"
fi
[[ -n "${SRC_DIR:-}" && -f "$SRC_DIR/meson.build" ]] \
    || die "no libfprint source found (run ./scripts/prepare-source.sh first, or set SRC_DIR=/path/to/libfprint-source)"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build-goodix}"

# --- sanity checks -----------------------------------------------------------
for tool in meson ninja dpkg-deb dpkg-shlibdeps dpkg-architecture; do
    command -v "$tool" >/dev/null || die "missing tool: $tool (try: sudo apt install meson ninja-build dpkg-dev)"
done

grep -q "goodix53x5" "$SRC_DIR/libfprint/meson.build" \
    || die "goodix53x5 driver is not wired into $SRC_DIR/libfprint/meson.build (run ./scripts/prepare-source.sh first)"
grep -q "goodix53x5" "$SRC_DIR/meson.build" \
    || die "goodix53x5 is not in $SRC_DIR/meson.build (run ./scripts/prepare-source.sh first)"
[[ -f "$SRC_DIR/libfprint/drivers/goodix53x5/goodix53x5.c" ]] \
    || die "driver sources missing from $SRC_DIR/libfprint/drivers/goodix53x5/"

ARCH="$(dpkg --print-architecture)"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
LIBDIR_REL="lib/$MULTIARCH"

UPSTREAM_VER="$(grep -m1 -oP "version:\s*'\K[^']+" "$SRC_DIR/meson.build")" \
    || die "could not read version from $SRC_DIR/meson.build"
DEB_VER="${UPSTREAM_VER}-1goodix${REVISION}"
DEB_FILE="${PKG_NAME}_${DEB_VER}_${ARCH}.deb"

log "Source:   $SRC_DIR"
log "Version:  $DEB_VER ($ARCH)"
log "Prefix:   $PREFIX"

# --- configure + build -------------------------------------------------------
if [[ "$RECONFIGURE" == "1" && -d "$BUILD_DIR" ]]; then
    log "Wiping $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

if [[ ! -d "$BUILD_DIR" ]]; then
    log "Configuring meson"
    meson setup "$BUILD_DIR" "$SRC_DIR" \
        --prefix="$PREFIX" \
        --libdir="$LIBDIR_REL" \
        -Ddrivers=all \
        -Dgtk-examples=false \
        -Ddoc=false \
        -Dudev_rules=disabled \
        -Dudev_hwdb=disabled
else
    log "Reusing existing build dir $BUILD_DIR"
    configured_prefix="$(meson introspect "$BUILD_DIR" --buildoptions 2>/dev/null \
        | python3 -c 'import sys,json; print(next(o["value"] for o in json.load(sys.stdin) if o["name"]=="prefix"))' 2>/dev/null || true)"
    if [[ -n "$configured_prefix" && "$configured_prefix" != "$PREFIX" ]]; then
        die "build dir was configured with prefix '$configured_prefix', expected '$PREFIX' (rerun with RECONFIGURE=1)"
    fi
fi

log "Compiling"
ninja -C "$BUILD_DIR"

# --- stage -------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/pkgroot"

log "Staging install into $ROOT"
DESTDIR="$ROOT" ninja -C "$BUILD_DIR" install >/dev/null

# Runtime-only package: drop headers and pkg-config files.
rm -rf "$ROOT$PREFIX/include" "$ROOT$PREFIX/$LIBDIR_REL/pkgconfig"
# ...and libfprint's installed test binaries (not needed at runtime).
rm -rf "$ROOT$PREFIX/libexec" "$ROOT$PREFIX/share/installed-tests"

# Strip shared objects.
find "$ROOT$PREFIX" -type f -name '*.so*' -exec strip --strip-unneeded {} + 2>/dev/null || true

# --- dependencies ------------------------------------------------------------
log "Computing shared-library dependencies"
mkdir -p "$WORK/debian"
cat > "$WORK/debian/control" <<EOF
Source: $PKG_NAME
Section: libs
Priority: optional
Maintainer: local <local@localhost>

Package: $PKG_NAME
Architecture: any
Description: temporary control file for dpkg-shlibdeps
EOF

mapfile -t SO_FILES < <(find "$ROOT$PREFIX" -type f -name '*.so*')
[[ ${#SO_FILES[@]} -gt 0 ]] || die "no shared objects found under $ROOT$PREFIX"

SHLIBDEPS="$(cd "$WORK" && dpkg-shlibdeps -O --ignore-missing-info \
                -l"$ROOT$PREFIX/$LIBDIR_REL" "${SO_FILES[@]}" 2>/dev/null \
             | sed 's/^shlibs:Depends=//' || true)"
[[ -n "$SHLIBDEPS" ]] || die "dpkg-shlibdeps produced no dependencies; run it manually to see why"
log "Depends: $SHLIBDEPS"

# --- packaging metadata ------------------------------------------------------
install -d "$ROOT/DEBIAN" \
           "$ROOT/usr/lib/systemd/system/fprintd.service.d" \
           "$ROOT/usr/share/doc/$PKG_NAME"

cat > "$ROOT/usr/lib/systemd/system/fprintd.service.d/goodix53x5.conf" <<EOF
[Service]
Environment=LD_LIBRARY_PATH=$PREFIX/$LIBDIR_REL
EOF

cat > "$ROOT/usr/share/doc/$PKG_NAME/copyright" <<'EOF'
libfprint: LGPL-2.1-or-later (https://gitlab.freedesktop.org/libfprint/libfprint)
Goodix HTK32 driver: https://github.com/AndyHazz/goodix53x5-libfprint (LGPL-2.1-or-later)
EOF

INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $DEB_VER
Architecture: $ARCH
Maintainer: ${USER:-local} <${USER:-local}@$(hostname)>
Installed-Size: $INSTALLED_SIZE
Depends: fprintd, $SHLIBDEPS
Section: libs
Priority: optional
Description: libfprint with Goodix HTK32 (27c6:5385) driver, installed in /opt
 Local build of Ubuntu's libfprint $UPSTREAM_VER plus the third-party
 goodix53x5 driver. Installed under $PREFIX and activated for fprintd
 through a systemd drop-in. Does not replace the system libfprint.
EOF

for script in postinst postrm; do
    cat > "$ROOT/DEBIAN/$script" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl try-restart fprintd.service >/dev/null 2>&1 || true
exit 0
EOF
    chmod 755 "$ROOT/DEBIAN/$script"
done

# --- build the deb -----------------------------------------------------------
mkdir -p "$OUT_DIR"
log "Building $DEB_FILE"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT_DIR/$DEB_FILE" >/dev/null

echo
dpkg-deb -I "$OUT_DIR/$DEB_FILE"
echo
dpkg-deb -c "$OUT_DIR/$DEB_FILE" | sed -n '1,25p'   # not head: avoids SIGPIPE under pipefail

echo
log "Done: $OUT_DIR/$DEB_FILE"
echo "Install:  sudo apt install '$OUT_DIR/$DEB_FILE'"
echo "Remove:   sudo apt remove $PKG_NAME"
echo "(If you installed to $PREFIX by hand earlier, run:"
echo "   sudo systemctl revert fprintd && sudo rm -rf $PREFIX   first)"
