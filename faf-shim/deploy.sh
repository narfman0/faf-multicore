#!/usr/bin/env bash
# deploy.sh — build faf_profiler.dll, inject import into SupCom.exe, deploy to game/bin/
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_BIN="$(realpath "$SCRIPT_DIR/../game/bin")"
ANALYSIS="$SCRIPT_DIR"

echo "=== Building faf_profiler.dll ==="
cd "$ANALYSIS"
make

echo ""
echo "=== Injecting import into SupremeCommander.exe ==="
python3 inject_import.py "$GAME_BIN/SupremeCommander.exe"

echo ""
echo "=== Deploying to $GAME_BIN ==="
cp faf_profiler.dll "$GAME_BIN/faf_profiler.dll"
cp "$GAME_BIN/SupremeCommander_patched.exe" "$GAME_BIN/SupremeCommander.exe"

echo ""
echo "=== Done ==="
echo "Profile output will be at: /tmp/faf_profile.csv"
echo "Debug log at:              /tmp/faf_profiler.log"
echo ""
echo "Run headless with:"
echo "  cd $SCRIPT_DIR/.."
echo "  bash faf-analysis/run_headless.sh"
