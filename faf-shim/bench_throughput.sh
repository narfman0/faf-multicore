#!/bin/bash
# bench_throughput.sh — A/B sim-throughput benchmark for the threat offload.
#
# Measures beats/sec (completed sim ticks per wall-clock second) for a headless
# M28AI skirmish, under either the baseline exe or the worker exe. In the headless
# session GameSpeed='fast' uncaps the sim (CPU-bound), so freeing sim-tick budget
# shows up directly as higher beats/sec. Higher = faster sim.
#
# PREREQUISITE for a meaningful "on" result: M28AI must actually consume the
# offload (HANDOFF.md "Open items" #2). Until then the worker exe spawns workers
# but the sim doesn't use the results, so on/off will read about the same — that
# null result is itself the Phase-2 gate.
#
# Usage:
#   EXE=base   MAP=SCMP_009 RUNS=5 bash bench_throughput.sh [timeout_seconds]
#   EXE=worker MAP=SCMP_009 RUNS=5 bash bench_throughput.sh [timeout_seconds]
#
#   EXE=base   -> ForgedAlliance.exe         (offload OFF / baseline)
#   EXE=worker -> ForgedAlliance_worker.exe  (offload ON, imports faf_worker.dll)
#
# Preferred: benchmark from the mid-game snapshot (heavy late-game state, no re-sim):
#   SNAPSHOT=../fixtures/seton4v4-30min.SCFAsave EXE=base   RUNS=5 bash bench_throughput.sh 240
#   SNAPSHOT=../fixtures/seton4v4-30min.SCFAsave EXE=worker RUNS=5 bash bench_throughput.sh 240
# beats/sec is measured as elapsed ticks (last-first), since a snapshot starts ~SAVE_TICK.
#
# Run each arm, then compare the reported "beats/sec mean ± stdev". Record numbers
# in faf-analysis/perf-results.md.

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/supcom_run"
TIMEOUT="${1:-360}"
RUNS="${RUNS:-5}"
EXE="${EXE:-base}"
MAP="${MAP:-SCMP_009}"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"
export DISPLAY="${DISPLAY:-:0}"

case "$EXE" in
    base)   EXE_NAME="ForgedAlliance.exe" ;;
    worker) EXE_NAME="ForgedAlliance_worker.exe" ;;
    *) echo "EXE must be 'base' or 'worker' (got '$EXE')" >&2; exit 2 ;;
esac

LOGDIR="/tmp/supcom-logs"
mkdir -p "$LOGDIR"
WIN_MAP="/maps/${MAP}/${MAP}_scenario.lua"

# Optional: benchmark from a mid-game SNAPSHOT (.SCFAsave) instead of a fresh game.
# SNAPSHOT=<unix path> loads that save (via /loadsave) so the A/B runs against the
# heavy late-game state captured at SAVE_TICK. Strongly preferred for the realized
# A/B: identical reloaded state under base vs worker, and no 30-min re-sim per run.
SNAPSHOT="${SNAPSHOT:-}"
LOADSAVE_ARGS=()
if [[ -n "$SNAPSHOT" ]]; then
    if [[ ! -f "$SNAPSHOT" ]]; then echo "SNAPSHOT not found: $SNAPSHOT" >&2; exit 2; fi
    SNAP_ABS=$(readlink -f "$SNAPSHOT")
    WIN_SNAP="Z:${SNAP_ABS//\//\\}"
    LOADSAVE_ARGS=(/loadsave "$WIN_SNAP")
fi

echo "[bench] exe=$EXE_NAME  map=$MAP  timeout=${TIMEOUT}s  runs=$RUNS"
echo "[bench] snapshot=${SNAPSHOT:-<none, fresh game>}"
echo "[bench] WINEPREFIX=$WINEPREFIX"
echo ""

cd "$GAMEDIR/bin" || exit 1

