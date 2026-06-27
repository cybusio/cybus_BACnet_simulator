#!/usr/bin/env bash
# Write-depth e2e — adapter handleWrite paths (CC-4157) that rw-soak's happy-path
# round-trip does not exercise:
#   1. a write round-trips exactly on a healthy device (the adapter sends the write), and
#   2. a write to a device that ABORTS it SURFACES the failure as a
#      `warn: "Write failed because: …"` (verified — base Connection.write logs it after
#      BacnetConnection.handleWrite throws describeBacnetError; the failure is NOT silent),
#      and the connection STAYS connected (an ABORT from a live peer is proof-of-life, not a
#      loss — no reconnect storm, no crash).
# An aborting device (abort_storm, force_abort) is used rather than a stopped one: the
# connection stays up so the write is deterministically attempted+failed. (A stopped-device
# write races the health-check — attempted -> warns, or skipped-while-disconnected -> dropped.)
# Scope: priority-array DEVICE semantics (FV-003 rejection, FV-004 NULL relinquish) are left
# manual by choice, not necessity — the sim CAN serve commandable objects (bacpypes3 local
# classes) but the rw-fleet uses plain present-value; a commandable profile would automate them.
#
# Prereqs: CW up; rw-fleet up (gen-rw-fleet.sh + compose/rw-fleet.compose.yaml); abort_storm
# up (base compose.yaml). curl jq mosquitto_pub/sub docker base64.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"; MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; PM="${PM:-platform-protocol-mapper-1}"
API="https://$CW_HOST/api"
CONN="$REPO/qa/scf/miele/connection_bacnet.yaml"; RECV="$REPO/qa/scf/rw/rw_recv.yaml"
NORM_PORT=47950; NORM_DEV=4000000     # first rw-fleet device — healthy, writable
ABRT_PORT=47821; ABRT_DEV=1014008     # abort_storm — force_abort aborts every write; stays connected (proof-of-life)

for c in curl jq mosquitto_pub mosquitto_sub docker base64; do command -v "$c" >/dev/null || { echo "ERROR: $c missing" >&2; exit 1; }; done
. "$DIR/../tools/mqtt-env.sh"   # $MQTT_ARGS (dev plain / prod mqtts+TLS) + $CW_CURL_CA
TOKEN=$(curl -s $CW_CURL_CA -X POST "$API/login" -H 'Content-Type: application/json' -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token//empty')
[ -n "$TOKEN" ] || { echo "ERROR: no CW token" >&2; exit 1; }
auth(){ curl -sL $CW_CURL_CA -H "Authorization: Bearer $TOKEN" "$@"; }
mqp(){ mosquitto_pub $MQTT_ARGS "$@"; }
mqs(){ mosquitto_sub $MQTT_ARGS "$@"; }
deploy(){ auth -X POST "$API/services" -H 'Content-Type: application/json' \
            -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 <"$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
remove(){ for id; do auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1; auth -X DELETE "$API/services/$id" >/dev/null 2>&1; done; }
cleanup(){ remove recv_norm conn_norm recv_abrt conn_abrt; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
check(){ if eval "$2"; then echo "  [+] $1"; PASS=$((PASS+1)); else echo "  [!] FAIL: $1 — $3"; FAIL=$((FAIL+1)); fi; }

echo "==> deploy: healthy device $NORM_DEV@$NORM_PORT + aborting device $ABRT_DEV@$ABRT_PORT"
remove recv_norm conn_norm recv_abrt conn_abrt >/dev/null 2>&1
for _ in 1 2 3 4 5 6; do auth "$API/services" 2>/dev/null | jq -e '.data[]?|select(.id|test("_norm$|_abrt$"))' >/dev/null 2>&1 && sleep 2 || break; done
deploy conn_norm "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$NORM_PORT,\"device_instance\":$NORM_DEV,\"machine_common_name\":\"wdn\"}"
deploy conn_abrt "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$ABRT_PORT,\"device_instance\":$ABRT_DEV,\"machine_common_name\":\"wda\"}"
sleep 8
deploy recv_norm "$RECV" "{\"bacnet_connection_service_id\":\"conn_norm\",\"machine_common_name\":\"wdn\",\"interval\":1000}"
deploy recv_abrt "$RECV" "{\"bacnet_connection_service_id\":\"conn_abrt\",\"machine_common_name\":\"wda\",\"interval\":1000}"
sleep 6
# Wait until the healthy connection is actually reading before asserting — robust to a prior
# test's connection teardown still settling in the process-wide native client.
for _ in $(seq 1 12); do [ -n "$(mqs -R -t "services/recv_norm/rw/av0" -C 1 -W 3 2>/dev/null)" ] && break; sleep 2; done

# 1 — happy write round-trips exactly on the healthy device
V=$(( RANDOM % 50000 + 1000 ))
mqp -t "services/recv_norm/rw/av0w/set" -m "$V"; sleep 3
GOT=$(mqs -R -t "services/recv_norm/rw/av0" -C 1 -W 6 2>/dev/null | jq -r '.value // empty' 2>/dev/null)
check "write round-trips exactly on a healthy device (wrote $V, read ${GOT:-none})" '[[ "${GOT%.*}" == "$V" ]]' "got '${GOT:-none}'"

# 2 — a write to the aborting device must surface a 'Write failed because:' warn (not a
#     silent fake-success), and the connection must stay connected (ABORT = proof-of-life)
R0=$(docker inspect "$PM" --format '{{.RestartCount}}')
b=$(docker logs "$PM" 2>&1 | wc -l)
mqp -t "services/recv_abrt/rw/av0w/set" -m "$(( RANDOM % 50000 + 1000 ))"; sleep 8
WERR=$(docker logs "$PM" 2>&1 | tail -n +$((b+1)) | grep -icE 'Write failed because')
STORM=$(docker logs "$PM" 2>&1 | tail -n +$((b+1)) | grep -icE 'Reconnecting BacnetConnection|reconnect storm')
R1=$(docker inspect "$PM" --format '{{.RestartCount}}')
check "a failed write surfaces a 'Write failed because:' warn (not a silent fake-success)" '[[ "$WERR" -ge 1 ]]' "0 Write-failed warns in window"
check "the aborting device stays connected — no reconnect storm, no crash" '[[ "$STORM" -eq 0 && "$R0" == "$R1" ]]' "storm=$STORM restart $R0->$R1"

echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
