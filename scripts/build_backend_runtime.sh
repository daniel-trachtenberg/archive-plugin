#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-$ROOT_DIR/backend}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$BACKEND_DIR/.venv}"
RECREATE_VENV="${RECREATE_VENV:-0}"

if [[ ! -d "$BACKEND_DIR" ]]; then
  echo "Backend directory not found: $BACKEND_DIR" >&2
  exit 1
fi

if [[ ! -f "$BACKEND_DIR/requirements.txt" ]]; then
  echo "Missing backend/requirements.txt in: $BACKEND_DIR" >&2
  exit 1
fi

if [[ "$RECREATE_VENV" == "1" ]]; then
  echo "==> Removing existing backend venv: $VENV_DIR"
  rm -rf "$VENV_DIR"
fi

if [[ ! -x "$VENV_DIR/bin/python3" && ! -x "$VENV_DIR/bin/python" ]]; then
  echo "==> Creating backend venv with copied executables via $PYTHON_BIN"
  "$PYTHON_BIN" -m venv --copies "$VENV_DIR"
fi

VENV_PYTHON="$VENV_DIR/bin/python3"
if [[ ! -x "$VENV_PYTHON" ]]; then
  VENV_PYTHON="$VENV_DIR/bin/python"
fi

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "Could not find python executable inside venv: $VENV_DIR" >&2
  exit 1
fi

echo "==> Installing backend dependencies"
"$VENV_PYTHON" -m pip install --upgrade pip setuptools wheel
"$VENV_PYTHON" -m pip install -r "$BACKEND_DIR/requirements.txt"

echo "==> Verifying backend runtime imports"
"$VENV_PYTHON" - <<'PY'
import importlib

modules = [
    "fastapi",
    "uvicorn",
    "watchdog",
    "chromadb",
    "torch",
    "open_clip",
    "pandas",
    "pptx",
    "docx",
    "PIL",
]

for module in modules:
    importlib.import_module(module)

print("Backend runtime import check passed.")
PY

echo "Backend runtime prepared at: $VENV_DIR"