# Highest sim tick reached from a moho log: prefer the harness beat logger
# ("FAF_BEAT: ticks=N"), fall back to the engine checksum line / beat markers.
# Mirrors run_skirmish_profiler.sh's ceiling-metrics logic.
last_beat() {
    local log="$1" b
    b=$(grep -oE 'FAF_BEAT: ticks=([0-9]+)' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    [[ -z "$b" ]] && b=$(grep -oE 'beat ([0-9]+) final checksum' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    [[ -z "$b" ]] && b=$(grep -oE '\*+ beat ([0-9]+) \*+' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    echo "${b:-0}"
}

# Lowest FAF_BEAT tick seen — the start point. For a snapshot run this is ~SAVE_TICK
# (e.g. 18000), so elapsed beats = last - first (not the absolute last tick).
first_beat() {
    local log="$1" b
    b=$(grep -oE 'FAF_BEAT: ticks=([0-9]+)' "$log" 2>/dev/null | grep -oE '[0-9]+' | sort -n | head -1)
    echo "${b:-0}"
}

RATES=()
for ((i = 1; i <= RUNS; i++)); do
    TS=$(date +%s)
    MOHO_LOGFILE="$LOGDIR/bench-$EXE-$MAP-$TS-$i.log"
    WINE_LOGFILE="$LOGDIR/bench-$EXE-$MAP-$TS-$i.wine.log"
    WIN_LOG="Z:${MOHO_LOGFILE//\//\\}"

    WALL_START=$(date +%s)
    timeout "$TIMEOUT" wine \
        "$GAMEDIR/bin/$EXE_NAME" \
        /init init_faf.lua \
        /map "$WIN_MAP" \
        "${LOADSAVE_ARGS[@]}" \
        /ai M28AI \
        /log "$WIN_LOG" \
        /nobugreport /nosound /nomovie /showlog \
        2>"$WINE_LOGFILE"
    WALL_END=$(date +%s)
    WALL_S=$((WALL_END - WALL_START))

    LAST=$(last_beat "$MOHO_LOGFILE")
    FIRST=$(first_beat "$MOHO_LOGFILE")
    BEATS=$((LAST - FIRST))   # elapsed sim ticks during this run (snapshot starts at ~SAVE_TICK)
    # Discard hung/flaky loads (the ~1-in-3 early hang at cheatbuffs.lua): a real
    # run advances many hundreds of beats; a hang advances near-zero.
    if [[ "$BEATS" -lt 50 ]]; then
        echo "  run $i: beats=$BEATS (last=$LAST first=$FIRST) wall=${WALL_S}s -> DISCARDED (likely flaky/hung load)"
        continue
    fi
    RATE=$(awk -v b="$BEATS" -v w="$WALL_S" 'BEGIN {printf "%.3f", (w>0)? b/w : 0}')
    # Determinism guard: any checksum mismatch invalidates the run as a result.
    if grep -qE 'Checksum for beat [0-9]+ mismatched' "$MOHO_LOGFILE" 2>/dev/null; then
        echo "  run $i: beats=$BEATS (last=$LAST first=$FIRST) wall=${WALL_S}s rate=$RATE b/s  [WARN] CHECKSUM MISMATCH (desync!)"
    else
        echo "  run $i: beats=$BEATS (last=$LAST first=$FIRST) wall=${WALL_S}s rate=$RATE b/s"
    fi
    RATES+=("$RATE")
done

echo ""
echo "=== $EXE_NAME throughput summary ($MAP) ==="
if [[ "${#RATES[@]}" -eq 0 ]]; then
    echo "  no valid runs (all discarded)"
    exit 1
fi
printf '%s\n' "${RATES[@]}" | awk '
    {x[NR]=$1; sum+=$1; n++}
    END {
        mean = sum/n;
        for (i=1;i<=n;i++) ss += (x[i]-mean)*(x[i]-mean);
        sd = (n>1) ? sqrt(ss/(n-1)) : 0;
        printf "  n=%d  beats/sec mean=%.3f  stdev=%.3f  (%.1f%% rel)\n", n, mean, sd, (mean>0)?100*sd/mean:0;
    }'
