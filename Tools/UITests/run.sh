#!/bin/zsh
set -euo pipefail

HERE=${0:A:h}
PROJECT=${HERE:h:h}
PLATFORM=${1:?Use ios DEVICE_ID or macos}
IS_SIMULATOR=0
case "$PLATFORM" in
  ios)
    DEVICE_ID=${2:?Informe o UUID do simulador isolado}
    if xcrun simctl list devices available --json | python3 -c 'import json,sys; ds=json.load(sys.stdin).get("devices",{}); sys.exit(0 if any(d.get("udid")==sys.argv[1] for group in ds.values() for d in group) else 1)' "$DEVICE_ID"; then
      DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
      IS_SIMULATOR=1
    else
      DESTINATION="platform=iOS,id=$DEVICE_ID"
      IS_SIMULATOR=0
    fi
    SIGNING_ALLOWED=${ANKIOS_UI_CODE_SIGNING_ALLOWED:-YES}
    shift 2
    ;;
  macos)
    DESTINATION="platform=macOS,arch=arm64"
    SIGNING_ALLOWED=${ANKIOS_UI_CODE_SIGNING_ALLOWED:-YES}
    shift
    ;;
  *) exit 2 ;;
esac

OUT=${ANKIOS_UI_OUTPUT:-/tmp/ankios-ui}
DERIVED=${ANKIOS_UI_DERIVED_DATA:-$OUT/build-$PLATFORM}
RUN="$OUT/$PLATFORM-$(date +%Y%m%d-%H%M%S)"
XCODE_SHARED_DECK_ARGS=()
SHARED_DECK_SERVER_PID=0
SHARED_DECK_PORT_FILE="$RUN.shared-deck-port"
if [[ -n ${ANKIOS_UI_SYNC_ENDPOINT:-} ]]; then
  export ANKIOS_UI_SYNC_ENDPOINT
  XCODE_SYNC_ARGS=("ANKIOS_UI_SYNC_ENDPOINT=$ANKIOS_UI_SYNC_ENDPOINT")
else
  XCODE_SYNC_ARGS=()
fi
if [[ -n ${ANKIOS_UI_SYNC_CANCEL_ENDPOINT:-} ]]; then
  export ANKIOS_UI_SYNC_CANCEL_ENDPOINT
  XCODE_SYNC_ARGS+=("ANKIOS_UI_SYNC_CANCEL_ENDPOINT=$ANKIOS_UI_SYNC_CANCEL_ENDPOINT")
fi
XCODE_INFO_CONSUMER_ARGS=()
if [[ ${ANKIOS_UI_INFO_CONSUMER:-0} == 1 ]]; then
  if [[ "$PLATFORM" != ios || $IS_SIMULATOR != 1 ]]; then
    print -u2 "O consumidor de infoForAdding só roda no simulador iOS."
    exit 2
  fi
  zsh "$HERE/build-info-consumer.sh" "$DEVICE_ID"
  XCODE_INFO_CONSUMER_ARGS=("ANKIOS_UI_INFO_CONSUMER=1")
fi
XCODE_CAMERA_AVAILABILITY_ARGS=()
if [[ ${ANKIOS_UI_CAMERA_AVAILABILITY_ONLY:-0} == 1 ]]; then
  if [[ "$PLATFORM" != ios || $IS_SIMULATOR != 1 ]]; then
    print -u2 "A verificação de disponibilidade da câmera só roda no simulador iOS."
    exit 2
  fi
  XCODE_CAMERA_AVAILABILITY_ARGS=("ANKIOS_UI_CAMERA_AVAILABILITY_ONLY=1")
fi
XCODE_REMOTE_MEDIA_ARGS=()
if [[ -n ${ANKIOS_UI_REMOTE_MEDIA_URL:-} ]]; then
  export ANKIOS_UI_REMOTE_MEDIA_URL
  XCODE_REMOTE_MEDIA_ARGS+=("ANKIOS_UI_REMOTE_MEDIA_URL=$ANKIOS_UI_REMOTE_MEDIA_URL")
