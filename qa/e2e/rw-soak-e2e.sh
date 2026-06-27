#!/usr/bin/env bash
# 32-device read/WRITE data-integrity soak via shell MQTT (curl+jq+mosquitto pub/sub).
# Deploys 32 BACnet connections + 32 R/W receives, each exposing a writable
# AnalogValue(REAL), MultiStateValue(UINT) and BinaryValue(BOOL). Every round writes
# FRESH RANDOM values (within each datatype's limits) to all 96 writable points in
# parallel, waits a poll cycle, reads every point back and asserts an EXACT round-trip.
# PM health (write errors / aborts / TSM exhaustion / reconnect storms / crashes / memory)
# is sampled every round, proving R/W integrity and adapter efficiency under sustained
# parallel load.
#
#   e2e/rw-soak-e2e.sh                       # deploy -> T0 validate -> 30-min soak -> cleanup
#   SOAK_MIN=2 ROUND_S=15 e2e/rw-soak-e2e.sh # quick smoke
# Prereqs: CW running; 32 R/W sims up (gen-rw-fleet.sh + rw-fleet.compose.yaml up); curl jq mosquitto_pub/sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
CONN="$REPO/qa/scf/miele/connection_bacnet.yaml"
RECV="$REPO/qa/scf/rw/rw_recv.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"; MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; POLL_MS="${POLL_MS:-2000}"
SOAK_MIN="${SOAK_MIN:-30}"; ROUND_S="${ROUND_S:-20}"; CAP="${CAP:-6}"
N="${N:-32}"; BASE_DEV=4000000; BASE_PORT=47950
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"

for c in curl jq mosquitto_pub mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }; done
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
mqp() { mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" "$@"; }

devs() { local i; for i in $(seq 0 $(( N - 1 ))); do echo $(( BASE_DEV + i )); done; }

deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }

deploy_fleet() {
  echo "==> deploy $N connections"; local i=0 dev
  for dev in $(devs); do
    deploy "conn_rw_$dev" "$CONN" \
      "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$(( BASE_PORT + i )),\"device_instance\":$dev,\"machine_common_name\":\"rw$dev\"}"
    i=$(( i + 1 ))
  done
  sleep 10
  echo "==> deploy $N R/W receives"
  for dev in $(devs); do
    deploy "recv_rw_$dev" "$RECV" \
      "{\"bacnet_connection_service_id\":\"conn_rw_$dev\",\"machine_common_name\":\"rw$dev\",\"interval\":$POLL_MS}"
  done
}

# Fire fresh random writes to all 3 writable points on every device, in parallel.
# Echoes the expected table "dev av mv bvexpect" on stdout for the verifier.
# Reads the PREVIOUS round's table on stdin (empty on round 1) and redraws so each
# value DIFFERS from last round — a STUCK write then can't coincidentally pass on the
# low-cardinality points (mv 1..4 ~25%, bv 0/1 ~50%); av collision is negligible.
write_round() {
  local dev av mv bv pav pmv pbv
  local -A PAV PMV PBV
  while read -r dev pav pmv pbv; do
    [[ -z "$dev" ]] && continue
    PAV[$dev]=$pav; PMV[$dev]=$pmv; PBV[$dev]=$([[ "$pbv" == active ]] && echo 1 || echo 0)
  done
  for dev in $(devs); do
    av=$(( (RANDOM << 8 | RANDOM) % 60000 + 1000 ))   # integer REAL, float32-exact (<2^24)
    while [[ "$av" == "${PAV[$dev]:-}" ]]; do av=$(( (RANDOM << 8 | RANDOM) % 60000 + 1000 )); done
    mv=$(( RANDOM % 4 + 1 ))                           # MultiStateValue present-value 1..4
    while [[ "$mv" == "${PMV[$dev]:-}" ]]; do mv=$(( RANDOM % 4 + 1 )); done
    if [[ -n "${PBV[$dev]:-}" ]]; then bv=$(( 1 - PBV[$dev] )); else bv=$(( RANDOM % 2 )); fi
    mqp -t "services/recv_rw_$dev/rw/av0w/set" -m "$av" &
    mqp -t "services/recv_rw_$dev/rw/mv0w/set" -m "$mv" &
    mqp -t "services/recv_rw_$dev/rw/bv0w/set" -m "$bv" &
    echo "$dev $av $mv $([[ $bv -eq 1 ]] && echo active || echo inactive)"
  done
  wait
}

