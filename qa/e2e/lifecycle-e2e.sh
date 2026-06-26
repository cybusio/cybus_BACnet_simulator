#!/usr/bin/env bash
# FACTORY lifecycle/reconnect e2e — the connection FSM proven on a RUNNING
# Connectware via real MQTT, real PM logs and a real peer power-cycle. Promotes
# the in-process connection-realism + reconnect suites to the factory path.
#   conn_life → modern sim (reachable): connects, object-name heartbeat on MQTT.
#   docker STOP the sim → heartbeat stops, health-check fires connectLost, FSM
#     enters reconnect (no crash). docker START → connection recovers, heartbeat resumes.
#   conn_dead → unroutable addr (RFC5737 192.0.2.1) → connectFailed → reconnect loop,
#     never connects, zero data, no crash (isolation: does not affect conn_life).
# Adversarial, exact, not lenient.
#   e2e/lifecycle-e2e.sh
# Prereqs: CW running; modern sim up (docker compose up bacnet-modern); curl jq mosquitto_sub docker.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/lifecycle/connection_hc.yaml"; RECV="$REPO/qa/scf/lifecycle/lifecycle_recv.yaml"
CW_HOST="${CW_HOST:-localhost}"; MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"; SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"; API="https://${CW_HOST}/api"
MODERN_PORT=47811; MODERN_DEV=400001; MODERN_CT="${MODERN_CT:-bacnet_simulator-bacnet-modern-1}"; POLL_MS=2000

for c in curl jq mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c missing" >&2; exit 1; }; done
docker inspect "$PM" >/dev/null 2>&1 || { echo "ERROR: PM container $PM not found" >&2; exit 1; }
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
# -R: count only FRESH publishes. A retained heartbeat would be delivered on every
# subscribe and falsely keep the Phase-2 "heartbeat stopped" count above zero.
heartbeat() { timeout "$1" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -R -t 'services/recv_life/life/name' 2>/dev/null | grep -c . ; }
# Trap so a mid-run failure or Ctrl-C (this script power-cycles a sim) never leaks services.
cleanup() { local id; for id in recv_life conn_life conn_dead; do
    auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1; done; }
trap cleanup EXIT INT TERM
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }

echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
echo "==> deploy conn_life (modern, short health-check) + conn_dead (unroutable) + recv_life"
deploy conn_life "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$MODERN_PORT,\"device_instance\":$MODERN_DEV,\"machine_common_name\":\"life\"}"
deploy conn_dead "$CONN" "{\"bacnet_host\":\"192.0.2.1\",\"bacnet_port\":47808,\"device_instance\":1,\"machine_common_name\":\"dead\"}"
sleep 8
deploy recv_life "$RECV" "{\"bacnet_connection_service_id\":\"conn_life\",\"machine_common_name\":\"life\",\"device_instance\":$MODERN_DEV,\"interval\":$POLL_MS}"

echo "== Phase 1: connected → heartbeat flows =="
sleep 5
N1=$(heartbeat 6)
check "reachable peer: object-name heartbeat flows on MQTT" '[[ "$N1" -ge 2 ]]' "got $N1 msgs"

echo "== Phase 2: peer drop (docker stop) → heartbeat stops, FSM detects connectLost =="
T_drop=$(date +%s); docker stop "$MODERN_CT" >/dev/null
# Health-check is interval=10s / failureThreshold=3 (hardcoded BACNET_DEFAULTS; the
# schema healthCheck knob was removed, so the SCF block is inert). A silent drop needs
# ~30s to drive connectLost — stay down past 3 ticks so it trips deterministically.
sleep 45
N2=$(heartbeat 5)
LOG2=$(docker logs --since "$(( $(date +%s) - T_drop + 6 ))s" "$PM" 2>&1)
check "peer drop: heartbeat STOPS on MQTT (zero msgs)" '[[ "$N2" -eq 0 ]]' "got $N2 msgs"
check "health-check detects the silent drop (Health check failed)" "grep -qiE 'health check failed' <<<\"\$LOG2\"" "no health-check failure logged"
check "FSM fires connectLost → reconnect, attributed to the health-check loss" "grep -qE 'Reconnecting BacnetConnection.*Health check failed' <<<\"\$LOG2\"" "no health-check-triggered Reconnecting logged"

echo "== Phase 3: peer back (docker start) → connection recovers, heartbeat resumes =="
T_up=$(date +%s); docker start "$MODERN_CT" >/dev/null
sleep 14
N3=$(heartbeat 6)
LOG3=$(docker logs --since "$(( $(date +%s) - T_up + 6 ))s" "$PM" 2>&1)
check "recovery: heartbeat RESUMES on MQTT" '[[ "$N3" -ge 2 ]]' "got $N3 msgs"
check "connection reports Connected again after recover" "grep -qiE 'connected bacnetconnection' <<<\"\$LOG3\"" "no reconnect-success logged"

echo "== Isolation + resilience =="
DEADSTATE=$(auth "$API/v2/services?pageSize=500" | jq -r '.data[]|select(.serviceId=="conn_dead")|.currentState')
check "unroutable conn_dead stays enabled (FSM reconnect loop, not crash)" '[[ "$DEADSTATE" == "enabled" ]]' "state=$DEADSTATE"
ALLLOG=$(docker logs --since "120s" "$PM" 2>&1)
# The crash check below is vacuous on an empty log — require a real window first.
check "PM log window captured (negative crash assertion is meaningful)" '[[ -n "$ALLLOG" ]]' "empty PM log window"
check "unroutable conn_dead never connects (connectFailed surfaced)" "grep -qiE 'failed to reach bacnet device' <<<\"\$ALLLOG\"" "no connectFailed for dead peer"
check "no crash across the whole cycle (0 unhandledRejection/uncaught/fatal)" "[[ \$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<\"\$ALLLOG\") -eq 0 ]]" "crash markers seen"

echo "==> cleanup"; cleanup
echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