fi
for testArgument in "$@"; do
  if [[ "$testArgument" == *testOpenOfficialPackageAndStudyImportedMedia* ]]; then
    if [[ "$PLATFORM" != ios || $IS_SIMULATOR != 1 ]]; then
      print -u2 "O download de Shared Deck de teste só roda no simulador iOS."
      exit 2
    fi
    python3 "$HERE/shared-deck-fixture-server.py" "$PROJECT/Tools/UITests/Fixtures/official.apkg" 0 "$SHARED_DECK_PORT_FILE" > "$RUN.shared-deck-server.log" 2>&1 &
    SHARED_DECK_SERVER_PID=$!
    for attempt in {1..50}; do
      [[ -s "$SHARED_DECK_PORT_FILE" ]] && break
      sleep 0.2
    done
    if [[ ! -s "$SHARED_DECK_PORT_FILE" ]]; then
      cat "$RUN.shared-deck-server.log"
      kill "$SHARED_DECK_SERVER_PID" 2>/dev/null || true
      exit 1
    fi
    read "SHARED_DECK_PORT" < "$SHARED_DECK_PORT_FILE"
    ANKIOS_UI_SHARED_DECK_FIXTURE_URL="http://127.0.0.1:$SHARED_DECK_PORT/"
    for attempt in {1..50}; do
      if curl -fsS "$ANKIOS_UI_SHARED_DECK_FIXTURE_URL" >/dev/null; then break; fi
      sleep 0.2
    done
    if ! curl -fsS "$ANKIOS_UI_SHARED_DECK_FIXTURE_URL" >/dev/null; then
      cat "$RUN.shared-deck-server.log"
      kill "$SHARED_DECK_SERVER_PID" 2>/dev/null || true
      exit 1
    fi
    XCODE_SHARED_DECK_ARGS=("ANKIOS_UI_SHARED_DECK_FIXTURE_URL=$ANKIOS_UI_SHARED_DECK_FIXTURE_URL")
    break
  fi
done
XCODE_SIGNING_ARGS=(
  "CODE_SIGNING_ALLOWED=$SIGNING_ALLOWED"
)
DEFAULT_SIGNING_REQUIRED=NO
DEFAULT_SIGNING_IDENTITY=-
if [[ "$PLATFORM" == ios ]] && (( ! IS_SIMULATOR )); then
  DEFAULT_SIGNING_REQUIRED=YES
  DEFAULT_SIGNING_IDENTITY="Apple Development"
fi
XCODE_SIGNING_ARGS+=(
  "CODE_SIGNING_REQUIRED=${ANKIOS_UI_CODE_SIGNING_REQUIRED:-$DEFAULT_SIGNING_REQUIRED}"
  "CODE_SIGN_IDENTITY=${ANKIOS_UI_CODE_SIGN_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
)
if [[ ${ANKIOS_UI_CODE_SIGN_ENTITLEMENTS+x} ]]; then
  XCODE_SIGNING_ARGS+=("CODE_SIGN_ENTITLEMENTS=$ANKIOS_UI_CODE_SIGN_ENTITLEMENTS")
