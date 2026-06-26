#!/usr/bin/env bash
# =============================================================================
# miele-spectrum-e2e.sh — drive the REAL Miele factory SCFs (scf/miele/
# connection_bacnet.yaml + receive_services/...TotalElectricalEnergyConsumption)
# against every BACnet device-characteristic profile, ONE AT A TIME, to find
# what/where the adapter fails NOW.
#
# The receive SCF's two ENABLED points (SumRealPower / SumRealEnergy) expose
# objectType + objectInstance as PARAMETERS, so we retarget them to objects that
# EXIST on each profile (Miele keeps its native AI57/AI61). What is tested is the
# DEVICE CHARACTERISTIC — abort 1/4/11, no-segmentation, 206B APDU, ultra-slow,
# empty, no-RPM — not a wrong instance. The full real pipeline runs unchanged:
# 6 endpoints -> per-node mappings -> collect -> burst(2) -> JSONata -> /combined.
#
# Per profile: deploy real conn+recv -> wait enabled -> settle -> read the real
# /combined output -> scan the PM log window (scoped to this connection) ->
# classify -> tear the two services down. Sims stay up (passive); only ONE Miele
# SCF is deployed at any moment.
#
# Outcomes:
#   FLOW      both enabled reads returned real values: /combined has kW + kW·h
#   GRACEFUL  reads fail cleanly (unknown-object / empty device): no data, but the
#             adapter stays connected with an actionable WARN — NO storm/TSM/crash
#   DEGRADED  /combined published but a point is 0/NULL
#   FAIL      adapter problem: not enabled / reconnect storm / TSM exhaustion / crash
#
# Sims must already be up (docker compose -f compose.yaml up). LOCAL only.
# Usage: miele-spectrum-e2e.sh <profile-key> | all | cleanup
#   keys: modern newlift legacy miele energy abort_seg no_rpm ultra_slow empty
# Env: CW_HOST CW_USER CW_PASS · MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS · SIM_HOST · PM
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MIELE="$(dirname "$DIR")/scf/miele"
CONN="$MIELE/connection_bacnet.yaml"
RECV="$MIELE/receive_services/receive_bacnet_TotalElectricalEnergyConsumption_DA_115_2.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"
POLL_MS="${POLL_MS:-5000}"

# Per-profile object map (from qa/inproc/device_profiles.py). Two enabled
# scalar reads retargeted to objects that exist on the device; Miele uses native
# AI57/AI61. Columns: key port dev p1type p1inst p2type p2inst capture expect note
read -r -d '' ROWS <<'TSV' || true
modern	47811	400001	analog-input	1	analog-input	2	16	FLOW	1476B seg-both, no abort — clean
newlift	47812	2000	analog-value	1	analog-value	4	16	FLOW	1476B seg-both, AV-only device
legacy	47810	300001	analog-input	1	analog-input	2	16	FLOW	206B no-seg abort-1 — scalars fit
miele	47808	1014006	analog-input	57	analog-input	61	20	FLOW	native AI57/AI61; 480B no-seg abort-1
energy	47809	2000001	analog-input	1	analog-input	2	20	FLOW	480B no-seg abort-11 — scalars fit
abort_seg	47817	600002	analog-input	1	analog-input	2	20	FLOW	480B abort-4 segNotSupported — scalars fit
no_rpm	47816	600001	analog-input	1	analog-input	2	18	FLOW	no RPM advertised — plain ReadProperty
ultra_slow	47818	600003	analog-input	1	analog-input	2	34	FLOW	slow responder near the read deadline
empty	47819	600004	analog-input	1	analog-input	2	16	GRACEFUL	0 objects — unknown-object, no data, stays connected
TSV

for c in curl jq mosquitto_sub base64 docker; do
  command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done
docker inspect "$PM" >/dev/null 2>&1 || { echo "ERROR: PM container $PM not found" >&2; exit 1; }

