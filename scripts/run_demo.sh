#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PY="${ROOT_DIR}/.venv/bin/python"

if [[ ! -x "$VENV_PY" ]]; then
  echo "❌ Missing ${VENV_PY}"
  echo "   Run: bash scripts/bootstrap_demo.sh"
  exit 1
fi

export PROJECT_ROOT="$ROOT_DIR"
export OPENVOICE_PY="$VENV_PY"
export SADTALKER_PY="$VENV_PY"
export CAPTIONS_PY="$VENV_PY"
export COMPOSITOR_PY="$VENV_PY"
export SCRIPTGEN_PY="$VENV_PY"
export YOUTUBE_PY="$VENV_PY"
export WHISPERX_PY="$VENV_PY"

exec bash "$ROOT_DIR/runnervidpipeline/runpipeline.sh" "$@"
