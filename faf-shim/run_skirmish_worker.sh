#!/bin/bash
# run_skirmish_worker.sh — run a live M28AI vs M28AI skirmish under the faf_worker build
# Validates the faf_worker.dll offload chain end to end:
#   attach → workers spawn → GTA hook installs → first GTA call registers
#   FAF_OffloadThreatMap / FAF_PollResult and caches the threat map.
#
# Mirrors run_skirmish_profiler.sh but launches ForgedAlliance_worker.exe
# (imports faf_worker.dll) instead of the profiler build. M28AI guarantees
# GetThreatAtPosition traffic so the hook actually fires.
#
# Usage: bash run_skirmish_worker.sh [timeout_seconds]

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/supcom_run"
TIMEOUT="${1:-600}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
TIMESTAMP=$(date +%s)
LOGDIR="/tmp/supcom-logs"
mkdir -p "$LOGDIR"
MOHO_LOGFILE="$LOGDIR/supcom-worker-skirmish-$TIMESTAMP.log"
WINE_LOGFILE="$LOGDIR/wine-worker-skirmish-$TIMESTAMP.log"

export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"
export DISPLAY="${DISPLAY:-:0}"

# Map: default SCMP_007 (512x512, 1v1); override with MAP env var, e.g.
#   MAP=SCMP_009 bash run_skirmish_worker.sh   (Seton's Clutch, 8-slot 4v4)
# Passed as a VFS path so FixupMapName can find it via DiskGetFileInfo.
MAP="${MAP:-SCMP_007}"
WIN_MAP="/maps/${MAP}/${MAP}_scenario.lua"
WIN_LOG="Z:${MOHO_LOGFILE//\//\\}"

echo "[worker-skirmish] WINEPREFIX=$WINEPREFIX"
echo "[worker-skirmish] exe=ForgedAlliance_worker.exe (imports faf_worker.dll)"
echo "[worker-skirmish] map=$MAP"
echo "[worker-skirmish] AI=M28AI (one bot per map army, two teams)"
echo "[worker-skirmish] moho_log=$MOHO_LOGFILE"
echo "[worker-skirmish] wine_log=$WINE_LOGFILE"
echo "[worker-skirmish] worker_log=/tmp/faf_worker.log"
echo ""

# Clear previous worker output so this run's log is unambiguous
rm -f /tmp/faf_worker.log

cd "$GAMEDIR/bin" || exit 1

timeout "$TIMEOUT" wine \
  "$GAMEDIR/bin/ForgedAlliance_worker.exe" \
  /init init_faf.lua \
  /map "$WIN_MAP" \
  /ai M28AI \
  /log "$WIN_LOG" \
  /nobugreport /nosound /nomovie /showlog \
  2>"$WINE_LOGFILE"
EC=$?

echo ""
echo "[worker-skirmish] wine exit: $EC (timeout=$TIMEOUT)"

echo ""
echo "=== faf_worker.log ==="
cat /tmp/faf_worker.log 2>/dev/null || echo "(not found — DLL never attached)"

echo ""
echo "=== worker chain checklist ==="
WLOG=/tmp/faf_worker.log
check() { grep -q "$1" "$WLOG" 2>/dev/null && echo "  [PASS] $2" || echo "  [FAIL] $2"; }
check "faf_worker: attached"                 "DLL attached"
check "worker\[0\]"                           "worker thread(s) spawned"
check "GTA hook installed"                    "GTA hook installed"
check "FAF_OffloadThreatMap / FAF_PollResult registered" "Lua offload API registered"
grep -q "GTA_VA byte mismatch" "$WLOG" 2>/dev/null && echo "  [WARN] GTA_VA byte mismatch — hook NOT installed"
grep -q "try_cache_tmap: unexpected" "$WLOG" 2>/dev/null && echo "  [WARN] threat-map cache failed (type_tag mismatch)"

echo ""
echo "=== Moho log (relevant lines) ==="
grep -iE "faf_worker|m28ai|error|fatal|hook|threat|FAF_Offload|FAF_Poll" "$MOHO_LOGFILE" 2>/dev/null | head -40 \
    || echo "(no moho log)"

echo ""
echo "=== Wine stderr tail ==="
tail -10 "$WINE_LOGFILE" 2>/dev/null
