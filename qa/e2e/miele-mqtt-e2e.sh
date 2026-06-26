#!/usr/bin/env bash
# Full MQTT end-to-end + DATA-INTEGRITY verification for the Miele production fleet
# against a RUNNING Connectware. Deploys the 36 real receive SCFs (scf/miele/) + 4
# concentrator connections, enables them, then asserts every receive's /combined.
# Each concentrator object holds a UNIQUE STATIC value (40000+device_index*1000+
# instance), so an EXACT value match proves the receive read its own device AND
# instance — catching cross-device / cross-instance bleed or corruption.
# Idiomatic: curl + jq + mosquitto_sub.
#
#   e2e/miele-mqtt-e2e.sh            # cleanup -> deploy -> integrity-assert -> cleanup
#   e2e/miele-mqtt-e2e.sh deploy     # cleanup -> deploy, leave running
#   e2e/miele-mqtt-e2e.sh cleanup    # disable + delete the fleet
#
# Prereqs: Connectware running; the 4 concentrator sims up (gen-miele-profiles.sh +
#          miele-fleet.compose.yaml); curl, jq, mosquitto_sub.
# Env: CW_HOST CW_USER CW_PASS · MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS
#      SIM_HOST (172.18.0.1) · POLL_MS (2000)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MIELE="$(dirname "$DIR")/scf/miele"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; POLL_MS="${POLL_MS:-2000}"
API="https://${CW_HOST}/api"
declare -A PORT=( [2098177]=47870 [2098183]=47871 [2098184]=47872 [2098185]=47873 )

for c in curl jq mosquitto_sub base64; do
  command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done
MAP="$("$REPO/qa/gen/gen-miele-map.sh")"

TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: Connectware auth failed at $API" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }  # -L: GET /api/services 301s to /api/v2

fleet_ids() { # every service id: receives then connections
  tail -n +2 <<<"$MAP" | awk -F'\t' '{print "mielerecv_" $1}'
  for d in "${!PORT[@]}"; do echo "mieleconn_$d"; done
}

cleanup() {
  while read -r id; do
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1
  done < <(fleet_ids)
}

wait_gone() { # block until every fleet id is 404 (bounded)
  local id pending
  for _ in $(seq 1 30); do
    pending=0
    while read -r id; do
      [[ "$(auth -o /dev/null -w '%{http_code}' "$API/services/$id")" != "404" ]] && { pending=1; break; }
    done < <(fleet_ids)
    [[ "$pending" -eq 0 ]] && return
    sleep 1
  done
}

deploy() { # deploy <id> <scf-file> <params-json>
  auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null
}

deploy_fleet() {
  echo "==> deploy + enable 4 concentrator connections"
  for d in "${!PORT[@]}"; do
    deploy "mieleconn_$d" "$MIELE/connection_bacnet.yaml" \
      "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":${PORT[$d]},\"device_instance\":$d,\"machine_common_name\":\"m$d\"}"
  done
  sleep 10
  echo "==> deploy + enable 36 receive services"
  while IFS=$'\t' read -r da dev energy power id ev pv; do
    deploy "mielerecv_$da" "$MIELE/receive_services/receive_bacnet_TotalElectricalEnergyConsumption_DA_115_$da.yaml" \
      "{\"bacnet_connection_service_id\":\"mieleconn_$dev\",\"machine_common_name\":\"m_$da\",\"PollInterval\":$POLL_MS}"
  done < <(tail -n +2 <<<"$MAP")
}

assert_fleet() {
  echo "==> settle, then assert every receive's /combined (EXACT data-integrity)"
  sleep $(( POLL_MS * 6 / 1000 ))
  local pass=0 fail=0
  while IFS=$'\t' read -r da dev energy power id ev pv; do
    local payload pvarg
    payload=$(timeout 10 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
              -t "services/mielerecv_$da/+/combined" -C 1 2>/dev/null)
    pvarg=null; [[ "$pv" != "-" ]] && pvarg="$pv"
    if [[ -n "$payload" ]] && jq -e \
         --argjson ev "$ev" --argjson pv "$pvarg" --arg id "$id" '
           .sumRealEnergy as $e | .sumRealPower as $p |
           ((($e.value - $ev) | fabs) < 0.01)
           and ($e.unit == "kW·h") and ($e.range == {low: 0, high: 0})
           and (.identifier == $id) and ((.timestamp | type) == "number")
           and (.sumApparentEnergy.unit == "NULL" and .sumApparentPower.unit == "NULL"
                and .sumReactiveEnergy.unit == "NULL" and .sumReactivePower.unit == "NULL")
           and (if $pv == null then ($p.value == 0 and $p.unit == "NULL")
                else ((($p.value - $pv) | fabs) < 0.01 and $p.unit == "kW") end)
         ' <<<"$payload" >/dev/null 2>&1; then
      pass=$(( pass + 1 ))
    else
      echo "  FAIL $da (dev $dev, E$energy=$ev P$power=$pv id=$id): ${payload:0:160}"
      fail=$(( fail + 1 ))
    fi
  done < <(tail -n +2 <<<"$MAP")
  echo ""
  echo "PRODUCTION-FLEET INTEGRITY: $pass/$(( pass + fail )) receives exact-match their (device,instance) value"
  [[ "$fail" -eq 0 ]]
}

case "${1:-test}" in
  cleanup) echo "==> cleanup"; cleanup; wait_gone; echo "done" ;;
  deploy)  echo "==> remove any prior fleet"; cleanup; wait_gone; deploy_fleet; echo "==> deployed (left running)" ;;
  test)
    echo "==> remove any prior fleet"; cleanup; wait_gone
    deploy_fleet
    if assert_fleet; then rc=0; else rc=1; fi
    if [[ "${KEEP:-0}" == "1" ]]; then echo "==> KEEP=1 — fleet left uploaded on CW"; else echo "==> cleanup"; cleanup; fi
    echo "==> e2e result: $([[ $rc -eq 0 ]] && echo PASS || echo FAIL)"
    exit $rc ;;
  *) echo "usage: $0 [test|deploy|cleanup]" >&2; exit 2 ;;
esac
