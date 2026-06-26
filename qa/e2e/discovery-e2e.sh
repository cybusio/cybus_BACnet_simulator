#!/usr/bin/env bash
# FACTORY capability-discovery + large-array e2e — proven on a RUNNING Connectware
# via real MQTT. Promotes the qa-simulator capability bits + mega-scale large-array
# recovery to the factory path.
#   modern → max-apdu-length-accepted=1476, segmentation-supported=segmented-both
#   legacy → max-apdu-length-accepted=206,  segmentation-supported=no-segmentation
#   mega-b → 20001-object object-list RECOVERED (chunked) and delivered COMPLETE on
#            MQTT (~100 KB payload) — extreme array recovery through the data plane.
# Adversarial, exact.
#   e2e/discovery-e2e.sh
# Prereqs: CW running; modern + legacy + mega-b sims up; curl jq mosquitto_sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/lifecycle/connection_hc.yaml"; RECV="$REPO/qa/scf/discovery/discovery_recv.yaml"
CW_HOST="${CW_HOST:-localhost}"; MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"; SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"; API="https://${CW_HOST}/api"
MODERN_DEV=400001; LEGACY_DEV=300001; MEGA_DEV=2000201; CAP="${CAP:-35}"

for c in curl jq mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c missing" >&2; exit 1; }; done
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }

echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
echo "==> deploy modern + legacy + mega-b discovery receives"
deploy conn_modern "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":47811,\"device_instance\":$MODERN_DEV,\"machine_common_name\":\"modern\"}"
deploy conn_legacy "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":47810,\"device_instance\":$LEGACY_DEV,\"machine_common_name\":\"legacy\"}"
deploy conn_mega   "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":47862,\"device_instance\":$MEGA_DEV,\"machine_common_name\":\"mega\"}"
sleep 8
deploy recv_modern "$RECV" "{\"bacnet_connection_service_id\":\"conn_modern\",\"machine_common_name\":\"modern\",\"device_instance\":$MODERN_DEV,\"interval\":3000}"
deploy recv_legacy "$RECV" "{\"bacnet_connection_service_id\":\"conn_legacy\",\"machine_common_name\":\"legacy\",\"device_instance\":$LEGACY_DEV,\"interval\":3000}"
deploy recv_mega   "$RECV" "{\"bacnet_connection_service_id\":\"conn_mega\",\"machine_common_name\":\"mega\",\"device_instance\":$MEGA_DEV,\"interval\":10000}"

echo "==> capture ${CAP}s (allow the 20k object-list chunked recovery to complete + publish)"
sleep 6
mkdir -p "$REPO/.run"; CAPF="$REPO/.run/disc-cap.$$"
timeout "$CAP" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t 'services/+/disc/+' -F '%t %p' >"$CAPF" 2>/dev/null || true
LOG=$(docker logs --since "$(( CAP + 25 ))s" "$PM" 2>&1)
val() { grep "^services/$1/disc/$2 " "$CAPF" | tail -1 | cut -d' ' -f2- | jq -r "$3" 2>/dev/null; }

MAPDU_M=$(val recv_modern maxapdu '.value'); SEG_M=$(val recv_modern seg '.value')
MAPDU_L=$(val recv_legacy maxapdu '.value'); SEG_L=$(val recv_legacy seg '.value')
OBJLEN=$(val recv_mega objlist '.value | length')
OBJUNIQ=$(val recv_mega objlist '.value | unique | length')
OBJWF=$(val recv_mega objlist '[.value[] | select(.objectTypeName != null and .objectInstance != null)] | length')
echo "  modern: max-apdu=$MAPDU_M seg=$SEG_M | legacy: max-apdu=$MAPDU_L seg=$SEG_L | mega-b object-list len=$OBJLEN unique=$OBJUNIQ well-formed=$OBJWF"

check "modern max-apdu-length-accepted == 1476 on MQTT"            '[[ "$MAPDU_M" == "1476" ]]' "got $MAPDU_M"
check "modern segmentation-supported == segmented-both on MQTT"    '[[ "$SEG_M" == "segmented-both" ]]' "got $SEG_M"
check "legacy max-apdu-length-accepted == 206 on MQTT"             '[[ "$MAPDU_L" == "206" ]]' "got $MAPDU_L"
check "legacy segmentation-supported == no-segmentation on MQTT"   '[[ "$SEG_L" == "no-segmentation" ]]' "got $SEG_L"
# Strict integrity, not just length: at least the 20001 generated objects, and the
# array must be exactly as long as it is UNIQUE (no chunk overlap/dup) and WELL-FORMED
# (every element a typed object-id). A duplicated or garbage array of the right length
# fails here where a length-only check would pass. (Total is 20001 generated + base
# objects, so the floor is >=20001, not an exact count.)
check "mega-b object-list (>=20001) COMPLETE + UNIQUE + well-formed on MQTT" \
  '[[ "$OBJLEN" -ge 20001 && "$OBJUNIQ" == "$OBJLEN" && "$OBJWF" == "$OBJLEN" ]]' \
  "got len=$OBJLEN unique=$OBJUNIQ well-formed=$OBJWF"
check "no crash during the large-array recovery (0 unhandledRejection/uncaught/fatal)" \
  "[[ \$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<\"\$LOG\") -eq 0 ]]" "crash markers seen"

rm -f "$CAPF"
echo "==> cleanup"
for id in recv_modern recv_legacy recv_mega conn_modern conn_legacy conn_mega; do
  auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
  auth -X DELETE "$API/services/$id" >/dev/null 2>&1
done
echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
