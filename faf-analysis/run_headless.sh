#!/bin/bash
# Headless SC:FA (FAF) launcher for automated testing on Linux/Wine.
#
# Strategy:
#   - Stage all binaries and assets under $GAMEDIR (see wine-setup.md for layout).
#   - Use Xvfb to provide a virtual display so the game can create its window
#     and proceed past D3D init even though there is no real display attached.
#   - Run under a dedicated wine prefix ($WINEPREFIX) that has vcrun2005, d3dx9,
#     and dsound installed via winetricks.

set -u

GAMEDIR="/home/narfman0/.openclaw/workspace/faf/game"
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-supcom}"
TIMESTAMP=$(date +%s)
LOGDIR="/tmp/supcom-logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/supcom-$TIMESTAMP.log"
WINELOG="$LOGDIR/wine-$TIMESTAMP.log"

# Quiet Wine output
export WINEDEBUG="${WINEDEBUG:-fixme-all,err+module,err+dll}"

# Start a virtual X display if Xvfb is not already running on :99.
if ! pgrep -af "Xvfb :99" > /dev/null; then
  Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
  XVFB_PID=$!
  # Give Xvfb a moment to come up
  sleep 1
  trap 'kill $XVFB_PID 2>/dev/null' EXIT
fi

export DISPLAY=:99

# The Moho log file path is interpreted by the engine as a windows path
# relative to the current directory. We pass an absolute Z: path so it
# lands somewhere predictable on the unix side.
WIN_LOGFILE="Z:${LOGFILE//\//\\}"

cd "$GAMEDIR/bin" || exit 1

echo "[run_headless] WINEPREFIX=$WINEPREFIX"
echo "[run_headless] GAMEDIR=$GAMEDIR"
echo "[run_headless] log=$LOGFILE"
echo "[run_headless] wine stderr=$WINELOG"

# /init init_faf.lua            select FAF init script (lives next to exe in bin/)
# /log <path>                   write Moho log to the given path
# /nobugreport                  skip the bug report dialog
# /nosound                      no sound device required
# /nomovie                      skip startup movies
# /showlog                      print log to stdout as well (helpful here)
timeout 90 wine \
  "$GAMEDIR/bin/SupremeCommander.exe" \
  /init init_faf.lua \
  /log "$WIN_LOGFILE" \
  /nobugreport /nosound /nomovie /showlog \
  "$@" \
  > "$WINELOG" 2>&1
EC=$?

echo "[run_headless] wine exit code: $EC"
echo "[run_headless] last 60 wine lines:"
tail -n 60 "$WINELOG"

if [ -f "$LOGFILE" ]; then
  echo "[run_headless] Moho log: $LOGFILE"
  echo "[run_headless] interesting Moho log lines:"
  grep -iE "beat|checksum|error|fatal|warning|mount" "$LOGFILE" 2>/dev/null | head -80
else
  echo "[run_headless] WARNING: no Moho log produced at $LOGFILE"
  # Look in the Wine user profile too, just in case
  find "$WINEPREFIX/drive_c" -maxdepth 6 -name "*.log" -newer "$WINELOG" 2>/dev/null
fi

exit $EC
