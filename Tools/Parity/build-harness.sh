#!/bin/zsh
# Builds the parity harness: the app's Swift sources (minus the @main entry point)
# compiled as a macOS command-line tool, driven by Harness/main.swift.
set -euo pipefail

HERE=${0:A:h}
PROJECT=${HERE:h:h}
SRC=$PROJECT/AnkiOS
OUT=${ANKIOS_PARITY_BUILD:-/tmp/ankios-parity/build}
mkdir -p "$OUT/obj"

SDK=$(xcrun --sdk macosx --show-sdk-path)
FSRS=$SRC/FSRSBridge/AnkiFSRS.xcframework/macos-arm64_x86_64
ZSTD=$SRC/Import/ZstdNative

for c in "$ZSTD/AnkiZstd.c" "$ZSTD/src/zstd.c"; do
  obj="$OUT/obj/${${c:t}:r}.o"
  if [[ ! -f "$obj" || "$c" -nt "$obj" ]]; then
    xcrun clang -c -O2 -arch arm64 -isysroot "$SDK" -mmacosx-version-min=26.0 \
      -I "$ZSTD" -DZSTD_MULTITHREAD=0 "$c" -o "$obj"
  fi
done

sed 's/^@main$//' "$SRC/App/AnkiOSApp.swift" > "$OUT/AnkiOSApp.swift"
sources=("${(@f)$(find "$SRC" -name '*.swift' ! -path '*/App/AnkiOSApp.swift' | sort)}")
sources+=("$OUT/AnkiOSApp.swift")
sources+=("${(@f)$(find "$HERE/Harness" -name '*.swift' | sort)}")

xcrun swiftc -swift-version 6 "${ANKIOS_PARITY_OPTIMIZATION:--Onone}" -wmo \
  -target arm64-apple-macos26.0 -sdk "$SDK" \
  -module-cache-path "$OUT/module-cache" \
  -D ANKIOS_PARITY_HARNESS \
  -module-name AnkiOS \
  -import-objc-header "$ZSTD/AnkiZstd-Bridging-Header.h" \
  -I "$SRC/AnkiBackendBridge" \
  -I "$FSRS/Headers" -L "$FSRS" -lankios_fsrs_macos \
  -Xlinker -dead_strip \
  "$OUT"/obj/*.o \
  "${sources[@]}" \
  -o "$OUT/ankios-harness"

echo "$OUT/ankios-harness"
