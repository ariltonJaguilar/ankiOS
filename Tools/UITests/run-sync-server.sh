#!/bin/zsh
set -euo pipefail

PARITY_PYTHON=${ANKIOS_ORACLE_PYTHON:-/tmp/ankios-parity/venv/bin/python}
SERVER_ROOT=${ANKIOS_UI_SYNC_ROOT:-$(mktemp -d /tmp/ankios-ui-sync.XXXXXX)}
exec env SYNC_USER1=ui-local:ui-local-only SYNC_HOST=127.0.0.1 \
  SYNC_PORT="${ANKIOS_UI_SYNC_PORT:-18765}" SYNC_BASE="$SERVER_ROOT" \
  "$PARITY_PYTHON" -m anki.syncserver
