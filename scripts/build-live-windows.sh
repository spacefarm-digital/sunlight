#!/bin/bash
# Builds Sunlight's live-window pieces into build/live-windows/:
#   payload              the Dock add-on (arm64e, as the Dock is), from LiveWindows/osax/payload.m
#   loader               injects the add-on into the Dock (arm64e, to share the Dock's library addresses)
#   SunlightLiveWindows  the helper the app runs as root; carries both in its __TEXT segment
# scripts/package.sh copies the helper into Sunlight.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/live-windows
SRC=LiveWindows
WARN="-Wall -Wextra -Wno-unused-parameter"
mkdir -p "$OUT"

# Dock.app on macOS 15 is arm64e PAC ABI v0 (otool: caps USR00, the high byte of
# cpusubtype is 0x80). Xcode 26's clang stamps an arm64e executable as ABI v1
# (USR01, 0x81). The kernel will not inject a v1 image into that Dock, so the
# loader exits 1 and live windows never answer. v0 and v1 use the same
# instructions; only this header byte differs. Pin both images after linking.
# This script builds thin arm64e only.
pin_pac_abi_v0() {
    local bin="$1"
    local caps
    caps=$(otool -hv "$bin" | awk '/^MH_MAGIC_64/ { print $4; exit }')
    case "$caps" in
        USR00) ;;
        USR01)
            printf '\x80' | dd of="$bin" bs=1 seek=11 count=1 conv=notrunc 2>/dev/null
            codesign -f -s - "$bin" >/dev/null
            ;;
        *)
            echo "build-live-windows: $bin has unexpected arm64e caps '${caps:-none}'" >&2
            exit 1
            ;;
    esac
    caps=$(otool -hv "$bin" | awk '/^MH_MAGIC_64/ { print $4; exit }')
    if [[ "$caps" != "USR00" ]]; then
        echo "build-live-windows: $bin is '${caps:-none}' after pinning, wanted USR00" >&2
        exit 1
    fi
}

xcrun clang "$SRC/osax/payload.m" $WARN -shared -fPIC -fobjc-arc -O2 -mmacosx-version-min=15.0 -arch arm64e -o "$OUT/payload" \
    -F/System/Library/PrivateFrameworks -framework SkyLight -framework Foundation -framework CoreGraphics
xcrun clang "$SRC/osax/loader.m" -O3 -mmacosx-version-min=15.0 -arch arm64e -o "$OUT/loader" -framework Cocoa
pin_pac_abi_v0 "$OUT/payload"
pin_pac_abi_v0 "$OUT/loader"
xcrun clang "$SRC/helper.m" $WARN -std=c11 -fobjc-arc -O2 -mmacosx-version-min=15.0 -arch arm64 \
    -o "$OUT/SunlightLiveWindows" -framework Cocoa -framework Security \
    -Wl,-sectcreate,__TEXT,__payload,"$OUT/payload" -Wl,-sectcreate,__TEXT,__loader,"$OUT/loader"
echo "Built $OUT/SunlightLiveWindows"
