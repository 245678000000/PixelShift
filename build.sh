#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/PixelShift.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
mkdir -p build/obj
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 Sources/*.swift -o build/obj/PixelShift-$arch
done
lipo -create build/obj/PixelShift-arm64 build/obj/PixelShift-x86_64 -output $APP/Contents/MacOS/PixelShift
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
if [ "$1" = "--zip" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ditto -c -k --keepParent $APP build/PixelShift-$VERSION.zip
  echo "Packed build/PixelShift-$VERSION.zip"
fi
echo "Built $APP"
