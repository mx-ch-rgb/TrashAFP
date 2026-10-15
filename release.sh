#!/bin/zsh
# Archive, signe (Developer ID), notarise et crée le DMG de TrashAFP.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

TEAM="D24PYPLQFG"
PROFILE="trashafp-notary"
cd "${0:A:h}"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "Certificat Developer ID Application introuvable."; exit 1; }
echo "Identité : $IDENTITY"

OUT="dist"; rm -rf "$OUT" build/release; mkdir -p "$OUT"

xcodebuild -project TrashAFP.xcodeproj -scheme TrashAFP -configuration Release \
  -derivedDataPath build/release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build

APP="build/release/Build/Products/Release/TrashAFP.app"
codesign --verify --deep --strict --verbose=2 "$APP"
cp -R "$APP" "$OUT/"

DMG="$OUT/TrashAFP.dmg"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname TrashAFP -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "OK : $DMG"
