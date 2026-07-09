#!/usr/bin/env bash
# Start the receiver simulator (macOS / Linux). Uses uv to provision the venv.
set -e
cd "$(dirname "$0")"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found. Install it: https://docs.astral.sh/uv/getting-started/installation/"
  exit 1
fi

uv venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
uv pip install -r requirements.txt
echo
python app.py
