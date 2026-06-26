#!/usr/bin/env bash
# Verify a deployed BACnet SCF against a running Connectware instance.
#
# Subscribes to the service's MQTT topics, waits for fresh data from each endpoint,
# and checks protocol-mapper logs for regressions (old abort format, TSM exhaustion).
# Only counts live publishes — retained messages are ignored (-R flag).
#
# Derives the MQTT topic prefix from the SCF's metadata.name (stripped of _ and -
# to match CW's topic normalization). Auto-finds the protocol-mapper container.
set -uo pipefail

TIMEOUT=60
MQTT_USER="${MQTT_USER:-admin}"
MQTT_PASS="${MQTT_PASS:-admin}"
MQTT_PORT="${MQTT_PORT:-1883}"

if [[ $# -lt 2 ]]; then
  cat <<'USAGE'
Usage: ./qa/tools/verify.sh <cw-host> <scf-file> [--timeout N]

  cw-host     Connectware host IP (where the MQTT broker runs)
  scf-file    The same SCF YAML that was uploaded to Connectware

Options:
  --timeout N   Seconds to wait for all topics (default: 60)

Environment:
  MQTT_USER     MQTT username (default: admin)
  MQTT_PASS     MQTT password (default: admin)
  MQTT_PORT     MQTT port (default: 1883)

Example:
  ./qa/tools/verify.sh 192.168.1.100 scf/newlift_gateway.yml
  ./qa/tools/verify.sh 10.0.0.5 scf/miele_energy_meter.yml --timeout 120
USAGE
  exit 1
fi

CW_HOST="$1"
SCF_FILE="$2"
shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if ! command -v mosquitto_sub &>/dev/null; then
  echo "ERROR: mosquitto_sub not found. Install: apt install mosquitto-clients / brew install mosquitto"
  exit 1
fi

[[ ! -f "$SCF_FILE" ]] && echo "ERROR: SCF not found: $SCF_FILE" && exit 1

# Derive service name from SCF metadata
# CW uses metadata.name as-is for MQTT topic prefix
SCF_NAME=$(grep '^\s*name:' "$SCF_FILE" | head -1 | sed 's/.*name:\s*//' | tr -d "'" | tr -d '"' | xargs)
TOPIC_PREFIX="services/${SCF_NAME}"

# Extract endpoint topics from SCF
TOPICS=$(grep '^\s*topic:' "$SCF_FILE" | sed 's/.*topic:\s*//' | tr -d "'" | tr -d '"')
TOPIC_COUNT=$(echo "$TOPICS" | grep -c . || true)

if [[ "$TOPIC_COUNT" -eq 0 ]]; then
  echo "ERROR: SCF has no endpoints (0 topic: fields found)" >&2
  exit 1
fi

# Find protocol-mapper container — log analysis is mandatory, so an empty result
# is a hard failure (a silent skip would let log regressions pass unnoticed).
PM_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i protocol-mapper | head -1)
if [[ -z "$PM_CONTAINER" ]]; then
  echo "ERROR: no protocol-mapper container found — cannot run log analysis" >&2
  exit 1
fi

echo "=== BACnet SCF Verification ==="
echo "CW host:    $CW_HOST"
echo "SCF:        $SCF_FILE"
echo "Service:    $SCF_NAME"
echo "Topics:     $TOPIC_COUNT expected under $TOPIC_PREFIX/#"
echo "Timeout:    ${TIMEOUT}s"
[[ -n "$PM_CONTAINER" ]] && echo "Log source: $PM_CONTAINER"
echo ""

# Subscribe to the service topic tree
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"; kill %1 2>/dev/null' EXIT INT TERM

echo "── Subscribing to $TOPIC_PREFIX/# ──"

# -R ignores retained messages — only count fresh publishes from a live device
mosquitto_sub \
  -h "$CW_HOST" -p "$MQTT_PORT" \
  -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t "$TOPIC_PREFIX/#" -v -R \
  -W "$TIMEOUT" \
  > "$TMPFILE" 2>/dev/null &
SUB_PID=$!

SEEN=0; STARTED=$(date +%s)
while kill -0 $SUB_PID 2>/dev/null; do
  sleep 2
  NOW_SEEN=$(cut -d' ' -f1 "$TMPFILE" | sed "s|^${TOPIC_PREFIX}/||" | sort -u | wc -l | tr -d ' ')
  ELAPSED=$(( $(date +%s) - STARTED ))
  if [[ "$NOW_SEEN" -ne "$SEEN" ]]; then
    SEEN=$NOW_SEEN
    printf "  %d/%d topics (%ds)\n" "$SEEN" "$TOPIC_COUNT" "$ELAPSED"
  fi
  if [[ "$SEEN" -ge "$TOPIC_COUNT" ]]; then
    kill $SUB_PID 2>/dev/null; break
  fi
done
wait $SUB_PID 2>/dev/null || true

ELAPSED=$(( $(date +%s) - STARTED ))
RECEIVED_TOPICS=$(cut -d' ' -f1 "$TMPFILE" | sed "s|^${TOPIC_PREFIX}/||" | sort -u)
RECEIVED=$(echo "$RECEIVED_TOPICS" | grep -c . || true)

echo ""
echo "── Results ──"
echo "  Received: $RECEIVED / $TOPIC_COUNT in ${ELAPSED}s"

if [[ "$RECEIVED" -ge "$TOPIC_COUNT" ]]; then
  # Presence check only: each topic published >=1 message. Value sanity is not
  # asserted here — this is a liveness probe, not a data-integrity gate.
  echo "  PASS: All endpoints publishing"
else
  echo "  FAIL: Missing $(( TOPIC_COUNT - RECEIVED )) topics"
  for t in $TOPICS; do
    echo "$RECEIVED_TOPICS" | grep -qF "$t" || echo "    missing: $t"
  done
fi

# Sample values
echo ""
echo "── Sample values ──"
tail -5 "$TMPFILE" | while IFS= read -r line; do
  topic=$(echo "$line" | cut -d' ' -f1 | sed "s|^${TOPIC_PREFIX}/||")
  value=$(echo "$line" | cut -d' ' -f2-)
  printf "  %-20s %s\n" "$topic" "$value"
done

# Log analysis (failures affect exit code)
LOG_FAIL=0
if [[ -n "$PM_CONTAINER" ]]; then
  echo ""
  echo "── Log analysis ($PM_CONTAINER) ──"
  LOGS=$(docker logs "$PM_CONTAINER" 2>&1 | tail -200)

  # Abort handling
  ABORTS=$(echo "$LOGS" | grep -c "BACnet ABORT" || true)
  FALLBACKS=$(echo "$LOGS" | grep -c "Response too large, using indexed reads" || true)
  if [[ "$ABORTS" -gt 0 || "$FALLBACKS" -gt 0 ]]; then
    echo "  Abort activity: $ABORTS C++ aborts, $FALLBACKS indexed-read fallbacks"
    echo "$LOGS" | grep -E "BACnet ABORT|Response too large" | tail -3 | sed 's/^/    /'
    echo "$LOGS" | grep -q "invoke_id=" && echo "  [+] New abort format (invoke_id present)"
    [[ "$FALLBACKS" -gt 0 ]] && echo "  [+] Indexed-read fallback active"
  else
    echo "  No abort activity"
  fi

  # Regression checks — FAIL the run
  if echo "$LOGS" | grep -q "Abort handler was called"; then
    echo "  [!] FAIL: Old abort format (pre-fix)"
    LOG_FAIL=1
  fi
  if echo "$LOGS" | grep -q "Reserved for Use by ASHRAE"; then
    echo "  [!] FAIL: Unmapped abort code (pre-fix)"
    LOG_FAIL=1
  fi

  CONC=$(echo "$LOGS" | grep -c "Maximum concurrency reached" || true)
  if [[ "$CONC" -gt 0 ]]; then
    echo "  [!] FAIL: TSM exhaustion x${CONC}"
    LOG_FAIL=1
  else
    echo "  [+] No TSM exhaustion"
  fi

  # Capability discovery (informational)
  echo "$LOGS" | grep -q "Device capabilities" && {
    echo "  [+] Capability discovery:"
    echo "$LOGS" | grep "Device capabilities" | tail -1 | sed 's/^/    /'
  }
fi

echo ""
if [[ "$RECEIVED" -lt "$TOPIC_COUNT" ]]; then
  echo "RESULT: FAIL ($RECEIVED/$TOPIC_COUNT topics, ${ELAPSED}s)"
  exit 1
elif [[ "$LOG_FAIL" -gt 0 ]]; then
  echo "RESULT: FAIL (topics OK but log regression detected)"
  exit 1
else
  echo "RESULT: PASS ($RECEIVED/$TOPIC_COUNT, ${ELAPSED}s)"
  exit 0
fi
