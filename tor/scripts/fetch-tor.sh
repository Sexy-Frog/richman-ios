#!/usr/bin/env bash
# Fetches the prebuilt Tor xcframework into Vendor/ and repacks it so SwiftPM
# accepts the static library name.
#
# Upstream (iCepa/Tor.framework 409.17.1) ships `tor.a`; SwiftPM refuses static
# libraries that are not `lib*.a`, so every slice is renamed to `libtor.a`.
# Idempotent: an existing Vendor/tor.xcframework is reused.
set -euo pipefail

VERSION="${TOR_VERSION:-409.17.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor"
XCFRAMEWORK="$DEST/tor.xcframework"

if [ -d "$XCFRAMEWORK" ]; then
    echo "tor.xcframework already present at $XCFRAMEWORK"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading tor.xcframework $VERSION (150 MB)…"
curl -fL --retry 3 --retry-delay 2 \
    -o "$TMP/tor.xcframework.zip" \
    "https://github.com/iCepa/Tor.framework/releases/download/${VERSION}/tor.xcframework.zip"

unzip -q "$TMP/tor.xcframework.zip" -d "$TMP"

# Rename tor.a -> libtor.a in every platform slice, and point the xcframework
# manifest at the new names.
while IFS= read -r -d '' archive; do
    mv "$archive" "$(dirname "$archive")/libtor.a"
done < <(find "$TMP/tor.xcframework" -name 'tor.a' -print0)
perl -pi -e 's{<string>tor\.a</string>}{<string>libtor.a</string>}g' \
    "$TMP/tor.xcframework/Info.plist"

mkdir -p "$DEST"
mv "$TMP/tor.xcframework" "$XCFRAMEWORK"
echo "Installed $XCFRAMEWORK"
