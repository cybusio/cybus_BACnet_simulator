#!/usr/bin/env bash
# FACTORY cadence/jitter e2e — proven on a RUNNING Connectware via real MQTT.
# Promotes the in-process cadence suite to the factory path.
#   8 endpoints on ONE connection, same interval. Adversarial claims:
#   (1) JITTER: their first MQTT messages spread across [0, interval) — they do
#       NOT all burst at t=0 (anti-burst for the shared TSM pool).
#   (2) STEADY CADENCE: each endpoint then publishes ~once/interval, no drift.
#   (3) NO TIMER LEAK: PM RSS stays flat across the window.
#   e2e/cadence-e2e.sh
# Prereqs: CW running; modern sim up; curl jq mosquitto_sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/lifecycle/connection_hc.yaml"; RECV="$REPO/qa/scf/cadence/cad_recv.yaml"
CW_HOST="${CW_HOST:-localhost}"; MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"; SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"; API="https://${CW_HOST}/api"
PORT=47811; DEV=400001; INTERVAL="${INTERVAL:-4000}"; WIN="${WIN:-32}"

for c in curl jq mosquitto_sub base64 docker awk; do command -v "$c" >/dev/null || { echo "ERROR: $c missing" >&2; exit 1; }; done
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
# RSS in MiB, unit-aware: docker reports e.g. "1.5GiB / 2GiB" or "512MiB / 2GiB".
# A bare $1+0 would read 1.5GiB as 1.5 and miss a GiB-scale leak, so normalize.
pmmem() {
  docker stats --no-stream --format '{{.MemUsage}}' "$PM" 2>/dev/null \
    | awk '{ v=$1+0; if ($1 ~ /GiB/) v*=1024; else if ($1 ~ /KiB/) v/=1024; print v }'
}
PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }
# Trap so a mid-run failure or Ctrl-C never leaks the deployed services on CW.
cleanup() { local id; for id in recv_cad conn_cad; do
    auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1; done; rm -f "${CAPF:-}" 2>/dev/null; }
trap cleanup EXIT INT TERM

echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
echo "==> deploy connection, settle, then start capture BEFORE the 8 endpoints subscribe"
deploy conn_cad "$CONN" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$PORT,\"device_instance\":$DEV,\"machine_common_name\":\"cad\"}"
sleep 7
MEM0=$(pmmem)
mkdir -p "$REPO/.run"; CAPF="$REPO/.run/cad-cap.$$"
timeout "$WIN" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -R -t 'services/recv_cad/cad/+' -F '%U %t' >"$CAPF" 2>/dev/null &
CAPPID=$!
sleep 1
deploy recv_cad "$RECV" "{\"bacnet_connection_service_id\":\"conn_cad\",\"machine_common_name\":\"cad\",\"device_instance\":$DEV,\"interval\":$INTERVAL}"
wait "$CAPPID" || true
CAP=$(cat "$CAPF"); rm -f "$CAPF"
MEM1=$(pmmem)

# First-arrival per topic → spread (jitter); per-topic counts → steady cadence.
FIRSTS=""; MINCOUNT=9999; NTOPICS=0
for e in $(seq 0 7); do
  lines=$(grep -E " services/recv_cad/cad/e$e\$" <<<"$CAP" || true)
  [[ -z "$lines" ]] && continue
  NTOPICS=$(( NTOPICS + 1 ))
  first=$(awk '{print $1}' <<<"$lines" | sort -n | head -1)
  cnt=$(grep -c . <<<"$lines")
  FIRSTS="$FIRSTS $first"
  [[ "$cnt" -lt "$MINCOUNT" ]] && MINCOUNT=$cnt
done
FMIN=$(tr ' ' '\n' <<<"$FIRSTS" | grep . | sort -n | head -1)
FMAX=$(tr ' ' '\n' <<<"$FIRSTS" | grep . | sort -n | tail -1)
SPREAD=$(awk "BEGIN{printf \"%.2f\", $FMAX - $FMIN}")
EXP=$(( WIN / (INTERVAL / 1000) ))   # ~ msgs/topic over the window
echo "  topics=$NTOPICS/8  first-poll spread=${SPREAD}s (interval $(awk "BEGIN{print $INTERVAL/1000}")s)  min msgs/topic=$MINCOUNT (~${EXP} expected)  mem ${MEM0}->${MEM1} MiB"

check "all 8 endpoints poll (each topic publishes)" '[[ "$NTOPICS" -eq 8 ]]' "only $NTOPICS topics published"
check "first polls JITTER-spread across >=30% of the interval (no t=0 burst)" \
  "awk \"BEGIN{exit !($SPREAD >= $INTERVAL/1000*0.3)}\"" "spread ${SPREAD}s too tight (burst)"
check "steady cadence holds — every topic keeps ~1 msg/interval (>= EXP-2)" \
  '[[ "$MINCOUNT" -ge $(( EXP - 2 )) ]]' "min msgs/topic=$MINCOUNT < $(( EXP - 2 ))"
check "no timer leak — PM RSS flat across the window (<25 MiB growth)" \
  "awk \"BEGIN{exit !($MEM1 - $MEM0 < 25)}\"" "mem grew ${MEM0}->${MEM1} MiB"

echo "==> cleanup"; cleanup
echo "==> RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
