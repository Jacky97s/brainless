#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Brainless.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Override with SDK=/path/to/MacOSX26.5.sdk when the default SDK lacks the SwiftUI macro plugin
SDK="${SDK:-$(xcrun --show-sdk-path)}"
clang -c -fobjc-arc -O2 -target arm64-apple-macosx14.0 -isysroot "$SDK" -o build/ExceptionCatcher.o Sources/ObjC/ExceptionCatcher.m
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -sdk "$SDK" -import-objc-header Sources/ObjC/ExceptionCatcher.h \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework ApplicationServices -framework ServiceManagement -framework SwiftUI \
  Sources/*.swift build/ExceptionCatcher.o -o "$APP/Contents/MacOS/Brainless"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - -i app.whispry.mac -r='designated => identifier "app.whispry.mac"' "$APP"
echo "built: $APP"
