#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
DEMO_ENV_FILE="$ROOT_DIR/.demo_env"

if [[ -z "$PYTHON_BIN" ]]; then
  echo "❌ python3 not found. Install Python 3.10+ and retry."
  exit 1
fi

setup_venv() {
  local venv_dir="$1"
  shift
  local reqs=("$@")
  local py="$venv_dir/bin/python"
  local pip="$venv_dir/bin/pip"

  if [[ ! -x "$py" ]]; then
    echo "🐍 Creating venv: $venv_dir"
    "$PYTHON_BIN" -m venv "$venv_dir"
  fi

  "$pip" install --upgrade pip setuptools wheel

  local req
  for req in "${reqs[@]}"; do
    if [[ -f "$req" ]]; then
      echo "📦 Installing requirements from $req"
      "$pip" install -r "$req"
    fi
  done
}

OPENVOICE_VENV="$ROOT_DIR/pipeline_openvoice/.venv"
SADTALKER_VENV="$ROOT_DIR/pipeline_sadtalker/.venv"
CAPTIONS_VENV="$ROOT_DIR/Captions_pipeline/.venv"
COMPOSITOR_VENV="$ROOT_DIR/PatternInterrupts_Pipeline/.venv"
SCRIPTGEN_VENV="$ROOT_DIR/ScriptGen_Pipeline/.venv"

setup_venv "$OPENVOICE_VENV" \
  "$ROOT_DIR/pipeline_openvoice/requirements.cleaned.txt"

setup_venv "$SADTALKER_VENV" \
  "$ROOT_DIR/pipeline_sadtalker/requirements.txt" \
  "$ROOT_DIR/pipeline_sadtalker/SadTalker/requirements.txt"

setup_venv "$CAPTIONS_VENV"
"$CAPTIONS_VENV/bin/pip" install numpy ffmpeg-python

setup_venv "$COMPOSITOR_VENV"
"$COMPOSITOR_VENV/bin/pip" install moviepy ffmpeg-python numpy

setup_venv "$SCRIPTGEN_VENV"
"$SCRIPTGEN_VENV/bin/pip" install python-dotenv requests

cat > "$DEMO_ENV_FILE" <<ENV
export PROJECT_ROOT="$ROOT_DIR"
export OPENVOICE_PY="$OPENVOICE_VENV/bin/python"
export SADTALKER_PY="$SADTALKER_VENV/bin/python"
export CAPTIONS_PY="$CAPTIONS_VENV/bin/python"
export COMPOSITOR_PY="$COMPOSITOR_VENV/bin/python"
export SCRIPTGEN_PY="$SCRIPTGEN_VENV/bin/python"
ENV

echo "\n⬇️  Downloading demo checkpoints"
bash "$ROOT_DIR/scripts/get_demo_files.sh"

echo "\n✅ Bootstrap complete."
echo "Run this next:"
echo "  source .demo_env"
echo "  bash scripts/run_demo.sh --text \"hello world\" --avatar /absolute/path/avatar.jpg"