login() {
  TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
  [[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed at $API" >&2; exit 1; }
}
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { # deploy <id> <scf> <params-json>
  auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' \
    -d '{"operation":"enable"}' >/dev/null
}
svc_state() { auth "$API/v2/services?pageSize=500" \
  | jq -r --arg id "$1" '[.data[]|select(.serviceId==$id)][0].currentState // "absent"'; }
wait_enabled() { # wait_enabled <id> <timeout-s>
  local id="$1" t="${2:-40}"
  for _ in $(seq 1 "$t"); do
    [[ "$(svc_state "$id")" == "enabled" ]] && return 0
    sleep 1
  done
  return 1
}
remove() { # remove <id...>; disable+delete, then wait until 404
  local id
  for id in "$@"; do
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' \
      -d '{"operation":"disable"}' >/dev/null 2>&1 || true
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 30); do
    local pending=0
    for id in "$@"; do
      [[ "$(auth -o /dev/null -w '%{http_code}' "$API/services/$id")" != "404" ]] && { pending=1; break; }
    done
    [[ "$pending" -eq 0 ]] && return
    sleep 1
  done
}

RESULTS=()  # "key|verdict|power|energy|detail"

run_one() { # run_one <tsv-row>
  local key port dev p1t p1i p2t p2i cap expect note
  IFS=$'\t' read -r key port dev p1t p1i p2t p2i cap expect note <<<"$1"
  local conn="spec_conn_${key}" recv="spec_recv_${key}"
  echo ""
  echo "=== [$key] $SIM_HOST:$port dev $dev — ${p1t}:${p1i}+${p2t}:${p2i} (expect $expect) — $note"
  remove "$recv" "$conn"

  deploy "$conn" "$CONN" \
    "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$port,\"device_instance\":$dev,\"machine_common_name\":\"$key\"}"
  if ! wait_enabled "$conn" 40; then
    echo "  [!] connection did not enable"; RESULTS+=("$key|FAIL|-|-|connection not enabled"); remove "$conn"; return
  fi
  deploy "$recv" "$RECV" \
    "{\"bacnet_connection_service_id\":\"$conn\",\"machine_common_name\":\"$key\",\"PollInterval\":$POLL_MS,\"identifier_param\":\"$key\",\"SumRealPower\":$p1i,\"SumRealPowerObjectType\":\"$p1t\",\"SumRealPowerState\":\"enabled\",\"SumRealEnergy\":$p2i,\"SumRealEnergyObjectType\":\"$p2t\",\"SumRealEnergyState\":\"enabled\"}"
  if ! wait_enabled "$recv" 40; then
    echo "  [!] receive did not enable"; RESULTS+=("$key|FAIL|-|-|receive not enabled"); remove "$recv" "$conn"; return
  fi

  # Settle, then grab the freshest /combined and a PM log window scoped to this conn.
  local combined pmwin state
  combined=$(timeout "$cap" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -R -t "services/$recv/+/combined" -C 1 2>/dev/null)
  state=$(svc_state "$recv")
  pmwin=$(docker logs --since "$((cap + 14))s" "$PM" 2>&1 | grep -F "$conn-bacnet_connection")

  local storm tsm crash unknown deadline
  storm=$(grep -ciE 'connectlost|reconnecting' <<<"$pmwin" || true)
  tsm=$(grep -ciE 'max concurrency|encode failed|no free invoke' <<<"$pmwin" || true)
  crash=$(docker logs --since "$((cap + 14))s" "$PM" 2>&1 | grep -ciE 'unhandledrejection|uncaughtexception|fatal' || true)
  unknown=$(grep -ciE 'unknown-object|not present on device' <<<"$pmwin" || true)
  deadline=$(grep -ciE 'client deadline|read aborted|reply-time|exceeded' <<<"$pmwin" || true)

  local pv pu ev eu
  pv='-'; pu='-'; ev='-'; eu='-'
  if jq -e . <<<"$combined" >/dev/null 2>&1; then
    pv=$(jq -r '.sumRealPower.value // "-"' <<<"$combined"); pu=$(jq -r '.sumRealPower.unit // "-"' <<<"$combined")
    ev=$(jq -r '.sumRealEnergy.value // "-"' <<<"$combined"); eu=$(jq -r '.sumRealEnergy.unit // "-"' <<<"$combined")
  fi

  # FLOW requires real numeric readings, not just the JSONata unit literal
  # (unit is `value>=0 ? "kW" : "NULL"`, true for any value incl. 0/garbage).
  local numok=0
  [[ "$pv" =~ ^[0-9]+(\.[0-9]+)?$ && "$ev" =~ ^[0-9]+(\.[0-9]+)?$ ]] && numok=1

  local verdict detail
  if [[ "$state" != enabled || "$storm" -gt 1 || "$tsm" -gt 0 || "$crash" -gt 0 ]]; then
    verdict=FAIL; detail="state=$state storm=$storm tsm=$tsm crash=$crash"
  elif [[ -n "$combined" && "$pu" == "kW" && "$eu" == "kW·h" && "$numok" -eq 1 ]]; then
    verdict=FLOW; detail="P=$pv kW E=$ev kW·h  (unknown=$unknown deadline=$deadline)"
  elif [[ -n "$combined" ]]; then
    verdict=DEGRADED; detail="P=$pv/$pu E=$ev/$eu  (unknown=$unknown deadline=$deadline)"
  elif [[ "$unknown" -gt 0 || "$deadline" -gt 0 ]]; then
    verdict=GRACEFUL; detail="no /combined; connected, unknown=$unknown deadline=$deadline, no storm/TSM/crash"
  else
    verdict=FAIL; detail="no /combined and no explanatory WARN (state=$state)"
  fi
  echo "  -> $verdict  $detail"
  RESULTS+=("$key|$verdict|$pu|$eu|$detail")
  remove "$recv" "$conn"
}

print_matrix() {
  echo ""
  echo "================ MIELE-SCF × PROFILE MATRIX ================"
  printf "%-12s %-9s %-7s %-7s %s\n" "profile" "verdict" "P.unit" "E.unit" "detail"
  printf '%.0s-' {1..96}; echo ""
  local r key v pu eu detail
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r key v pu eu detail <<<"$r"
    printf "%-12s %-9s %-7s %-7s %s\n" "$key" "$v" "$pu" "$eu" "$detail"
  done
}

cmd_cleanup() {
  login
  local key
  while IFS=$'\t' read -r key _rest; do
    [[ -z "${key// }" ]] && continue
    remove "spec_recv_${key}" "spec_conn_${key}"
  done <<<"$ROWS"
  echo "==> spectrum SCFs removed"
}

main() {
  case "${1:-all}" in
    cleanup) cmd_cleanup ;;
    all)
      login
      while IFS= read -r row; do [[ -z "${row// }" ]] && continue; run_one "$row"; done <<<"$ROWS"
      print_matrix ;;
    *)
      local row; row=$(grep -P "^${1}\t" <<<"$ROWS")
      [[ -n "$row" ]] || { echo "unknown profile: $1" >&2; exit 2; }
      login; run_one "$row"; print_matrix ;;
  esac
}
main "$@"
