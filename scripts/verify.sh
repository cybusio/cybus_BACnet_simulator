#!/usr/bin/env bash
# Verify BACnet SCF against Connectware — subscribes to MQTT, checks data flows and logs.
# Usage: ./scripts/verify.sh <broker> <scf-file> <topic-prefix> [--timeout N] [--check-logs <container>]
set -uo pipefail

TIMEOUT=60
CONTAINER=""
MQTT_USER="${MQTT_USER:-admin}"
MQTT_PASS="${MQTT_PASS:-admin}"

if [[ $# -lt 3 ]]; then
  cat <<'USAGE'
Usage: ./scripts/verify.sh <broker> <scf-file> <topic-prefix> [options]

  broker         MQTT broker URL (mqtt://host:port)
  scf-file       Path to the deployed SCF YAML
  topic-prefix   CW service topic prefix (e.g., services/newlift_gateway)
  --timeout N    Seconds to wait for all topics (default: 60)
  --check-logs C Check container C logs for BACnet-specific patterns

Example:
  ./scripts/verify.sh mqtt://192.168.1.100:1883 scf/newlift_gateway.yml services/newlift_gateway
  ./scripts/verify.sh mqtt://10.0.0.5:1883 scf/miele.yml services/miele --check-logs protocol-mapper
USAGE
  exit 1
fi

BROKER="$1"
SCF_FILE="$2"
TOPIC_PREFIX="$3"
shift 3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --check-logs) CONTAINER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if ! command -v mosquitto_sub &>/dev/null; then
  echo "ERROR: mosquitto_sub not found. Install: apt install mosquitto-clients / brew install mosquitto"
  exit 1
fi

[[ ! -f "$SCF_FILE" ]] && echo "ERROR: SCF not found: $SCF_FILE" && exit 1

BROKER_HOST=$(echo "$BROKER" | sed 's|mqtt://||' | cut -d: -f1)
BROKER_PORT=$(echo "$BROKER" | sed 's|mqtt://||' | cut -d: -f2)
BROKER_PORT="${BROKER_PORT:-1883}"

# Extract endpoint topic names from SCF (the topic: field on each endpoint)
TOPICS=$(grep '^\s*topic:' "$SCF_FILE" | sed 's/.*topic:\s*//' | tr -d "'" | tr -d '"')
TOPIC_COUNT=$(echo "$TOPICS" | grep -c . || true)

if [[ "$TOPIC_COUNT" -eq 0 ]]; then
  echo "ERROR: SCF has no endpoints (0 topic: fields found)" >&2
  exit 1
fi

echo "=== BACnet SCF Verification ==="
echo "Broker:  $BROKER_HOST:$BROKER_PORT"
echo "SCF:     $SCF_FILE"
echo "Prefix:  $TOPIC_PREFIX"
echo "Topics:  $TOPIC_COUNT expected"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Subscribe to the service topic tree
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"; kill %1 2>/dev/null' EXIT INT TERM

echo "── Subscribing to $TOPIC_PREFIX/# ──"

mosquitto_sub \
  -h "$BROKER_HOST" -p "$BROKER_PORT" \
  -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t "$TOPIC_PREFIX/#" -v \
  -W "$TIMEOUT" \
  > "$TMPFILE" 2>/dev/null &
SUB_PID=$!

SEEN=0; STARTED=$(date +%s)
while kill -0 $SUB_PID 2>/dev/null; do
  sleep 2
  # Count unique topic suffixes (strip prefix, match against SCF topics)
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

# Log analysis (failures here affect exit code)
LOG_FAIL=0
if [[ -n "$CONTAINER" ]]; then
  echo ""
  echo "── Log analysis ($CONTAINER) ──"
  LOGS=$(docker logs "$CONTAINER" 2>&1 | tail -200)

  # CC-4155: check abort handling (C++ stderr + JS-level fallback)
  ABORTS=$(echo "$LOGS" | grep -c "BACnet ABORT" || true)
  FALLBACKS=$(echo "$LOGS" | grep -c "Response too large, using indexed reads" || true)
  if [[ "$ABORTS" -gt 0 || "$FALLBACKS" -gt 0 ]]; then
    echo "  Abort activity: $ABORTS C++ aborts, $FALLBACKS indexed-read fallbacks"
    echo "$LOGS" | grep -E "BACnet ABORT|Response too large" | tail -3 | sed 's/^/    /'
    echo "$LOGS" | grep -q "invoke_id=" && echo "  [+] New abort format (invoke_id present)"
    [[ "$FALLBACKS" -gt 0 ]] && echo "  [+] Indexed-read fallback active (CC-4155/4157 working)"
  else
    echo "  No abort activity"
  fi

  # Regression checks — these FAIL the run
  if echo "$LOGS" | grep -q "Abort handler was called"; then
    echo "  [!] FAIL: Old abort format detected (pre-CC-4155)"
    LOG_FAIL=1
  fi
  if echo "$LOGS" | grep -q "Reserved for Use by ASHRAE"; then
    echo "  [!] FAIL: Unmapped abort code detected (pre-CC-4155)"
    LOG_FAIL=1
  fi

  CONC=$(echo "$LOGS" | grep -c "Maximum concurrency reached" || true)
  if [[ "$CONC" -gt 0 ]]; then
    echo "  [!] FAIL: TSM exhaustion — 'Maximum concurrency reached' x${CONC}"
    LOG_FAIL=1
  else
    echo "  [+] No TSM exhaustion"
  fi

  # CC-4156/4157: capability discovery (informational, not gated)
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
