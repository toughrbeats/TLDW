#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
VENV_DIR="${ROOT_DIR}/.venv"
VENV_PY="${VENV_DIR}/bin/python"
PIP="${VENV_DIR}/bin/pip"

if [[ -z "$PYTHON_BIN" ]]; then
  echo "❌ python3 not found. Install Python 3.10+ and retry."
  exit 1
fi

if [[ ! -x "$VENV_PY" ]]; then
  echo "🐍 Creating repo venv at ${VENV_DIR}"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$PIP" install --upgrade pip setuptools wheel

REQ_FILES=(
  "$ROOT_DIR/pipeline_openvoice/requirements.cleaned.txt"
  "$ROOT_DIR/pipeline_sadtalker/requirements.txt"
  "$ROOT_DIR/pipeline_sadtalker/SadTalker/requirements.txt"
)

for req in "${REQ_FILES[@]}"; do
  if [[ -f "$req" ]]; then
    echo "📦 Installing requirements from ${req}"
    if ! "$PIP" install -r "$req"; then
      echo "⚠️  Failed to install ${req}. Continuing with fallback package set."
    fi
  fi
done

# extras used by compositor + common helpers when not pinned above
"$PIP" install torch torchvision moviepy python-dotenv requests ffmpeg-python

echo "\n⬇️  Downloading demo checkpoints"
bash "$ROOT_DIR/scripts/get_demo_files.sh"

echo "\n✅ Bootstrap complete."
echo "Next step:"
echo "  bash scripts/run_demo.sh --text \"hello world\" --avatar /absolute/path/avatar.jpg"
