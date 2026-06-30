#!/bin/bash
# run_worker_replay.sh — run a FAF replay through ForgedAlliance_worker.exe under Wine
# Usage: bash run_worker_replay.sh [replay_path]

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/supcom_run"
REPLAY="${1:-/home/narfman0/.openclaw/workspace/faf/27204699.fafreplay}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
TIMESTAMP=$(date +%s)
LOGDIR="/tmp/supcom-logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/supcom-$TIMESTAMP.log"
WINELOG="$LOGDIR/wine-worker-$TIMESTAMP.log"

export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"

# Use real display with RTX 5090; force GLX so Wine doesn't loop on EGL pixel format
export DISPLAY="${DISPLAY:-:0}"

# Convert replay path to Windows Z: path
WIN_REPLAY="Z:${REPLAY//\//\\}"
WIN_LOGFILE="Z:${LOGFILE//\//\\}"

cd "$GAMEDIR/bin" || exit 1

echo "[run_worker_replay] WINEPREFIX=$WINEPREFIX"
echo "[run_worker_replay] replay=$REPLAY"
echo "[run_worker_replay] win_replay=$WIN_REPLAY"
echo "[run_worker_replay] moho_log=$LOGFILE"
echo "[run_worker_replay] wine_stderr=$WINELOG"
echo "[run_worker_replay] faf_worker_log=/tmp/faf_worker.log"
echo ""

timeout 600 wine \
  "$GAMEDIR/bin/ForgedAlliance_worker.exe" \
  /init init_faf.lua \
  /replay "$WIN_REPLAY" \
  /log "$WIN_LOGFILE" \
  /nobugreport /nosound /nomovie /showlog \
  2>"$WINELOG"
EC=$?

echo ""
echo "[run_worker_replay] wine exit: $EC"

echo ""
echo "=== faf_worker.log ==="
cat /tmp/faf_worker.log 2>/dev/null || echo "(not found)"

echo ""
echo "=== Moho log (interesting lines) ==="
grep -iE "faf_worker|offload|threat|beat|error|fatal" "$LOGFILE" 2>/dev/null | head -60 || echo "(no moho log)"

echo ""
echo "=== Wine stderr tail ==="
tail -20 "$WINELOG" 2>/dev/null
