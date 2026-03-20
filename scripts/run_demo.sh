#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_ENV_FILE="${ROOT_DIR}/.demo_env"

if [[ ! -f "$DEMO_ENV_FILE" ]]; then
  echo "❌ Missing ${DEMO_ENV_FILE}"
  echo "   Run: bash scripts/bootstrap_demo.sh"
  exit 1
fi

source "$DEMO_ENV_FILE"

FALLBACK_PY="${VIRTUAL_ENV:-$ROOT_DIR/.venv}/bin/python"
if [[ ! -x "$FALLBACK_PY" ]]; then
  FALLBACK_PY="$(command -v python3 || command -v python || true)"
fi

repair_py_var() {
  local name="$1"
  local current="${!name:-}"
  if [[ -n "$current" && -x "$current" ]]; then
    return 0
  fi
  if [[ -n "$FALLBACK_PY" && -x "$FALLBACK_PY" ]]; then
    echo "⚠️  $name missing ($current). Falling back to $FALLBACK_PY"
    export "$name=$FALLBACK_PY"
    return 0
  fi
  echo "❌ $name missing and no fallback python found."
  exit 1
}

repair_py_var OPENVOICE_PY
repair_py_var SADTALKER_PY
repair_py_var CAPTIONS_PY
repair_py_var COMPOSITOR_PY
repair_py_var SCRIPTGEN_PY
repair_py_var YOUTUBE_PY
repair_py_var WHISPERX_PY

exec bash "$ROOT_DIR/runnervidpipeline/runpipeline.sh" "$@"
