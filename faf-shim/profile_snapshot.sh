#!/bin/bash
# profile_snapshot.sh — perf-profile the sim thread while reloading a mid-game
# .SCFAsave snapshot under the real FAF build (ForgedAlliance_faf.exe).
#
# Reloading a snapshot puts us straight into the dense late-game state (no ~1hr
# re-sim), so we can perf-record the busy sim thread at a fixed, reproducible unit
# load. Used for the "what's slow in a real battle" C++/Lua breakdown.
#
# Usage:
#   SNAPSHOT=../fixtures/seton4v4-45min.SCFAsave bash profile_snapshot.sh [perf_secs]
#
# Env:
#   SNAPSHOT   (required) unix path to the .SCFAsave to reload
#   SHOWLOG=0|1  default 0 — drop /showlog to kill the riched20 log-console render
#                (the measured 29% DSO artifact). Set 1 to A/B that hypothesis.
#   PERF_HZ      perf sampling rate (default 499)
#   perf_secs    positional; record window in seconds (default 25)
#
# Output: DSO breakdown + top symbols of the hottest ForgedAlliance thread, plus
# the FAF_BEAT ms/tick over the window (from the beat logger's rt timeline).

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/supcom_run"
EXE_NAME="ForgedAlliance_faf.exe"
PERF_SECS="${1:-25}"
PERF_HZ="${PERF_HZ:-499}"
SHOWLOG="${SHOWLOG:-0}"
SNAPSHOT="${SNAPSHOT:?set SNAPSHOT=<path to .SCFAsave>}"

export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$(ls -t /run/user/1000/.mutter-Xwaylandauth.* 2>/dev/null | head -1)}"

[[ -f "$SNAPSHOT" ]] || { echo "SNAPSHOT not found: $SNAPSHOT" >&2; exit 2; }
SNAP_ABS=$(readlink -f "$SNAPSHOT")
WIN_SNAP="Z:${SNAP_ABS//\//\\}"

LOGDIR="/tmp/supcom-logs"; mkdir -p "$LOGDIR"
TS=$(date +%s)
MOHO_LOG="$LOGDIR/profile-$TS.log"
WINE_LOG="$LOGDIR/profile-$TS.wine.log"
PERF_DATA="$LOGDIR/perf-$TS.data"
WIN_LOG="Z:${MOHO_LOG//\//\\}"

SHOWLOG_ARG=(); [[ "$SHOWLOG" == "1" ]] && SHOWLOG_ARG=(/showlog)

echo "[profile] snapshot=$SNAP_ABS"
echo "[profile] showlog=$SHOWLOG  perf_hz=$PERF_HZ  perf_secs=$PERF_SECS"
echo "[profile] moho_log=$MOHO_LOG  perf_data=$PERF_DATA"

cd "$GAMEDIR/bin" || exit 1

# Launch the reload in the background.
timeout 180 wine "$GAMEDIR/bin/$EXE_NAME" \
    /init init_faf.lua \
    /map /maps/SCMP_009/SCMP_009_scenario.lua \
    /loadsave "$WIN_SNAP" \
    /ai m28ai \
    /log "$WIN_LOG" \
    /nobugreport /nosound /nomovie "${SHOWLOG_ARG[@]}" \
    >"$WINE_LOG" 2>&1 &
WINE_PID=$!

# Wait until the sim is actually ticking post-reload (FAF_BEAT appears), up to 120s.
echo "[profile] waiting for post-reload sim ticks..."
for i in $(seq 1 60); do
    sleep 2
    if grep -q 'FAF_BEAT: ticks=' "$MOHO_LOG" 2>/dev/null; then
        echo "[profile] sim ticking (waited ${i}x2s)"; break
    fi
    if ! kill -0 "$WINE_PID" 2>/dev/null; then
        echo "[profile] wine exited before ticking — load failed"; tail -5 "$MOHO_LOG" 2>/dev/null; exit 1
    fi
done

# Find the hottest ForgedAlliance thread (the sim thread pegs one core).
sleep 3
TID=$(ps -eLo tid,pcpu,comm --sort=-pcpu | grep -i 'ForgedAll' | head -1 | awk '{print $1}')
CPU=$(ps -eLo tid,pcpu,comm --sort=-pcpu | grep -i 'ForgedAll' | head -1 | awk '{print $2}')
echo "[profile] hottest sim thread tid=$TID cpu=${CPU}%"
[[ -z "$TID" ]] && { echo "no busy thread found"; exit 1; }

BEAT_START=$(grep -oE 'FAF_BEAT: ticks=[0-9]+ gt=[0-9.]+ rt=[0-9.]+' "$MOHO_LOG" | tail -1)
echo "[profile] beat at record start: $BEAT_START"

echo "[profile] perf record -F $PERF_HZ -t $TID for ${PERF_SECS}s ..."
perf record -F "$PERF_HZ" -t "$TID" -o "$PERF_DATA" -- sleep "$PERF_SECS" 2>>"$WINE_LOG"

BEAT_END=$(grep -oE 'FAF_BEAT: ticks=[0-9]+ gt=[0-9.]+ rt=[0-9.]+' "$MOHO_LOG" | tail -1)
echo "[profile] beat at record end:   $BEAT_END"

# Stop the game.
for p in $(pgrep -f 'ForgedAlliance_faf'); do kill -9 "$p" 2>/dev/null; done

echo ""
echo "=== DSO breakdown (where the time goes, by module) ==="
perf report -i "$PERF_DATA" --stdio --sort=dso 2>/dev/null | grep -vE '^#|^$' | head -15

echo ""
echo "=== Top symbols in ForgedAlliance_faf.exe (engine self-time) ==="
perf report -i "$PERF_DATA" --stdio --dsos=ForgedAlliance_faf.exe --sort=symbol 2>/dev/null \
    | grep -vE '^#|^$' | head -30

echo ""
echo "=== ms/tick over the window (from FAF_BEAT rt timeline) ==="
grep -oE 'FAF_BEAT: ticks=[0-9]+ gt=[0-9.]+ rt=[0-9.]+' "$MOHO_LOG" | tail -20 \
    | awk '{for(i=1;i<=NF;i++){if($i ~ /ticks=/){split($i,a,"=");t=a[2]} if($i ~ /rt=/){split($i,b,"=");r=b[2]}}
            if(pt){dt=t-pt; dr=r-pr; if(dt>0) printf "  ticks %d..%d: %.1f ms/tick\n", pt, t, 1000*dr/dt}
            pt=t; pr=r}'

echo ""
echo "perf_data=$PERF_DATA  moho_log=$MOHO_LOG"
