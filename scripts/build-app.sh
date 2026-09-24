#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/CoreBars.app"
MODULE_CACHE="$ROOT/.build/ModuleCache"

cd "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Vendor/macmon/macmon" "$APP/Contents/Resources/macmon"
cp "$ROOT/Vendor/macmon/LICENSE" "$APP/Contents/Resources/macmon-LICENSE"
cp -R "$ROOT/Resources/Assets" "$APP/Contents/Resources/Assets"
chmod +x "$APP/Contents/Resources/macmon"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun clang \
    -fobjc-arc \
    -fmodules \
    -mmacosx-version-min=13.0 \
    -framework AppKit \
    -framework IOKit \
    "$ROOT/SourcesObjC/main.m" \
    -o "$APP/Contents/MacOS/CoreBars"

codesign --force --sign - "$APP/Contents/Resources/macmon"
codesign --force --deep --sign - "$APP"
echo "$APP"
