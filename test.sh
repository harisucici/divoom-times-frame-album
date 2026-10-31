#!/bin/zsh
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$ROOT/.build/module-cache"
SWIFT_MODULE_CACHE_PATH="$ROOT/.build/module-cache" CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
swiftc -D FRAME_TEST -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Photos -framework Security -framework CryptoKit \
  "$ROOT/TimesFrameAlbum.swift" "$ROOT/MacPhotoLibrary.swift" "$ROOT/DeviceSettings.swift" "$ROOT/WatchfaceWorkbench.swift" "$ROOT/Tests/Regression.swift" \
  -o "$ROOT/.build/Regression"
"$ROOT/.build/Regression" "$@"

SWIFT_MODULE_CACHE_PATH="$ROOT/.build/module-cache" CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
swiftc -D FRAME_TEST -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Photos -framework Security -framework CryptoKit \
  "$ROOT/TimesFrameAlbum.swift" "$ROOT/MacPhotoLibrary.swift" "$ROOT/DeviceSettings.swift" "$ROOT/WatchfaceWorkbench.swift" "$ROOT/Tests/Lifecycle.swift" \
  -o "$ROOT/.build/Lifecycle"
"$ROOT/.build/Lifecycle"

SWIFT_MODULE_CACHE_PATH="$ROOT/.build/module-cache" CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
swiftc -D FRAME_TEST -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework Photos -framework Security -framework CryptoKit \
  "$ROOT/TimesFrameAlbum.swift" "$ROOT/MacPhotoLibrary.swift" "$ROOT/DeviceSettings.swift" "$ROOT/WatchfaceWorkbench.swift" "$ROOT/Tests/WatchfaceRegression.swift" \
  -o "$ROOT/.build/WatchfaceRegression"
"$ROOT/.build/WatchfaceRegression" "$@"
