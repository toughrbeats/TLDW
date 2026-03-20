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

exec bash "$ROOT_DIR/runnervidpipeline/runpipeline.sh" "$@"
