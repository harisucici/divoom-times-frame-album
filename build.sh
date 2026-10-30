#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP="$PROJECT_ROOT/dist/TimesFrame 相册管理.app"

mkdir -p "$BUILD_ROOT/module-cache" "$APP/Contents/MacOS"

SWIFT_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache" \
CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache" \
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Photos \
  "$PROJECT_ROOT/TimesFrameAlbum.swift" "$PROJECT_ROOT/MacPhotoLibrary.swift" \
  -o "$APP/Contents/MacOS/TimesFrameAlbum"

cp "$PROJECT_ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
print "已生成：$APP"