# Read expected table from stdin, bulk-capture readbacks, assert each device's
# av0/mv0/bv0 EXACTLY match the last write. Prints "pass total [firstmismatch]".
verify_round() {
  local exp cap pass=0 total=0 dev av mv bvx avv mvv bvv miss=""
  exp="$(cat)"
  cap=$(timeout "$CAP" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t 'services/+/rw/+' -F '%t %p' 2>/dev/null || true)
  while read -r dev av mv bvx; do
    [[ -z "$dev" ]] && continue
    total=$(( total + 1 ))
    avv=$(jq -r '.value' <<<"$(grep "^services/recv_rw_$dev/rw/av0 " <<<"$cap" | tail -1 | cut -d' ' -f2-)" 2>/dev/null)
    mvv=$(jq -r '.value' <<<"$(grep "^services/recv_rw_$dev/rw/mv0 " <<<"$cap" | tail -1 | cut -d' ' -f2-)" 2>/dev/null)
    bvv=$(jq -r '.value' <<<"$(grep "^services/recv_rw_$dev/rw/bv0 " <<<"$cap" | tail -1 | cut -d' ' -f2-)" 2>/dev/null)
    if [[ "$avv" == "$av" && "$mvv" == "$mv" && "$bvv" == "$bvx" ]]; then pass=$(( pass + 1 ))
    elif [[ -z "$miss" ]]; then miss="$dev av:$av/$avv mv:$mv/$mvv bv:$bvx/$bvv"; fi
  done <<<"$exp"
  echo "$pass $total${miss:+ | first-miss $miss}"
}

pm_health() { # since <secs> -> "wrerr abort tsm storm crash"
  local log; log=$(docker logs --since "${1}s" "$PM" 2>&1)
  echo "$(grep -ciE 'write.?property.*(error|fail|reject)|reject.*writ|write failed' <<<"$log") \
$(grep -ciE 'Buffer Overflow' <<<"$log") $(grep -ciE 'max concurrency|encode failed' <<<"$log") \
$(grep -ciE 'reconnect|connectlost' <<<"$log") $(grep -ciE 'unhandledrejection|uncaught|fatal' <<<"$log")" | tr -s ' '
}
pm_mem() { docker stats --no-stream --format '{{.MemUsage}}' "$PM" 2>/dev/null | awk '{print $1}'; }
pm_mem_n() { pm_mem | awk '{m=$1; if(m ~ /GiB/){gsub(/GiB/,"",m); print m*1024} else {gsub(/MiB/,"",m); print m+0}}'; }

cleanup() {
  for dev in $(devs); do
    auth -X PUT "$API/services/recv_rw_$dev/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/recv_rw_$dev" >/dev/null 2>&1
    auth -X PUT "$API/services/conn_rw_$dev/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/conn_rw_$dev" >/dev/null 2>&1
  done
}

trap cleanup EXIT INT TERM
echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
deploy_fleet
echo "==> settle, T0 round-trip across all $N devices ($(( N * 3 )) writable points)"
sleep $(( POLL_MS * 6 / 1000 ))
exp="$(write_round </dev/null)"; sleep $(( POLL_MS / 1000 + 2 ))
read -r p t rest <<<"$(verify_round <<<"$exp")"
echo "T0 R/W INTEGRITY: $p/$t exact round-trip ${rest:-}"
if [[ "$p" != "$t" ]]; then echo "T0 not clean — aborting soak"; cleanup; exit 1; fi

