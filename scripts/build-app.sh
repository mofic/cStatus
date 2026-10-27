#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache -c release -debug-info-format none
binary_dir=$(swift build --disable-sandbox --cache-path .build/cache -c release --show-bin-path)
app="$PWD/dist/cStatus.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/cStatus" "$app/Contents/MacOS/cStatus"
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf 'Built: %s\n' "$app"
