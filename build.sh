#!/bin/bash
# Собирает YDiskSync.app (universal: arm64 + Intel, macOS 11+).
#
#   ./build.sh                         — сборка; подписывается, если задан SIGN_ID
#                                        (в .sign.local или в командной строке), иначе ad-hoc
#   SIGN_ID="<хэш или имя сертификата Developer ID Application>" \\
#   NOTARY_PROFILE="<профиль notarytool>" ./build.sh
#                                      — подпись Developer ID + нотаризация, на выходе YDiskSync.zip
#   NOTARY_PROFILE= ./build.sh         — быстрая сборка с подписью, без нотаризации
set -e
cd "$(dirname "$0")"
[ -f .sign.local ] && . ./.sign.local
APP="YDiskSync.app"
TMP="$(mktemp -d)"

rm -rf build "$APP" YDiskSync.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos11.0  Sources/*.swift -o "$TMP/arm64"
swiftc -O -target x86_64-apple-macos11.0 Sources/*.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/YDiskSync"

cp Info.plist "$APP/Contents/Info.plist"

swiftc -O Tools/make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if [ -n "$NOTARY_PROFILE" ]; then
    ditto -c -k --keepParent "$APP" "$TMP/notarize.zip"
    xcrun notarytool submit "$TMP/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
  fi
  ditto -c -k --keepParent "$APP" YDiskSync.zip
  echo "Готово (подписано Developer ID): $(pwd)/YDiskSync.zip"
else
  codesign --force --sign - "$APP"
  echo "Готово (ad-hoc подпись, только для своего Мака): $(pwd)/$APP"
fi
rm -rf "$TMP"
