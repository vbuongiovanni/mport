#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release binary of mport and packages it into dist/.
#
# Usage: scripts/release.sh
#
# Optional environment:
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
#                   Defaults to ad-hoc ("-"), which runs on any Mac as long as the file
#                   isn't quarantined (i.e. fetched with curl/brew rather than a browser).
#   NOTARY_PROFILE  notarytool keychain profile. When set, the zip is submitted for
#                   notarization. Requires a Developer ID SIGN_IDENTITY.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/.*version: "([^"]+)".*/\1/p' mport/Mport.swift)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
NAME="mport-$VERSION-macos-universal"
BUILD_DIR=.build/release
ARCHIVE="$BUILD_DIR/mport.xcarchive"
STAGE="$BUILD_DIR/stage"
DIST_DIR=dist

rm -rf "$ARCHIVE" "$STAGE"
mkdir -p "$STAGE" "$DIST_DIR"

echo "==> Archiving mport $VERSION"
xcodebuild archive \
    -project mport.xcodeproj \
    -scheme mport \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$ARCHIVE" \
    ARCHS="arm64 x86_64" \
    -quiet

cp "$ARCHIVE/Products/usr/local/bin/mport" "$STAGE/mport"

# Xcode signs with the local Apple Development cert, which other Macs don't trust,
# so re-sign with the distribution identity (dropping Xcode's injected entitlements).
echo "==> Signing with identity: $SIGN_IDENTITY"
sign_flags=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_flags+=(--timestamp)
fi
codesign "${sign_flags[@]}" "$STAGE/mport"
codesign --verify --strict "$STAGE/mport"
"$STAGE/mport" --version > /dev/null

echo "==> Packaging"
rm -f "$DIST_DIR/$NAME.zip" "$DIST_DIR/$NAME.zip.sha256" "$DIST_DIR/$NAME.dSYM.zip"
ditto -c -k "$STAGE" "$DIST_DIR/$NAME.zip"
ditto -c -k --keepParent "$ARCHIVE/dSYMs/mport.dSYM" "$DIST_DIR/$NAME.dSYM.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DIST_DIR/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
fi

(cd "$DIST_DIR" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

echo "==> Done"
ls -lh "$DIST_DIR/$NAME".*
