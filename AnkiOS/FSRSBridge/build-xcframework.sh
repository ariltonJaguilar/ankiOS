#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CARGO_MANIFEST="$ROOT/Cargo.toml"
TEMP_DIR="${TMPDIR:-/tmp}/AnkiFSRSXCFramework"
TARGET_DIR="$TEMP_DIR/target"
mkdir -p "$TARGET_DIR"

CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$CARGO_MANIFEST" --release --target aarch64-apple-ios
CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$CARGO_MANIFEST" --release --target aarch64-apple-ios-sim
CARGO_TARGET_DIR="$TARGET_DIR" cargo build --manifest-path "$CARGO_MANIFEST" --release --target x86_64-apple-ios

mkdir -p "$TEMP_DIR/ios/Headers" "$TEMP_DIR/ios-sim/Headers"
cp "$ROOT/AnkiFSRS.h" "$ROOT/module.modulemap" "$TEMP_DIR/ios/Headers/"
cp "$ROOT/AnkiFSRS.h" "$ROOT/module.modulemap" "$TEMP_DIR/ios-sim/Headers/"
lipo -create \
  "$TARGET_DIR/aarch64-apple-ios-sim/release/libankios_fsrs_bridge.a" \
  "$TARGET_DIR/x86_64-apple-ios/release/libankios_fsrs_bridge.a" \
  -output "$TEMP_DIR/libankios_fsrs_ios_sim.a"
rm -rf "$ROOT/AnkiFSRS.xcframework"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libankios_fsrs_bridge.a" -headers "$TEMP_DIR/ios/Headers" \
  -library "$TEMP_DIR/libankios_fsrs_ios_sim.a" -headers "$TEMP_DIR/ios-sim/Headers" \
  -output "$ROOT/AnkiFSRS.xcframework"
