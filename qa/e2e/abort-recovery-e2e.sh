#!/usr/bin/env bash
# FACTORY abort/recovery e2e — SCFs deployed+enabled on a running Connectware,
# real MQTT data plane, real protocol-mapper logs. Adversarial, exact, not lenient.
#
# Deploys the abort_recv SCF against TWO real sims:
#   miele (47808, size-abort reason 1) — object-list too-large RECOVERS to an
#     exact 101-element array on MQTT; present-value flows; a mis-scoped point
#     (analog-value:999999) must NOT flow and must log the actionable fix.
#   replyTimeStorm (47822, reason 8 = application-exceeded-reply-time) — every
#     read aborts; NOTHING flows, the reason-8 abort is surfaced in the PM log,
#     and the connection stays UP (an ABORT is proof-of-life, not a loss).
# Proves the abort-reason fix + large-array recovery end-to-end through CW+MQTT,
# and graceful degradation (good points keep flowing while bad ones fail).
#
#   e2e/abort-recovery-e2e.sh
# Prereqs: CW running; miele+replyTimeStorm sims up (docker compose up); curl jq mosquitto_sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/miele/connection_bacnet.yaml"
RECV="$REPO/qa/scf/abort/abort_recv.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"; MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; POLL_MS="${POLL_MS:-2000}"; CAP="${CAP:-12}"
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"
MIELE_DEV=1014006; MIELE_PORT=47808; RTS_DEV=1014009; RTS_PORT=47822

for c in curl jq mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }; done
docker inspect "$PM" >/dev/null 2>&1 || { echo "ERROR: PM container $PM not found" >&2; exit 1; }
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
# Trap so a mid-run failure or Ctrl-C never leaks the deployed services on CW.
cleanup() { local id; for id in recv_miele recv_rts conn_miele conn_rts; do
    auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1; done; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }

echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
echo "==> deploy 2 connections + 2 abort receives (miele size-abort / replyTimeStorm reason-8)"
deploy conn_miele "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$MIELE_PORT,\"device_instance\":$MIELE_DEV,\"machine_common_name\":\"miele\"}"
deploy conn_rts   "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$RTS_PORT,\"device_instance\":$RTS_DEV,\"machine_common_name\":\"rts\"}"
sleep 8
deploy recv_miele "$RECV" "{\"bacnet_connection_service_id\":\"conn_miele\",\"machine_common_name\":\"miele\",\"device_instance\":$MIELE_DEV,\"interval\":$POLL_MS}"
deploy recv_rts   "$RECV" "{\"bacnet_connection_service_id\":\"conn_rts\",\"machine_common_name\":\"rts\",\"device_instance\":$RTS_DEV,\"interval\":$POLL_MS}"

echo "==> settle + capture ${CAP}s of MQTT + PM log"
sleep $(( POLL_MS * 4 / 1000 ))
T0=$(date +%s)
CAPFILE=$(mktemp -u); CAP_MQTT=$(timeout "$CAP" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -R -t 'services/+/abort/+' -F '%t %p' 2>/dev/null || true)
LOG=$(docker logs --since "$(( $(date +%s) - T0 + CAP + 15 ))s" "$PM" 2>&1)
# Negative log/MQTT assertions below pass vacuously on an empty capture — fail fast.
check "PM log window captured (negative assertions are meaningful)" '[[ -n "$LOG" ]]' "empty PM log window"

mq() { grep "^services/$1/abort/$2 " <<<"$CAP_MQTT" | tail -1 | cut -d' ' -f2-; }   # latest payload for recv/topic
mqcount() { grep -c "^services/$1/abort/$2 " <<<"$CAP_MQTT"; }

echo "== MIELE (size-abort reason 1): recovery + graceful degradation =="
OBJLIST=$(mq recv_miele objlist)
OBJLEN=$(jq -r '.value | length' <<<"$OBJLIST" 2>/dev/null || echo NaN)
check "object-list too-large RECOVERS to an exact 101-element array on MQTT" \
  '[[ "$OBJLEN" == "101" ]]' "got length=$OBJLEN"