[[ "$SOAK_MIN" -gt 0 ]] || { echo "RESULT: FAIL (SOAK_MIN=$SOAK_MIN — a soak must run at least one round)"; exit 1; }
MEM0=$(pm_mem_n)
echo "==> SOAK ${SOAK_MIN} min, fresh random R/W every ~${ROUND_S}s (mem now: ${MEM0} MiB)"
fail=0 round=0 deadline=$(( SECONDS + SOAK_MIN * 60 )); soak_start=$SECONDS; MEM_BASE=""; BASE_T=0; MEM_LAST=""; LAST_T=0
while (( SECONDS < deadline )); do
  round=$(( round + 1 )); t0=$SECONDS
  prev_exp="$exp"; exp="$(write_round <<<"$prev_exp")"; sleep $(( POLL_MS / 1000 + 2 ))
  read -r p t rest <<<"$(verify_round <<<"$exp")"
  read -r we ab tsm st cr <<<"$(pm_health $(( SECONDS - t0 + 4 )))"
  el=$(( SECONDS - t0 )); mem=$(pm_mem)
  memn=$(awk -v m="$mem" 'BEGIN{if(m~/GiB/){sub(/GiB/,"",m);print m*1024}else if(m~/MiB/){sub(/MiB/,"",m);print m+0}else{print ""}}')
  if [ -n "$memn" ]; then   # empty = a docker-stats hiccup, skip the sample
    [[ -z "$MEM_BASE" && $(( SECONDS - soak_start )) -ge 300 ]] && { MEM_BASE=$memn; BASE_T=$SECONDS; }
    MEM_LAST=$memn; LAST_T=$SECONDS
  fi
  ok="OK"; { [[ "$p" != "$t" ]] || [[ "$tsm" -gt 0 ]] || [[ "$cr" -gt 0 ]] || [[ "$we" -gt 0 ]]; } && { ok="DEGRADED"; fail=1; }
  printf '  [r%03d +%dm] rw %s/%s | wrerr %s abort %s tsm %s storm %s crash %s | %ds mem %s | %s%s\n' \
    "$round" "$(( (deadline - SECONDS) >= 0 ? (SOAK_MIN - (deadline - SECONDS + 59)/60) : SOAK_MIN ))" \
    "$p" "$t" "$we" "$ab" "$tsm" "$st" "$cr" "$el" "$mem" "$ok" "${rest:+ ${rest}}"
  (( SECONDS - t0 < ROUND_S )) && sleep $(( ROUND_S - (SECONDS - t0) ))
done

MEMF=$(pm_mem_n)
echo "==> SOAK DONE — $round rounds, $(( round * N * 3 )) write+read verifications, final mem ${MEMF} MiB"
# Leak check — the round gate above is memory-blind. Measure STEADY-STATE growth from the
# first post-warm-up sample (>=5 min in) to the last, so the one-time deploy ramp isn't counted.
MEM_WARN_RATE=${MEM_WARN_RATE:-15}; MEM_FAIL_RATE=${MEM_FAIL_RATE:-50}   # MiB/hour (50/h ~ 1.2 GiB/day)
win=$(( (LAST_T - BASE_T) / 60 ))
if [[ "$win" -ge 10 && "$MEM_BASE" =~ ^[0-9.]+$ && "$MEM_LAST" =~ ^[0-9.]+$ ]]; then
  rate=$(awk "BEGIN{printf \"%.1f\", ($MEM_LAST-$MEM_BASE)/($win/60)}")
  echo "==> MEM TREND (steady-state, post-ramp): ${MEM_BASE} -> ${MEM_LAST} MiB over ${win}m = ${rate} MiB/hour (warn>${MEM_WARN_RATE}, fail>${MEM_FAIL_RATE})"
  awk "BEGIN{exit !($rate > $MEM_FAIL_RATE)}" && { echo "MEM LEAK: ${rate} MiB/hour exceeds ${MEM_FAIL_RATE}"; fail=1; }
  awk "BEGIN{exit !($rate > $MEM_WARN_RATE && $rate <= $MEM_FAIL_RATE)}" && echo "MEM WARN: ${rate} MiB/hour — confirm it plateaus over a longer soak before sign-off"
else
  echo "==> MEM TREND: T0 ${MEM0} -> final ${MEMF} MiB (no >=10-min post-warm-up window; informational, not gated)"
fi
echo "==> cleanup"; cleanup
# A PASS with zero rounds is not a soak — require at least one verified round.
if [[ "$fail" -eq 0 && "$round" -ge 1 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL (round=$round)"; exit 1; fi
