#!/usr/bin/env bash
#
# Build a distributable Ladybird.app from a completed macOS build, then produce
# a zip and a DMG alongside it.
#
# Run from the repository root. Outputs, relative to the ladybird checkout:
#   Ladybird.app.zip
#   ladybird-macos.dmg

set -euo pipefail

cd "$(dirname "$0")/../../ladybird"

BUILD_DIR="${BUILD_DIR:-Build/release}"

# The bundle in $BUILD_DIR/bin is deliberately NOT relocatable: its
# Contents/lib is a symlink into the build tree (see UI/CMakeLists.txt).
# The install rules remove that symlink and copy the real libraries in.
cmake --install "$BUILD_DIR" --prefix "$PWD/dist"
APP="$PWD/dist/bundle/Ladybird.app"

# InstallRules.cmake copies $prefix/lib into the bundle before the lagom
# libraries are installed there, so don't rely on that ordering. Only .dylib:
# the build tree's lib/ also holds ~330 MB of static libs.
mkdir -p "$APP/Contents/lib"
cp -a "$BUILD_DIR"/lib/*.dylib "$APP/Contents/lib/"

# The lagom libraries pull in vcpkg dependencies (skia, harfbuzz, libjpeg,
# libpng, libavif, libwebp, openssl, ...) which are not installed.
cp -a "$BUILD_DIR"/vcpkg_installed/*/lib/*.dylib "$APP/Contents/lib/"

rpaths_of() {
    otool -l "$1" | awk '/LC_RPATH/ { f = 1 } f && /path / { print $2; f = 0 }'
}

# cmake --install already rewrites some rpaths, so adding one unconditionally
# fails with "would duplicate path".
add_rpath() {
    rpaths_of "$1" | grep -Fxq "$2" || install_name_tool -add_rpath "$2" "$1"
}

# Binaries carry absolute rpaths into the build tree. Strip those and point at
# the bundled libraries instead.
for bin in "$APP"/Contents/MacOS/* "$APP"/Contents/lib/*.dylib; do
    # grep exits 1 when a binary has no build-tree rpath, which pipefail would
    # otherwise turn into a failure.
    { rpaths_of "$bin" | grep "^$PWD" || true; } \
        | while read -r rpath; do
            install_name_tool -delete_rpath "$rpath" "$bin" 2>/dev/null || true
          done
done
for bin in "$APP"/Contents/MacOS/*; do
    add_rpath "$bin" @executable_path/../lib
done
# The libraries reference each other by @rpath as well, so let them resolve
# siblings in their own directory.
for lib in "$APP"/Contents/lib/*.dylib; do
    add_rpath "$lib" @loader_path
done

# install_name_tool invalidates signatures, so re-sign last. This is an ad-hoc
# signature, so Gatekeeper still needs "Open Anyway" on first run.
codesign --force --deep --sign - --entitlements Meta/DebugEntitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Zip the bundle ourselves. Uploading the .app directory directly makes
# upload-artifact root the archive at the least common ancestor of the matched
# files, which strips the Contents/ level and breaks the bundle.
rm -f Ladybird.app.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" Ladybird.app.zip

# Create DMG disk image
rm -rf ladybird-macos
mkdir -p ladybird-macos
cp -R "$APP" ladybird-macos/
ln -sf /Applications ladybird-macos/Applications
hdiutil create -volname "Ladybird" -srcfolder ladybird-macos -ov -format UDZO ladybird-macos.dmg
