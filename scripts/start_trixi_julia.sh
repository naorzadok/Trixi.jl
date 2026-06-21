#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARMUP_SCRIPT="$ROOT_DIR/utils/warmup_packages.jl"
PACKAGE_FILE="$ROOT_DIR/utils/startup_packages.txt"
CACHE_FILE="$ROOT_DIR/.warmup_cache"
PROJECT_PATH="$ROOT_DIR"

if [[ ! -f "$WARMUP_SCRIPT" ]]; then
  echo "Warmup script not found: $WARMUP_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$PACKAGE_FILE" ]]; then
  echo "Package file not found: $PACKAGE_FILE" >&2
  exit 1
fi

echo "[start_trixi_julia] Running warmup (cache-aware)..."
julia "$WARMUP_SCRIPT" \
  --project="$PROJECT_PATH" \
  --file="$PACKAGE_FILE" \
  --cache-file="$CACHE_FILE" \
  --use-cache \
  --add-missing

echo "[start_trixi_julia] Starting Julia REPL in project: $PROJECT_PATH"

# Build a `using ...` expression from the package list so the interactive REPL
# actually has the packages loaded (the warmup above only precompiles them in a
# separate process that exits before this REPL starts).
LOAD_PKGS="$(grep -vE '^\s*(#|$)' "$PACKAGE_FILE" | paste -sd, -)"
if [[ -n "$LOAD_PKGS" ]]; then
  echo "[start_trixi_julia] Importing packages into REPL: $LOAD_PKGS"
  exec julia --project="$PROJECT_PATH" -i -e "using $LOAD_PKGS"
else
  exec julia --project="$PROJECT_PATH" -i
fi
