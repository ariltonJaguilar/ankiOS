#!/bin/zsh
set -euo pipefail

HERE=${0:A:h}
PROJECT=${HERE:h:h}
PLATFORM=${1:?Use ios DEVICE_ID or macos}
case "$PLATFORM" in
  ios)
    DEVICE_ID=${2:?Informe o UUID do simulador isolado}
    DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
    shift 2
    ;;
  macos)
    DESTINATION="platform=macOS,arch=arm64"
    shift
    ;;
  *) exit 2 ;;
esac

OUT=${ANKIOS_UI_OUTPUT:-/tmp/ankios-ui}
DERIVED=${ANKIOS_UI_DERIVED_DATA:-$OUT/build-$PLATFORM}
RUN="$OUT/$PLATFORM-$(date +%Y%m%d-%H%M%S)"
SYNC_SETTINGS=()
if [[ -n ${ANKIOS_UI_SYNC_ENDPOINT:-} ]]; then
  SYNC_SETTINGS+=("ANKIOS_UI_SYNC_ENDPOINT=$ANKIOS_UI_SYNC_ENDPOINT")
fi
mkdir -p "$OUT"
if xcodebuild -project "$PROJECT/AnkiOS.xcodeproj" -scheme AnkiOS-UI \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath "$RUN.xcresult" "${SYNC_SETTINGS[@]}" "$@" test > "$RUN.log" 2>&1; then
  tail -18 "$RUN.log"
else
  tail -65 "$RUN.log"
  exit 1
fi
