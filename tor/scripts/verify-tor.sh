#!/usr/bin/env bash
# Fails when a Tor.framework slice exports anything besides the public Tor C
# API. Run after scripts/fetch-tor.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="$ROOT/Vendor/tor.xcframework"

test -d "$XCFRAMEWORK" || { echo "missing $XCFRAMEWORK" >&2; exit 1; }

found=0
while IFS= read -r -d '' binary; do
    found=$((found + 1))
    echo "== $binary"
    globals="$(nm -gU "$binary" | awk '{print $NF}' | grep '^_' | sort -u || true)"
    test -n "$globals" || { echo "::error::$binary exports no symbols" >&2; exit 1; }

    # __mh_dylib_header is bookkeeping, not a crypto symbol.
    bad="$(printf '%s\n' "$globals" | grep -vE '^(_tor_|__mh_)' || true)"
    if [ -n "$bad" ]; then
        echo "::error::$binary still exports non-Tor symbols (BoringSSL collision risk):" >&2
        printf '%s\n' "$bad" | head -n 20 >&2
        exit 1
    fi

    printf '%s\n' "$globals" | grep -qx '_tor_run_main' \
        || { echo "::error::$binary is missing _tor_run_main" >&2; exit 1; }
done < <(find "$XCFRAMEWORK" -type f -path '*Tor.framework/Tor' -print0)

test "$found" -ge 1 || { echo "::error::no Tor.framework slices found" >&2; exit 1; }
echo "Tor.framework exports only the public tor_* API ($found slices)"