fi
MEDIA_FIXTURE_PATHS=()
if [[ "$PLATFORM" == "ios" ]]; then
  seedImageFixture=0
  seedAudioFixture=0
  seedVideoFixture=0
  seedApkgFixture=0
  seedFSRSFixture=0
  seedStatsFixture=0
  seedCSVFixture=0
  seedCSVHTMLFixture=0
  if (( $# == 0 )); then
    seedImageFixture=1
    seedAudioFixture=1
    seedVideoFixture=1
    seedApkgFixture=1
    seedCSVFixture=1
  fi
  for testArgument in "$@"; do
    if [[ "$testArgument" == *testEditorMediaPickerImportsImageFile* || "$testArgument" == *testNoteEditorImportsAndPersistsMedia* || "$testArgument" == *testImageOcclusionDrawsAndPersistsMasks* ]]; then
      seedImageFixture=1
    fi
    if [[ "$testArgument" == *testNoteEditorImportsAndPersistsMedia* ]]; then
      seedAudioFixture=1
      seedVideoFixture=1
    fi
    if [[ "$testArgument" == *testCollectionPackageImportThroughToolsAndStudiesImportedMedia* || "$testArgument" == *testApkgImportOptionsAndPoliciesArePresentedBeforeImport* ]]; then
      seedApkgFixture=1
    fi
    if [[ "$testArgument" == *testFSRSOptimizerComputesAndPersistsParametersFromReviewHistory* ]]; then
      seedFSRSFixture=1
    fi
    if [[ "$testArgument" == *testStatisticsReviewChartExposesEveryReviewType* ]]; then
      seedStatsFixture=1
    fi
    if [[ "$testArgument" == *testCSVImportThroughToolsMapsFieldsTagsAndStudiesNote* || "$testArgument" == *testCSVImportCanIgnoreAnExistingNoteThroughTools* || "$testArgument" == *testCSVImportUpdatesAnExistingNoteThroughTools* || "$testArgument" == *testCSVImportAsNewCreatesAnotherNoteThroughTools* || "$testArgument" == *testCSVImportOptionsPersistAfterRelaunch* || "$testArgument" == *testCSVImportMatchesDuplicatesOnlyWithinSelectedDeck* ]]; then
      seedCSVFixture=1
    fi
    if [[ "$testArgument" == *testCSVImportSemicolonAndHTMLThroughTools* ]]; then
      seedCSVHTMLFixture=1
    fi
  done
  if [[ ${ANKIOS_UI_CAMERA_AVAILABILITY_ONLY:-0} == 1 ]]; then
    seedImageFixture=0
  fi
  if (( seedImageFixture || seedAudioFixture || seedVideoFixture || seedApkgFixture || seedFSRSFixture || seedStatsFixture || seedCSVFixture || seedCSVHTMLFixture )) && (( IS_SIMULATOR )); then
    fileProviderGroups=$(xcrun simctl get_app_container "$DEVICE_ID" com.apple.DocumentsApp groups)
    fileProviderRoot=$(print -r -- "$fileProviderGroups" | awk '$1 == "group.com.apple.FileProvider.LocalStorage" { print $2; exit }')
    if [[ -z "$fileProviderRoot" ]]; then
      print -u2 "O provedor local do app Arquivos não está disponível neste simulador."
      exit 1
    fi
    mkdir -p "$fileProviderRoot/File Provider Storage/Downloads"
    if (( seedImageFixture )); then
      imageFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-picker-fixture.png"
      if [[ -e "$imageFixturePath" ]]; then
        print -u2 "A fixture de mídia já existe no simulador: ankios-picker-fixture.png"
        exit 1
      fi
      cp "$PROJECT/AnkiOS/Assets.xcassets/LaunchMark.imageset/LaunchMark.png" "$imageFixturePath"
      MEDIA_FIXTURE_PATHS+=("$imageFixturePath")
    fi
    if (( seedAudioFixture )); then
      audioFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-picker-audio-fixture.wav"
      if [[ -e "$audioFixturePath" ]]; then
        print -u2 "A fixture de mídia já existe no simulador: ankios-picker-audio-fixture.wav"
        exit 1
      fi
      python3 "$PROJECT/Tools/UITests/make-audio-fixture.py" "$audioFixturePath"
      MEDIA_FIXTURE_PATHS+=("$audioFixturePath")
    fi
    if (( seedVideoFixture )); then
      videoFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-picker-video-fixture.mp4"
      if [[ -e "$videoFixturePath" ]]; then
        print -u2 "A fixture de mídia já existe no simulador: ankios-picker-video-fixture.mp4"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/media-video.mp4" "$videoFixturePath"
      MEDIA_FIXTURE_PATHS+=("$videoFixturePath")
    fi
    if (( seedApkgFixture )); then
      apkgFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-tools-import-fixture.apkg"
      if [[ -e "$apkgFixturePath" ]]; then
        print -u2 "A fixture de importação já existe no simulador: ankios-tools-import-fixture.apkg"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/official.apkg" "$apkgFixturePath"
      MEDIA_FIXTURE_PATHS+=("$apkgFixturePath")
    fi
    if (( seedFSRSFixture )); then
      fsrsFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-fsrs-optimizer.apkg"
      if [[ -e "$fsrsFixturePath" ]]; then
        print -u2 "A fixture de otimização FSRS já existe no simulador: ankios-fsrs-optimizer.apkg"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/fsrs-optimizer.apkg" "$fsrsFixturePath"
      MEDIA_FIXTURE_PATHS+=("$fsrsFixturePath")
    fi
    if (( seedStatsFixture )); then
      statsFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-stats-review-types.apkg"
      if [[ -e "$statsFixturePath" ]]; then
        print -u2 "A fixture de estatísticas já existe no simulador: ankios-stats-review-types.apkg"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/stats-review-types.apkg" "$statsFixturePath"
      MEDIA_FIXTURE_PATHS+=("$statsFixturePath")
    fi
    if (( seedCSVFixture )); then
      csvFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-tools-import-fixture.csv"
      if [[ -e "$csvFixturePath" ]]; then
        print -u2 "A fixture de importação já existe no simulador: ankios-tools-import-fixture.csv"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/tools-import.csv" "$csvFixturePath"
      MEDIA_FIXTURE_PATHS+=("$csvFixturePath")
    fi
    if (( seedCSVHTMLFixture )); then
      csvHTMLFixturePath="$fileProviderRoot/File Provider Storage/Downloads/ankios-tools-html-import-fixture.csv"
      if [[ -e "$csvHTMLFixturePath" ]]; then
        print -u2 "A fixture de importação já existe no simulador: ankios-tools-html-import-fixture.csv"
        exit 1
      fi
      cp "$PROJECT/Tools/UITests/Fixtures/tools-import-html.csv" "$csvHTMLFixturePath"
      MEDIA_FIXTURE_PATHS+=("$csvHTMLFixturePath")
    fi
  elif (( seedImageFixture || seedAudioFixture || seedVideoFixture || seedApkgFixture || seedFSRSFixture || seedStatsFixture || seedCSVFixture || seedCSVHTMLFixture )); then
    print "As fixtures do app Arquivos são semeadas apenas em simuladores; o fluxo físico selecionado termina antes de Arquivos."
  fi
fi
cleanupMediaFixture() {
  if (( SHARED_DECK_SERVER_PID > 0 )); then
    kill "$SHARED_DECK_SERVER_PID" 2>/dev/null || true
  fi
  rm -f -- "$SHARED_DECK_PORT_FILE"
  for fixturePath in "${MEDIA_FIXTURE_PATHS[@]}"; do
    rm -f -- "$fixturePath"
  done
}
trap cleanupMediaFixture EXIT
mkdir -p "$OUT"
for previousResult in "$OUT"/*.xcresult(N); do
  if [[ ! -f "$previousResult/Info.plist" ]]; then
    rm -rf -- "$previousResult"
  fi
done
XCODE_PID=0
trap 'if (( XCODE_PID > 0 )); then kill -TERM "$XCODE_PID" 2>/dev/null || true; fi; exit 143' INT TERM
xcodebuild -project "$PROJECT/AnkiOS.xcodeproj" -scheme AnkiOS-UI \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  "${XCODE_SYNC_ARGS[@]}" \
  "${XCODE_INFO_CONSUMER_ARGS[@]}" \
  "${XCODE_CAMERA_AVAILABILITY_ARGS[@]}" \
  "${XCODE_REMOTE_MEDIA_ARGS[@]}" \
  "${XCODE_SHARED_DECK_ARGS[@]}" \
  "${XCODE_SIGNING_ARGS[@]}" -parallel-testing-enabled NO \
  -resultBundlePath "$RUN.xcresult" "$@" test > "$RUN.log" 2>&1 &
XCODE_PID=$!
SUMMARY_GRACE=0
SUMMARY_TIMED_OUT=0
while kill -0 "$XCODE_PID" 2>/dev/null; do
  if rg -q "Test Suite 'Selected tests' passed at " "$RUN.log" \
    && rg -q "Executed [1-9][0-9]* tests?, with 0 failures" "$RUN.log" \
    && ! rg -q "Test Case '.*' failed|Test Suite 'Selected tests' failed|Executed .* with [1-9][0-9]* failures" "$RUN.log"; then
    (( SUMMARY_GRACE += 1 ))
    if (( SUMMARY_GRACE >= 45 )); then
      kill -TERM "$XCODE_PID" 2>/dev/null || true
      SUMMARY_TIMED_OUT=1
      break
    fi
  elif rg -q "Test Case '.*' failed \\(" "$RUN.log" \
    && (rg -q "Executed [1-9][0-9]* tests?, with [1-9][0-9]* failures" "$RUN.log" \
      || (rg -q "Restarting after unexpected exit" "$RUN.log" \
        && rg -q "Executed 0 tests, with 0 failures" "$RUN.log")); then
    (( SUMMARY_GRACE += 1 ))
    if (( SUMMARY_GRACE >= 45 )); then
      kill -TERM "$XCODE_PID" 2>/dev/null || true
      SUMMARY_TIMED_OUT=1
      break
    fi
  else
    SUMMARY_GRACE=0
  fi
  sleep 1
done
XCODE_STATUS=0
wait "$XCODE_PID" || XCODE_STATUS=$?
XCODE_PID=0
if (( XCODE_STATUS == 0 )); then
  tail -18 "$RUN.log"
elif rg -q "Test Suite 'Selected tests' passed at " "$RUN.log" \
  && rg -q "Test Case '.*' passed \\(" "$RUN.log" \
  && rg -q "Executed [1-9][0-9]* tests?, with 0 failures" "$RUN.log" \
  && ! rg -q "Test Case '.*' failed|Test Suite 'Selected tests' failed|Executed .* with [1-9][0-9]* failures" "$RUN.log"; then
  print "XCTest passou; o xcodebuild não finalizou o xcresult após 45 segundos."
  tail -18 "$RUN.log"
else
  tail -65 "$RUN.log"
  if (( SUMMARY_TIMED_OUT )); then
    exit 1
  fi
  exit "$XCODE_STATUS"
fi
