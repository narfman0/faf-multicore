#!/bin/bash
# run_skirmish_profiler.sh — run a live M28AI vs M28AI skirmish for GTA profiling
# Usage: bash run_skirmish_profiler.sh [timeout_seconds]
#
# Requires:
#   - supcom_run/bin/ForgedAlliance.exe with faf_profiler.dll in import table
#   - Game.prefs with active_mods including M28AI UID
#   - custom-hook/lua/singleplayerlaunch.lua hook for all-AI session setup

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/supcom_run"
TIMEOUT="${1:-600}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
TIMESTAMP=$(date +%s)
LOGDIR="/tmp/supcom-logs"
mkdir -p "$LOGDIR"
MOHO_LOGFILE="$LOGDIR/supcom-skirmish-$TIMESTAMP.log"
WINE_LOGFILE="$LOGDIR/wine-skirmish-$TIMESTAMP.log"

export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"
export DISPLAY="${DISPLAY:-:0}"

# Map: SCMP_007 (512x512); pass as VFS path so FixupMapName can find it via DiskGetFileInfo
WIN_MAP='/maps/SCMP_007/SCMP_007_scenario.lua'
WIN_LOG="Z:${MOHO_LOGFILE//\//\\}"

echo "[skirmish-profiler] WINEPREFIX=$WINEPREFIX"
echo "[skirmish-profiler] map=SCMP_007 (Open Palms 512x512)"
echo "[skirmish-profiler] AI=M28AI vs M28AI (1v1)"
echo "[skirmish-profiler] moho_log=$MOHO_LOGFILE"
echo "[skirmish-profiler] wine_log=$WINE_LOGFILE"
echo "[skirmish-profiler] profiler_csv=/tmp/faf_profile.csv"
echo ""

# Clear previous profiling output
rm -f /tmp/faf_profiler.log /tmp/faf_profile.csv

cd "$GAMEDIR/bin" || exit 1

timeout "$TIMEOUT" wine \
  "$GAMEDIR/bin/ForgedAlliance.exe" \
  /init init_faf.lua \
  /map "$WIN_MAP" \
  /ai M28AI \
  /log "$WIN_LOG" \
  /nobugreport /nosound /nomovie /showlog \
  2>"$WINE_LOGFILE"
EC=$?

echo ""
echo "[skirmish-profiler] wine exit: $EC (timeout=$TIMEOUT)"

echo ""
echo "=== faf_profiler.log ==="
cat /tmp/faf_profiler.log 2>/dev/null || echo "(not found)"

echo ""
echo "=== GTA call summary ==="
if [[ -f /tmp/faf_profile.csv ]]; then
    CALL_COUNT=$(tail -n +2 /tmp/faf_profile.csv | wc -l)
    echo "Total GTA calls: $CALL_COUNT"
    if [[ "$CALL_COUNT" -gt 0 ]]; then
        echo "First 5 calls:"
        head -6 /tmp/faf_profile.csv
        echo "Last 5 calls:"
        tail -5 /tmp/faf_profile.csv
        echo ""
        echo "Timing stats (awk):"
        awk -F',' 'NR>1 {sum+=$2; n++; if($2>max) max=$2; if(min==""||$2<min) min=$2}
                   END {printf "  count=%d  avg=%.1fus  min=%.1fus  max=%.1fus\n", n, sum/n, min, max}' \
            /tmp/faf_profile.csv
    fi
else
    echo "(no CSV found — GTA was not called)"
fi

echo ""
echo "=== Moho log (relevant lines) ==="
grep -iE "faf_profiler|m28ai|error|fatal|hook|threat|gta" "$MOHO_LOGFILE" 2>/dev/null | head -40 \
    || echo "(no moho log)"

echo ""
echo "=== Wine stderr tail ==="
tail -10 "$WINE_LOGFILE" 2>/dev/null
