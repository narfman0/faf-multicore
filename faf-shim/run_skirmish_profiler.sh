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

# Map: default SCMP_007 (512x512, 1v1); override with MAP env var, e.g.
#   MAP=SCMP_009 bash run_skirmish_profiler.sh   (Seton's Clutch, 8-slot 4v4)
# Passed as a VFS path so FixupMapName can find it via DiskGetFileInfo.
MAP="${MAP:-SCMP_007}"
WIN_MAP="/maps/${MAP}/${MAP}_scenario.lua"
WIN_LOG="Z:${MOHO_LOGFILE//\//\\}"

echo "[skirmish-profiler] WINEPREFIX=$WINEPREFIX"
echo "[skirmish-profiler] map=$MAP"
echo "[skirmish-profiler] AI=M28AI vs M28AI (one bot per map army, two teams)"
echo "[skirmish-profiler] moho_log=$MOHO_LOGFILE"
echo "[skirmish-profiler] wine_log=$WINE_LOGFILE"
echo "[skirmish-profiler] profiler_csv=/tmp/faf_profile.csv"
echo ""

# Clear previous profiling output
rm -f /tmp/faf_profiler.log /tmp/faf_profile.csv

cd "$GAMEDIR/bin" || exit 1

WALL_START=$(date +%s)
timeout "$TIMEOUT" wine \
  "$GAMEDIR/bin/ForgedAlliance.exe" \
  /init init_faf.lua \
  /map "$WIN_MAP" \
  /ai M28AI \
  /log "$WIN_LOG" \
  /nobugreport /nosound /nomovie /showlog \
  2>"$WINE_LOGFILE"
EC=$?
WALL_END=$(date +%s)
WALL_S=$((WALL_END - WALL_START))

echo ""
echo "[skirmish-profiler] wine exit: $EC (timeout=$TIMEOUT, wall=${WALL_S}s)"

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

# --- Ceiling metrics: GTA cost as a share of the sim-tick budget --------------
# total_beats = highest sim tick reached. Primary source is the harness beat
# logger ("FAF_BEAT: ticks=N", emitted by custom-hook/lua/aibrain.lua); fall back
# to the engine checksum line and the "********** beat N **********" markers if
# present. ms/beat uses wall-clock (headless runs GameSpeed='fast' => CPU-bound,
# so ms/beat reflects real per-tick cost). See HANDOFF.md "Open items" #1.
echo ""
echo "=== Ceiling metrics ==="
AVG_US=$(awk -F',' 'NR>1 {sum+=$2; n++} END {if(n>0) printf "%.4f", sum/n; else print "0"}' \
    /tmp/faf_profile.csv 2>/dev/null)
CALL_COUNT="${CALL_COUNT:-0}"
TOTAL_BEATS=$(grep -oE 'FAF_BEAT: ticks=([0-9]+)' "$MOHO_LOGFILE" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -n | tail -1)
if [[ -z "$TOTAL_BEATS" ]]; then
    TOTAL_BEATS=$(grep -oE 'beat ([0-9]+) final checksum' "$MOHO_LOGFILE" 2>/dev/null \
        | grep -oE '[0-9]+' | sort -n | tail -1)
fi
if [[ -z "$TOTAL_BEATS" ]]; then
    TOTAL_BEATS=$(grep -oE '\*+ beat ([0-9]+) \*+' "$MOHO_LOGFILE" 2>/dev/null \
        | grep -oE '[0-9]+' | sort -n | tail -1)
fi
TOTAL_BEATS="${TOTAL_BEATS:-0}"
echo "  total_GTA_calls = $CALL_COUNT"
echo "  total_beats     = $TOTAL_BEATS"
echo "  avg_us          = $AVG_US"
echo "  wall_clock_s    = $WALL_S"
if [[ "$TOTAL_BEATS" -gt 0 ]]; then
    awk -v calls="$CALL_COUNT" -v beats="$TOTAL_BEATS" -v avg="$AVG_US" -v wall="$WALL_S" \
        'BEGIN {
            cpt = calls / beats;
            gta_us_tick = cpt * avg;
            ms_beat = (wall * 1000.0) / beats;
            share = (ms_beat > 0) ? (gta_us_tick / (ms_beat * 1000.0)) * 100.0 : 0;
            printf "  calls/tick      = %.2f\n", cpt;
            printf "  GTA us/tick     = %.1f\n", gta_us_tick;
            printf "  ms/beat         = %.2f\n", ms_beat;
            printf "  GTA %% of tick   = %.2f%%\n", share;
        }'
else
    echo "  (no beats parsed from moho log — cannot compute tick share)"
fi

echo ""
echo "=== Moho log (relevant lines) ==="
grep -iE "faf_profiler|m28ai|error|fatal|hook|threat|gta" "$MOHO_LOGFILE" 2>/dev/null | head -40 \
    || echo "(no moho log)"

echo ""
echo "=== Wine stderr tail ==="
tail -10 "$WINE_LOGFILE" 2>/dev/null