# Length alone can't distinguish a clean recovery from 101 garbage elements:
# require every element to be a well-formed object-id — numeric objectInstance plus
# a type tag (objectTypeName or objectTypeId, the adapter may emit either).
check "every recovered object-list element is a well-formed object-id (not garbage)" \
  "jq -e '.value | (length>0) and all(type==\"object\" and (.objectInstance|type==\"number\") and (has(\"objectTypeName\") or has(\"objectTypeId\")))' <<<\"\$OBJLIST\" >/dev/null 2>&1" \
  "recovered elements are not all well-formed object-ids"
PVVAL=$(jq -r '.value' <<<"$(mq recv_miele pv)" 2>/dev/null || echo "")
check "present-value (analog-value:101009) keeps flowing (numeric) on MQTT" \
  '[[ "$PVVAL" =~ ^[0-9.]+$ ]]' "got value='$PVVAL'"
check "mis-scoped point (analog-value:999999) produces ZERO MQTT messages" \
  '[[ "$(mqcount recv_miele missing)" == "0" ]]' "got $(mqcount recv_miele missing) msgs"
check "PM log names the mis-scoped point + the SCF fix (describeBacnetError, exact)" \
  "grep -qF \"analog-value:999999 'present-value' not present on device — correct this point's objectInstance/objectType\" <<<\"\$LOG\"" \
  "actionable unknown-object line not found"

echo "== replyTimeStorm (reason 8 = application-exceeded-reply-time): surfaced, never recovered =="
check "reason-8 device: object-list NOT recovered — ZERO MQTT messages" \
  '[[ "$(mqcount recv_rts objlist)" == "0" ]]' "got $(mqcount recv_rts objlist) msgs"
check "reason-8 device: present-value ZERO MQTT messages" \
  '[[ "$(mqcount recv_rts pv)" == "0" ]]' "got $(mqcount recv_rts pv) msgs"
check "PM log surfaces the reason-8 abort name (application-exceeded-reply-time)" \
  "grep -qiF 'Application Exceeded Reply Time' <<<\"\$LOG\"" "reason-8 name not in PM log"
check "PM log shows it as a described read failure (point named + abort surfaced)" \
  "grep -qE \"read failed: BACnet ABORT.*Application Exceeded Reply Time\" <<<\"\$LOG\"" "described reply-time failure not found"

# Positive liveness: the reply-time "zero msgs" checks are guaranteed-zero against a
# DEAD adapter too. Prove the healthy miele receive published in the SAME window so
# an all-dead capture can't pass the reason-8 silence checks vacuously.
check "healthy miele present-value DID publish in the same window (capture is live)" \
  '[[ "$(mqcount recv_miele pv)" -gt 0 ]]' "no miele pv msgs — capture/adapter dead, reason-8 silence is meaningless"

echo "== graceful degradation / no storm =="
check "both connections stay enabled (no fail-to-connect)" \
  "[[ \$(auth \"\$API/v2/services?pageSize=500\" | jq -r '[.data[]|select(.serviceId|test(\"conn_(miele|rts)\"))|select(.currentState==\"enabled\")]|length') == 2 ]]" \
  "connections not both enabled"
check "no reconnect storm on the abort connections (0 connectLost)" \
  "[[ \$(grep -ciE 'connectlost|trying to reconnect' <<<\"\$LOG\") -eq 0 ]]" \
  "connectLost/reconnect seen: $(grep -ciE 'connectlost|trying to reconnect' <<<"$LOG")"
check "no crash (0 unhandledRejection/uncaught/fatal)" \
  "[[ \$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<\"\$LOG\") -eq 0 ]]" \
  "crash markers seen"

echo "==> cleanup"; cleanup
echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
