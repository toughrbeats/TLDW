#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OPENVOICE_DIR="$ROOT_DIR/pipeline_openvoice"
SADTALKER_DIR="$ROOT_DIR/pipeline_sadtalker/SadTalker"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing required command: $1"; exit 1; }
}

need_cmd curl
need_cmd unzip

mkdir -p "$OPENVOICE_DIR/checkpoints" "$SADTALKER_DIR/checkpoints" "$SADTALKER_DIR/gfpgan/weights"

fetch() {
  local out="$1"; shift
  local urls=("$@")
  for u in "${urls[@]}"; do
    echo "⬇️  Trying: $u"
    if curl -fL --retry 3 --connect-timeout 20 --max-time 0 "$u" -o "$out"; then
      echo "✅ Downloaded: $out"
      return 0
    fi
    echo "⚠️  Failed: $u"
  done
  return 1
}

echo "\n== OpenVoice checkpoints =="
OPENVOICE_ZIP="$OPENVOICE_DIR/checkpoints/checkpoints_v2.zip"
if [[ ! -f "$OPENVOICE_ZIP" ]]; then
  fetch "$OPENVOICE_ZIP" \
    "https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2_0417.zip" \
    "https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_v2.zip" || {
      echo "❌ Could not download OpenVoice checkpoints zip from known URLs."
      echo "   Place a checkpoints zip manually at: $OPENVOICE_ZIP"
      exit 2
    }
fi

if [[ ! -f "$OPENVOICE_DIR/checkpoints/checkpoints_v2/converter/checkpoint.pth" ]]; then
  echo "📦 Extracting OpenVoice checkpoints..."
  unzip -o "$OPENVOICE_ZIP" -d "$OPENVOICE_DIR/checkpoints/" >/dev/null
fi

# Handle common zip structures by normalizing to checkpoints/checkpoints_v2/...
if [[ -d "$OPENVOICE_DIR/checkpoints/checkpoints_v2_0417" && ! -d "$OPENVOICE_DIR/checkpoints/checkpoints_v2" ]]; then
  mv "$OPENVOICE_DIR/checkpoints/checkpoints_v2_0417" "$OPENVOICE_DIR/checkpoints/checkpoints_v2"
fi
if [[ -d "$OPENVOICE_DIR/checkpoints/checkpoints_v2/checkpoints_v2" ]]; then
  shopt -s dotglob
  mv "$OPENVOICE_DIR/checkpoints/checkpoints_v2/checkpoints_v2"/* "$OPENVOICE_DIR/checkpoints/checkpoints_v2/"
  rmdir "$OPENVOICE_DIR/checkpoints/checkpoints_v2/checkpoints_v2" || true
  shopt -u dotglob
fi

# Some project code expects en-default speaker embedding under ses/
if [[ -f "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/en-default.pth" && ! -f "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/ses/en-default.pth" ]]; then
  mkdir -p "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/ses"
  cp "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/en-default.pth" "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/ses/en-default.pth"
fi

echo "\n== SadTalker checkpoints =="
(
  cd "$SADTALKER_DIR"
  bash scripts/download_models.sh
)

# quick presence checks for demo-critical files
check_file() {
  [[ -f "$1" ]] || { echo "❌ Missing expected file: $1"; return 1; }
  echo "✅ $1"
}

echo "\n== Verification =="
check_file "$OPENVOICE_DIR/checkpoints/checkpoints_v2/converter/config.json"
check_file "$OPENVOICE_DIR/checkpoints/checkpoints_v2/converter/checkpoint.pth"
check_file "$OPENVOICE_DIR/checkpoints/checkpoints_v2/base_speakers/ses/en-default.pth"
check_file "$SADTALKER_DIR/checkpoints/mapping_00109-model.pth.tar"
check_file "$SADTALKER_DIR/checkpoints/mapping_00229-model.pth.tar"
check_file "$SADTALKER_DIR/checkpoints/SadTalker_V0.0.2_256.safetensors"
check_file "$SADTALKER_DIR/checkpoints/SadTalker_V0.0.2_512.safetensors"
check_file "$SADTALKER_DIR/gfpgan/weights/GFPGANv1.4.pth"

echo "\n🎉 Done. Core demo assets are in place."
