#!/usr/bin/env bash
# Fetches the prebuilt Tor xcframework and repacks every slice as a dynamic
# Tor.framework that exports only the public `tor_*` C API.
#
# Why: tor.xcframework bundles OpenSSL 3.6.5 while libsignal_ffi.a links
# BoringSSL. Both export the same C symbols (CRYPTO_*, SSL_*, EVP_*, ...). ld64
# binds an undefined reference to the first archive that defines it, so Tor's
# OpenSSL-3.6 call to `CRYPTO_get_ex_new_index(class_index, ...)` was resolved
# to BoringSSL's ABI-incompatible `CRYPTO_get_ex_new_index(class, out, ...)`
# (crash at launch in ex_data.c). The archive is LTO bitcode, so symbols can
# only be hidden on a real link. Relinking each slice into a dylib with an
# export list keeps Tor's OpenSSL/libevent/lzma inside the framework, where
# BoringSSL can neither satisfy nor interpose them.
#
# Idempotent: an xcframework that already contains Tor.framework is reused;
# a previously cached static xcframework is converted in place.
set -euo pipefail

VERSION="${TOR_VERSION:-409.17.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor"
XCFRAMEWORK="$DEST/tor.xcframework"

has_framework() {
    [ -d "$XCFRAMEWORK" ] \
        && [ -n "$(find "$XCFRAMEWORK" -maxdepth 3 -name 'Tor.framework' -print -quit 2>/dev/null)" ]
}

if has_framework; then
    echo "tor.xcframework already contains Tor.framework"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -d "$XCFRAMEWORK" ]; then
    echo "Converting the existing static tor.xcframework"
    SRC="$XCFRAMEWORK"
else
    echo "Downloading tor.xcframework $VERSION (150 MB)…"
    curl -fL --retry 3 --retry-delay 2 \
        -o "$WORK/tor.xcframework.zip" \
        "https://github.com/iCepa/Tor.framework/releases/download/${VERSION}/tor.xcframework.zip"
    unzip -q "$WORK/tor.xcframework.zip" -d "$WORK"
    SRC="$WORK/tor.xcframework"
fi

# Only the documented Tor C API stays visible; everything else (OpenSSL,
# libevent, liblzma) becomes local to the framework.
printf '_tor_*\n' > "$WORK/exports.txt"

frameworks=()
for archive in "$SRC"/*/tor.a; do
    [ -f "$archive" ] || continue
    slice="$(basename "$(dirname "$archive")")"
    case "$slice" in
        *macos*)     platform=macos;         sdk=macosx;         minver=14.0; platform_name=MacOSX ;;
        *simulator*) platform=ios-simulator; sdk=iphonesimulator; minver=17.0; platform_name=iPhoneSimulator ;;
        *)           platform=ios;           sdk=iphoneos;        minver=17.0; platform_name=iPhoneOS ;;
    esac
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    sdkver="$(xcrun --sdk "$sdk" --show-sdk-version)"

    dylibs=()
    for arch in $(lipo -archs "$archive"); do
        thin="$WORK/$slice-$arch.a"
        # Device slices are already thin; lipo -thin rejects non-fat input.
        if lipo -info "$archive" | grep -q '^Non-fat file'; then
            cp "$archive" "$thin"
        else
            lipo "$archive" -thin "$arch" -output "$thin"
        fi

        echo "Linking Tor.framework/$slice/$arch"
        # Seed the public API instead of -all_load: some archived members are
        # never pulled by a normal Tor link and have unresolved internal
        # references (e.g. proto_ext_or.o -> _ext_or_cmd_new).
        ld -dylib -arch "$arch" \
            -platform_version "$platform" "$minver" "$sdkver" \
            -syslibroot "$sysroot" \
            -u _tor_run_main \
            -u _tor_main \
            -u _tor_api_get_provider_version \
            -u _tor_main_configuration_new \
            -u _tor_main_configuration_free \
            -u _tor_main_configuration_set_command_line \
            -u _tor_main_configuration_setup_control_socket \
            "$thin" \
            -lz -lSystem \
            -install_name @rpath/Tor.framework/Tor \
            -exported_symbols_list "$WORK/exports.txt" \
            -o "$WORK/$slice-$arch.dylib"
        dylibs+=("$WORK/$slice-$arch.dylib")
    done

    fw="$WORK/$slice/Tor.framework"
    mkdir -p "$fw"
    if [ "${#dylibs[@]}" -eq 1 ]; then
        cp "${dylibs[0]}" "$fw/Tor"
    else
        lipo -create "${dylibs[@]}" -output "$fw/Tor"
    fi

    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Tor</string>
    <key>CFBundleIdentifier</key><string>works.kelvins.tor</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Tor</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>${platform_name}</string></array>
    <key>MinimumOSVersion</key><string>${minver}</string>
</dict>
</plist>
PLIST

    frameworks+=(-framework "$fw")
done

test "${#frameworks[@]}" -gt 0 || { echo "no Tor slices found" >&2; exit 1; }

xcodebuild -create-xcframework "${frameworks[@]}" -output "$WORK/out.xcframework"
rm -rf "$XCFRAMEWORK"
mkdir -p "$DEST"
mv "$WORK/out.xcframework" "$XCFRAMEWORK"
echo "Installed dynamic $XCFRAMEWORK"
