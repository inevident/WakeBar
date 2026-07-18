#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="WakeBar"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$DIST_DIR/.${APP_NAME}-release-staging"
STAGING_APP="$STAGING_DIR/$APP_NAME.app"

usage() {
    cat <<'EOF'
Prepare a Developer ID-signed and notarized WakeBar archive locally.

This script is intentionally separate from build-app.sh. It never publishes a
release, and it refuses to run without an explicit confirmation flag plus a
Developer ID identity and Keychain-backed notary profile.

Usage:
  WAKEBAR_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
  WAKEBAR_NOTARY_PROFILE="WakeBar-notary" \
  ./Scripts/prepare-notarized-release.sh --sign-and-notarize

Options:
  -h, --help               Show this help without building or signing.
  --sign-and-notarize      Explicitly authorize the local release workflow.

The notary profile must already exist in Keychain. Create it with:
  xcrun notarytool store-credentials "WakeBar-notary" \
    --apple-id "YOUR_APPLE_ACCOUNT" \
    --team-id "YOUR_TEAM_ID"
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --sign-and-notarize)
        if (( $# != 1 )); then
            usage >&2
            exit 64
        fi
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

SIGNING_IDENTITY="${WAKEBAR_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${WAKEBAR_NOTARY_PROFILE:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "WAKEBAR_SIGNING_IDENTITY is required." >&2
    exit 64
fi

if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "WAKEBAR_SIGNING_IDENTITY must name a Developer ID Application certificate." >&2
    exit 64
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "WAKEBAR_NOTARY_PROFILE is required." >&2
    exit 64
fi

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
    echo "Signing identity is not available in the current keychain:" >&2
    echo "  $SIGNING_IDENTITY" >&2
    exit 69
fi

echo "Validating the Keychain-backed notary profile…"
/usr/bin/xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null

UPLOAD_ARCHIVE=""
NOTARY_RESULT=""

cleanup() {
    rm -rf "$STAGING_DIR"
    if [[ -n "$UPLOAD_ARCHIVE" ]]; then
        rm -f "$UPLOAD_ARCHIVE"
    fi
    if [[ -n "$NOTARY_RESULT" ]]; then
        rm -f "$NOTARY_RESULT"
    fi
}
trap cleanup EXIT

"$ROOT/Scripts/build-app.sh" release

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$STAGING_APP"

echo "Applying Developer ID signature and hardened runtime to a staging copy…"
/usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$STAGING_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$STAGING_APP/Contents/Info.plist")"
UPLOAD_ARCHIVE="$DIST_DIR/.${APP_NAME}-${VERSION}-notarization.zip"
NOTARY_RESULT="$DIST_DIR/.${APP_NAME}-${VERSION}-notarization.json"
FINAL_ARCHIVE="$DIST_DIR/${APP_NAME}-${VERSION}-macOS.zip"
CHECKSUM_FILE="$FINAL_ARCHIVE.sha256"

rm -f "$UPLOAD_ARCHIVE" "$NOTARY_RESULT" "$FINAL_ARCHIVE" "$CHECKSUM_FILE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$STAGING_APP" \
    "$UPLOAD_ARCHIVE"

echo "Submitting to Apple's notary service…"
if ! /usr/bin/xcrun notarytool submit "$UPLOAD_ARCHIVE" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$NOTARY_RESULT"; then
    /bin/cat "$NOTARY_RESULT" >&2
    exit 70
fi

NOTARY_STATUS="$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT")"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    /bin/cat "$NOTARY_RESULT" >&2
    echo "Apple did not accept the notarization submission." >&2
    exit 70
fi

echo "Stapling and validating the notarization ticket…"
/usr/bin/xcrun stapler staple "$STAGING_APP"
/usr/bin/xcrun stapler validate "$STAGING_APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

# Rebuild the downloadable archive after stapling so the distributed copy
# carries its ticket even when Gatekeeper cannot reach Apple's servers.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$STAGING_APP" \
    "$FINAL_ARCHIVE"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 "${FINAL_ARCHIVE:t}" > "${CHECKSUM_FILE:t}"
)

echo "Prepared locally; nothing was published:"
echo "  $FINAL_ARCHIVE"
echo "  $CHECKSUM_FILE"
