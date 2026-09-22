#!/bin/bash
# Builds a Glint release that installed copies pick up on their own, through Sparkle:
#
#   Tools/release.sh 1.1 notes.md
#
# It sets the version in the project (the build number goes up by one), archives a Release
# build, signs it with Developer ID, puts it in a DMG, has Apple notarize the DMG and staples the
# ticket, signs the DMG with Glint's update key, and writes appcast.xml: the published entries
# plus this one. Nothing is uploaded; the last lines say how to publish.
#
# Installed copies read https://github.com/uaburak/glint/releases/latest/download/appcast.xml,
# so the DMG and appcast.xml both go on a GitHub release, and that release must be the latest.
#
# Once per Mac:
#   - A "Developer ID Application" certificate: Xcode › Settings › Accounts › Manage Certificates › +.
#   - Notary credentials, with an app-specific password from account.apple.com:
#       xcrun notarytool store-credentials glint-notary --apple-id <apple id> --team-id Q6GDNC3V8B
#   - Glint's update key (EdDSA) in the login keychain. It was made with Sparkle's generate_keys;
#     keep a copy (generate_keys -x <file>) somewhere safe: without it no update can ever be
#     installed by the copies already out there. On another Mac: generate_keys -f <file>.
set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"
if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "usage: Tools/release.sh <version> [notes.md]   e.g. Tools/release.sh 1.1 notes.md" >&2
    exit 64
fi
if [[ -n "$NOTES" && ! -f "$NOTES" ]]; then
    echo "error: no release notes at $NOTES" >&2
    exit 66
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Glint.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
TEAM_ID="Q6GDNC3V8B"
REPO="uaburak/glint"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
NOTARY_PROFILE="${NOTARY_PROFILE:-glint-notary}"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/release/$VERSION"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
DMG="$OUT/Glint-$VERSION.dmg"
TAG="v$VERSION"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

# Everything that can fail for want of setup is checked before the version changes.
step "Checking the setup"
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme Glint -derivedDataPath "$DERIVED" >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle's tools aren't at $SPARKLE_BIN"
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 \
    || die "the update key isn't in the login keychain (import it with $SPARKLE_BIN/generate_keys -f <file>)"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Glint/Info.plist")"
[[ "$("$SPARKLE_BIN/generate_keys" -p)" == "$PLIST_KEY" ]] \
    || die "the keychain's update key doesn't match SUPublicEDKey in Glint/Info.plist"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notary credentials named $NOTARY_PROFILE (see the top of this script)"

CURRENT_BUILD="$(grep -m1 -E 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);/\1/')"
BUILD=$((CURRENT_BUILD + 1))
MIN_SYSTEM="$(grep -m1 -E 'MACOSX_DEPLOYMENT_TARGET = ' "$PBXPROJ" | sed -E 's/.*= ([0-9.]+);/\1/')"

step "Glint $VERSION (build $BUILD)"
# A release that fails part way leaves the project at the version it had.
cp "$PBXPROJ" "$OUT/project.pbxproj.before"
FINISHED=0
trap '[[ $FINISHED == 1 ]] || { cp "$OUT/project.pbxproj.before" "$PBXPROJ"; echo "Version change undone." >&2; }' EXIT
sed -i '' -E \
    -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/" \
    "$PBXPROJ"

step "Archiving"
xcodebuild archive -project "$PROJECT" -scheme Glint -configuration Release \
    -derivedDataPath "$DERIVED" -archivePath "$OUT/Glint.xcarchive" \
    -allowProvisioningUpdates -quiet

step "Signing with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/Glint.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
APP="$OUT/export/Glint.app"
codesign --verify --deep --strict "$APP"
SIGNING="$(codesign -dvv "$APP" 2>&1)"
grep -q "^Authority=Developer ID Application" <<< "$SIGNING" \
    || die "the exported app isn't signed with Developer ID"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] \
    || die "the exported app doesn't carry build $BUILD"

step "Making the DMG"
ditto "$APP" "$OUT/dmg/Glint.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Glint" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" -quiet
# The DMG gets the same signature as the app when the certificate is on this Mac; with only
# Xcode's cloud-managed one it stays unsigned, which notarization accepts.
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application:.*($TEAM_ID)" | awk '{print $2}' || true)"
if [[ -n "$IDENTITY" ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

step "Notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$OUT/notarization.json" || true
STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$OUT/notarization.json" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
    SUBMISSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$OUT/notarization.json" 2>/dev/null || true)"
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization: ${STATUS:-no answer} (details above and in $OUT/notarization.json)"
fi
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null \
    || echo "note: Gatekeeper didn't assess the DMG itself (normal when it's unsigned); the app inside is notarized."

step "Signing the update and writing appcast.xml"
SIGNATURE="$("$SPARKLE_BIN/sign_update" -p "$DMG")"
LENGTH="$(stat -f%z "$DMG")"
if curl -fsSL "$FEED_URL" -o "$OUT/previous-appcast.xml" 2>/dev/null; then
    PREVIOUS="$OUT/previous-appcast.xml"
else
    PREVIOUS=""
    echo "No published appcast yet; starting a new one."
fi
/usr/bin/python3 "$ROOT/Tools/appcast.py" \
    ${PREVIOUS:+--previous "$PREVIOUS"} \
    --out "$OUT/appcast.xml" \
    --version "$VERSION" --build "$BUILD" --minimum-system "$MIN_SYSTEM" \
    --url "https://github.com/$REPO/releases/download/$TAG/Glint-$VERSION.dmg" \
    --length "$LENGTH" --signature "$SIGNATURE" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    ${NOTES:+--notes "$NOTES"}
"$SPARKLE_BIN/sign_update" --verify "$DMG" "$SIGNATURE" >/dev/null \
    || die "the DMG's update signature doesn't verify"
FINISHED=1

step "Ready"
cat <<EOF
  $DMG
  $OUT/appcast.xml

The project is now at $VERSION ($BUILD); commit that before tagging.

Publish: a GitHub release tagged $TAG on $REPO with both files attached, marked as the latest.
  Web: https://github.com/$REPO/releases/new?tag=$TAG
  gh:  gh release create $TAG "$DMG" "$OUT/appcast.xml" --repo $REPO --title "Glint $VERSION"${NOTES:+ --notes-file "$NOTES"}

Installed copies see it at their next daily check, or right away with "Güncellemeleri Denetle…".
EOF
