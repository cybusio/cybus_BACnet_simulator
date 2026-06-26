#!/usr/bin/env bash
# Full-stack cert-SCF × device-profile matrix against a RUNNING Connectware.
# Deploys the REAL cert weatherstation SCF
#   system-test-fixtures/.../receive_bacnet_cov-endpoint_with-mapping_service.yaml
# (the exact factory file — 9 BACnet endpoints x {object-name,present-value,units}
# with cov/collect/filter/transform mapping) against each core device profile in
# turn, retargeting its 3 sensors onto that device's real analog-input instances,
# then asserts the real WeatherStation/combined MQTT output. This exercises the
# genuine factory pipeline (endpoint + mapping engine), not just a read probe, so
# it shows which device class the cert service flows on and which it can't.
#
#   e2e/cert-scf-matrix-e2e.sh           # per-profile deploy -> assert -> clean
#   e2e/cert-scf-matrix-e2e.sh KEEP=1    # leave the last profile deployed
#
# Prereqs: Connectware running; the core sim fleet up (docker compose up). The
# combined topic only flows when all 3 sensors poll, so a profile with <3
# analog-inputs (empty, newlift) is expected NOT to produce /combined — reported
# as such, not a failure of the adapter.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
FIX="$REPO/../system-test-fixtures/regression-tests/_bacnet_miele_missing_rainCurrent"
CERT_SCF="$FIX/receive_bacnet_cov-endpoint_with-mapping_service.yaml"
CONN_SCF="$REPO/qa/scf/miele/connection_bacnet.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; POLL_MS="${POLL_MS:-1000}"
API="https://${CW_HOST}/api"

for c in curl jq mosquitto_sub base64; do
  command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done
[[ -f "$CERT_SCF" ]] || { echo "ERROR: cert SCF not found at $CERT_SCF" >&2; exit 1; }

# profile: label|port|deviceInstance|present(1/0)  — the 3 sensors map to AI inst 1,2,3
PROFILES=(
  "modern|fast 1476B segmented (baseline)|47811|400001|1"
  "legacy|206B noSeg slow (constrained APDU)|47810|300001|1"
  "miele|array-ABORT(1) device, scalar read|47808|1014006|1"
  "energy|array-ABORT(11) device, scalar read|47809|2000001|1"
  "noRpm|no ReadPropertyMultiple|47816|600001|1"
  "abortSeg|ABORT(4) segNotSupported|47817|600002|1"
  "empty|0 analog-inputs (no /combined expected)|47819|600004|0"
)

TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: Connectware auth failed at $API" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }

del() { # disable + delete one service, ignore errors
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"disable"}' >/dev/null 2>&1
  auth -X DELETE "$API/services/$1" >/dev/null 2>&1
}
gone() { [[ "$(auth -o /dev/null -w '%{http_code}' "$API/services/$1")" == "404" ]]; }
wait_gone() { for _ in $(seq 1 20); do gone "$1" && gone "$2" && return; sleep 1; done; }

# Mid-run failure / Ctrl-C must not leak the in-flight profile's two services.
# Honour KEEP=1 (intentionally leaves the last profile deployed).
cid=""; rid=""
cleanup() { [[ "${KEEP:-0}" == "1" ]] && return; [[ -n "$rid" ]] && del "$rid"; [[ -n "$cid" ]] && del "$cid"; }
trap cleanup EXIT INT TERM

deploy() { # deploy <id> <scf> <params-json>
  auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null
}

pass=0; fail=0
declare -a VERDICT
for row in "${PROFILES[@]}"; do
  IFS='|' read -r key label port dev present <<<"$row"
  cid="certmxconn_$key"; rid="certmxrecv_$key"
  echo "==> [$key] $label  (port $port, device $dev)"
  del "$rid"; del "$cid"; wait_gone "$cid" "$rid"

  deploy "$cid" "$CONN_SCF" \
    "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$port,\"device_instance\":$dev,\"machine_common_name\":\"cm_$key\"}"
  sleep 6
  # cert SCF: 3 sensors -> analog-input inst 1,2,3; filter_object_count 3 (all 3 present)
  deploy "$rid" "$CERT_SCF" "$(jq -nc --arg c "$cid" '{
    bacnet_connection_service_id:$c, identifier_param:("DA_111_"+$c),
    sampling_interval:'"$POLL_MS"', filter_object_count:3, machine_common_name:"cm",
    outdoorTemperatureObjectInstance:1, windSpeedObjectInstance:2, relativeHumidityObjectInstance:3
  }')"

  # settle several poll+collect cycles, then read the real /combined (LIVE, skip retained)
  sleep $(( POLL_MS * 8 / 1000 + 4 ))
  payload=$(timeout 12 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
            -R -t "services/$rid/WeatherStation/combined" -C 1 2>/dev/null)

  if [[ "$present" == "1" ]]; then
    # all 3 sensors must carry a numeric present-value + the SCF identifier.
    # NOTE: type-only, not exact-value. The WeatherStation SCF is retargeted onto
    # each core profile's AI 1/2/3, and those inherit the simulator's default ±2%
    # drift (drift_pct 0.02), so the served values fluctuate — an exact match would
    # flake. Exact-value assertions would need a drift_pct:0 profile.
    if [[ -n "$payload" ]] && jq -e --arg id "DA_111_$cid" '
         .measuredValues as $m
         | (($m.outdoorTemperature["present-value"]|type)=="number")
         and (($m.windSpeed["present-value"]|type)=="number")
         and (($m.relativeHumidity["present-value"]|type)=="number")
         and (.identifier==$id) and ((.timestamp|type)=="number")
       ' <<<"$payload" >/dev/null 2>&1; then
      ot=$(jq -r '.measuredValues.outdoorTemperature["present-value"]' <<<"$payload")
      ws=$(jq -r '.measuredValues.windSpeed["present-value"]' <<<"$payload")
      rh=$(jq -r '.measuredValues.relativeHumidity["present-value"]' <<<"$payload")
      echo "    PASS — /combined flows: outdoorTemp=$ot windSpeed=$ws relHumidity=$rh"
      VERDICT+=("$key: FLOWS (combined ot=$ot ws=$ws rh=$rh)"); pass=$(( pass+1 ))
    else
      echo "    FAIL — expected /combined with 3 numeric sensors: ${payload:0:160}"
      VERDICT+=("$key: NO DATA (expected flow)"); fail=$(( fail+1 ))
    fi
  else
    # no analog-inputs -> combined must NOT appear (filter never reaches 3)
    if [[ -z "$payload" ]]; then
      echo "    PASS — no /combined (device has no analog-inputs), adapter stayed up"
      VERDICT+=("$key: NO /combined as expected (0 analog-inputs)"); pass=$(( pass+1 ))
    else
      echo "    FAIL — unexpected /combined from a 0-object device: ${payload:0:160}"
      VERDICT+=("$key: UNEXPECTED data"); fail=$(( fail+1 ))
    fi
  fi

  if [[ "${KEEP:-0}" == "1" && "$row" == "${PROFILES[-1]}" ]]; then
    echo "    KEEP=1 — leaving $key deployed"
  else
    del "$rid"; del "$cid"
  fi
done

echo ""
echo "CERT-SCF MATRIX (real factory SCF per device profile):"
printf '  - %s\n' "${VERDICT[@]}"
echo ""
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
