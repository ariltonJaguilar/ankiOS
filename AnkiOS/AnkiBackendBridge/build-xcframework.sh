#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR="${TMPDIR:-/tmp}/AnkiBackendXCFramework"
TARGET_DIR="$TEMP_DIR/target"
ARTIFACT_DIR="$TEMP_DIR/artifacts"
IOS_DIR="$TEMP_DIR/ios/Headers"
IOS_SIM_DIR="$TEMP_DIR/ios-sim/Headers"

mkdir -p "$TARGET_DIR" "$ARTIFACT_DIR" "$IOS_DIR" "$IOS_SIM_DIR"

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  if [[ "$target" == *-apple-ios-sim || "$target" == x86_64-apple-ios ]]; then
    IPHONEOS_DEPLOYMENT_TARGET=26.0 CFLAGS="-mios-simulator-version-min=26.0 ${CFLAGS:-}" CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$ROOT/Cargo.toml" --release --target "$target"
  else
    IPHONEOS_DEPLOYMENT_TARGET=26.0 CFLAGS="-miphoneos-version-min=26.0 ${CFLAGS:-}" CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$ROOT/Cargo.toml" --release --target "$target"
  fi
  cp "$TARGET_DIR/$target/release/libankios_anki_backend_bridge.a" "$ARTIFACT_DIR/$target.a"
  CARGO_TARGET_DIR="$TARGET_DIR" cargo clean --manifest-path "$ROOT/Cargo.toml" --target "$target"
done

rm -f "$IOS_DIR/module.modulemap" "$IOS_SIM_DIR/module.modulemap"
cp "$ROOT/AnkiBackend.h" "$IOS_DIR/"
cp "$ROOT/AnkiBackend.h" "$IOS_SIM_DIR/"

lipo -create \
  "$ARTIFACT_DIR/aarch64-apple-ios-sim.a" \
  "$ARTIFACT_DIR/x86_64-apple-ios.a" \
  -output "$TEMP_DIR/libankios_anki_backend_ios_sim.a"

rm -rf "$TEMP_DIR/AnkiBackend.xcframework"
xcodebuild -create-xcframework \
  -library "$ARTIFACT_DIR/aarch64-apple-ios.a" -headers "$IOS_DIR" \
  -library "$TEMP_DIR/libankios_anki_backend_ios_sim.a" -headers "$IOS_SIM_DIR" \
  -output "$TEMP_DIR/AnkiBackend.xcframework"

rm -rf "$ROOT/AnkiBackend.xcframework"
mv "$TEMP_DIR/AnkiBackend.xcframework" "$ROOT/AnkiBackend.xcframework"
rm -rf "$TARGET_DIR" "$ARTIFACT_DIR"
