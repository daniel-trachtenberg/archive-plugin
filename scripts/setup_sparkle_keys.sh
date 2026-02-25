#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-archive-plugin}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/.sparkle-tools/Sparkle}"

mkdir -p "$(dirname "$SPARKLE_TOOLS_DIR")"

if [[ ! -d "$SPARKLE_TOOLS_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/sparkle-project/Sparkle "$SPARKLE_TOOLS_DIR" >/dev/null 2>&1
fi

swift package --package-path "$SPARKLE_TOOLS_DIR" resolve >/dev/null 2>&1

GEN_KEYS="$SPARKLE_TOOLS_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

if [[ ! -x "$GEN_KEYS" ]]; then
  echo "Could not find Sparkle generate_keys tool at $GEN_KEYS" >&2
  exit 1
fi

echo "==> Setting up Sparkle key for account: $SPARKLE_ACCOUNT"
"$GEN_KEYS" --account "$SPARKLE_ACCOUNT"

echo
echo "==> Sparkle public key"
"$GEN_KEYS" --account "$SPARKLE_ACCOUNT" -p
