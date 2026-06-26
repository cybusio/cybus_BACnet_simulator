#!/usr/bin/env bash
# FACTORY concurrency/isolation e2e — per-device isolation proven on a RUNNING
# Connectware via real MQTT + PM logs. Promotes the in-process factory-storm +
# scale-fleet isolation suites to the factory path.
#   conn_fast  → modern sim (healthy): object-name heartbeat at 1 Hz on MQTT.
#   conn_slow  → ultra-slow sim: reads exceed the deadline (lags / times out).
#   conn_bogus → unroutable addr: never connects, perpetual reconnect.
# All three share the one process-wide BACnet socket + TSM pool. Adversarial claim:
# conn_fast keeps FULL cadence on MQTT and never reconnects, regardless of the
# slow + bogus peers churning health-checks/reconnects beside it. No storm, no crash.
#   e2e/isolation-e2e.sh
# Prereqs: CW running; modern + ultra-slow sims up; curl jq mosquitto_sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/lifecycle/connection_hc.yaml"; RECV="$REPO/qa/scf/lifecycle/lifecycle_recv.yaml"
CW_HOST="${CW_HOST:-localhost}"; MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"; SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"; API="https://${CW_HOST}/api"
FAST_PORT=47811; FAST_DEV=400001; SLOW_PORT=47818; SLOW_DEV=600003; WIN="${WIN:-15}"

for c in curl jq mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c missing" >&2; exit 1; }; done
docker inspect "$PM" >/dev/null 2>&1 || { echo "ERROR: PM container $PM not found" >&2; exit 1; }
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
# Trap so a mid-run failure or Ctrl-C never leaks the deployed services on CW.
cleanup() { local id; for id in recv_fast recv_slow recv_bogus conn_fast conn_slow conn_bogus; do
    auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1; done; }
trap cleanup EXIT INT TERM
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }

echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
echo "==> deploy fast(modern) + slow(ultra-slow) + bogus(unroutable), 1 Hz heartbeat each"
deploy conn_fast  "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$FAST_PORT,\"device_instance\":$FAST_DEV,\"machine_common_name\":\"fast\"}"
deploy conn_slow  "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$SLOW_PORT,\"device_instance\":$SLOW_DEV,\"machine_common_name\":\"slow\"}"
deploy conn_bogus "$CONN" "{\"bacnet_host\":\"192.0.2.2\",\"bacnet_port\":47808,\"device_instance\":1,\"machine_common_name\":\"bogus\"}"
sleep 8
deploy recv_fast  "$RECV" "{\"bacnet_connection_service_id\":\"conn_fast\",\"machine_common_name\":\"fast\",\"device_instance\":$FAST_DEV,\"interval\":1000}"
deploy recv_slow  "$RECV" "{\"bacnet_connection_service_id\":\"conn_slow\",\"machine_common_name\":\"slow\",\"device_instance\":$SLOW_DEV,\"interval\":1000}"
deploy recv_bogus "$RECV" "{\"bacnet_connection_service_id\":\"conn_bogus\",\"machine_common_name\":\"bogus\",\"device_instance\":1,\"interval\":1000}"

echo "==> settle + capture ${WIN}s of MQTT heartbeats across all three"
sleep 5
T0=$(date +%s)
CAP=$(timeout "$WIN" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -R -t 'services/+/life/name' -F '%t' 2>/dev/null || true)
LOG=$(docker logs --since "$(( $(date +%s) - T0 + WIN + 8 ))s" "$PM" 2>&1)
NFAST=$(grep -c '^services/recv_fast/life/name' <<<"$CAP")
NSLOW=$(grep -c '^services/recv_slow/life/name' <<<"$CAP")
NBOGUS=$(grep -c '^services/recv_bogus/life/name' <<<"$CAP")
echo "  heartbeats in ${WIN}s — fast=$NFAST slow=$NSLOW bogus=$NBOGUS (fast ~1 Hz expected)"

# The conn_fast "never reconnects" and "no crash" checks grep $LOG negatively and
# pass vacuously if the window is empty — require a real PM log window first.
check "PM log window captured (negative assertions are meaningful)" '[[ -n "$LOG" ]]' "empty PM log window"

check "healthy peer keeps FULL cadence on MQTT despite slow+bogus neighbours (>=12 in ${WIN}s)" \
  '[[ "$NFAST" -ge 12 ]]' "fast=$NFAST"
check "slow peer demonstrably lags the healthy one (isolation, not lockstep)" \
  '[[ "$NSLOW" -lt "$NFAST" ]]' "slow=$NSLOW fast=$NFAST"
check "unroutable peer never delivers (0 heartbeats)" \
  '[[ "$NBOGUS" -eq 0 ]]' "bogus=$NBOGUS"
check "healthy connection never reconnects under the noisy neighbours" \
  "[[ \$(grep -E 'id\":\"conn_fast-' <<<\"\$LOG\" | grep -ciE 'Reconnecting|connect failed') -eq 0 ]]" \
  "conn_fast saw $(grep -E 'id\":\"conn_fast-' <<<"$LOG" | grep -ciE 'Reconnecting|connect failed') reconnect events"
check "slow + bogus peers ARE in the reconnect loop (genuinely stuck, not silently ok)" \
  "grep -qE 'id\":\"conn_(slow|bogus)-' <<<\"\$LOG\" && grep -E 'id\":\"conn_(slow|bogus)-' <<<\"\$LOG\" | grep -qiE 'Reconnecting|Failed to reach|reconnect'" \
  "slow/bogus not observed reconnecting"
check "no crash under mixed-health concurrency (0 unhandledRejection/uncaught/fatal)" \
  "[[ \$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<\"\$LOG\") -eq 0 ]]" "crash markers seen"

echo "==> cleanup"; cleanup
echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
