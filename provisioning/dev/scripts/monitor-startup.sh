#!/usr/bin/env bash
# monitor-startup.sh — Run and monitor the startup pipeline dynamically with heartbeat
set -uo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Start startup.sh in the background
log "Starting startup.sh in background..."
bash provisioning/dev/scripts/startup.sh > startup.log 2>&1 &
BG_PID=$!

log "Bootstrap started with background PID: ${BG_PID}"

LAST_LINE=0
while kill -0 ${BG_PID} 2>/dev/null; do
  TOTAL_LINES=$(wc -l < startup.log)
  if [ "${TOTAL_LINES}" -gt "${LAST_LINE}" ]; then
    START_L=$((LAST_LINE + 1))
    tail -n +"${START_L}" startup.log
    LAST_LINE=${TOTAL_LINES}
  fi
  sleep 15
done

# Print any final trailing lines
TOTAL_LINES=$(wc -l < startup.log)
if [ "${TOTAL_LINES}" -gt "${LAST_LINE}" ]; then
  START_L=$((LAST_LINE + 1))
  tail -n +"${START_L}" startup.log
fi

wait ${BG_PID}
EXIT_CODE=$?

log "Bootstrap process finished with exit code: ${EXIT_CODE}"
exit ${EXIT_CODE}
