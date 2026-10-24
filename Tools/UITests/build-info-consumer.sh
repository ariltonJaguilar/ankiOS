#!/bin/zsh
set -euo pipefail

DEVICE_ID=${1:?Informe o UUID do simulador}
OUTPUT=${2:-/tmp/ankios-ui/info-consumer}
HERE=${0:A:h}
APP="$OUTPUT/AnkiInfoConsumer.app"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$APP"
xcrun --sdk iphonesimulator swiftc \
  -target arm64-apple-ios26.0-simulator \
  -sdk "$SDK" \
  -module-name AnkiInfoConsumer \
  -parse-as-library \
  -framework SwiftUI \
  -framework UIKit \
  "$HERE/InfoForAddingConsumer/InfoForAddingConsumer.swift" \
  -o "$APP/AnkiInfoConsumer"
cp "$HERE/InfoForAddingConsumer/Info.plist" "$APP/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
xcrun simctl install "$DEVICE_ID" "$APP"
