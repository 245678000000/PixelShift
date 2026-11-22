#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/PixelShift.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o $APP/Contents/MacOS/PixelShift
cp Resources/Info.plist $APP/Contents/
if [ ! -f build/AppIcon.icns ]; then
  swift Resources/make_icon.swift build/icon.png
  mkdir -p build/AppIcon.iconset
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build/icon.png --out build/AppIcon.iconset/icon_${sz}x${sz}.png >/dev/null
    sips -z $((sz*2)) $((sz*2)) build/icon.png --out build/AppIcon.iconset/icon_${sz}x${sz}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns $APP/Contents/Resources/
codesign --force -s - $APP
echo "Built $APP"
