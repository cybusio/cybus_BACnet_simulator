#!/usr/bin/env bash
# 32-server scale + soak with EXACT data-integrity, via shell MQTT (curl+jq+mosquitto_sub).
# Deploys 32 device connections + 106 receives (4 real Miele concentrators + 28 synthetic
# mixed-size meters) on a running Connectware. Every analog-input is static + uniquely
# valued (40000+device_idx*1000+instance), so each receive's /combined must EXACTLY match
# its (device,instance) value. Verifies at T0, then re-verifies all 32 every 5 min for
# SOAK_MIN minutes alongside PM health (aborts / TSM exhaustion / reconnect storms / crashes
# / memory), proving integrity holds under sustained 32-device load.
#
#   e2e/scale-soak-e2e.sh           # clean -> deploy -> T0 integrity -> 30-min soak -> cleanup
#   SOAK_MIN=5 e2e/scale-soak-e2e.sh
# Prereqs: CW running; 32 sims up (gen-scale-fleet.sh + the two composes); curl jq mosquitto_sub.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
MIELE="$REPO/qa/scf/miele"
TEMPLATE="$MIELE/receive_services/receive_bacnet_TotalElectricalEnergyConsumption_DA_115_12.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"; MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"; POLL_MS="${POLL_MS:-2000}"; SOAK_MIN="${SOAK_MIN:-30}"; CAP="${CAP:-20}"
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"
declare -A PORT=( [2098177]=47870 [2098183]=47871 [2098184]=47872 [2098185]=47873 )

for c in curl jq mosquitto_sub base64 docker; do command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }; done
MAP="$("$REPO/qa/gen/gen-scale-fleet.sh")"
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
synport() { echo $(( 47880 + $1 - 3000000 )); }

deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }

deploy_fleet() {
  echo "==> deploy 32 connections"
  echo "$MAP" | tail -n +2 | awk -F'\t' '{print $2"\t"$8}' | sort -u | while IFS=$'\t' read -r dev kind; do
    if [[ "$kind" == real ]]; then port=${PORT[$dev]}; else port=$(synport "$dev"); fi
    deploy "conn_$dev" "$MIELE/connection_bacnet.yaml" \
      "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$port,\"device_instance\":$dev,\"machine_common_name\":\"d$dev\"}"
  done
  sleep 10
  echo "==> deploy 106 receives (36 real + 70 synthetic)"
  echo "$MAP" | tail -n +2 | while IFS=$'\t' read -r da dev energy power id ev pv kind; do
    if [[ "$kind" == real ]]; then
      deploy "recv_$da" "$MIELE/receive_services/receive_bacnet_TotalElectricalEnergyConsumption_DA_115_$da.yaml" \
        "{\"bacnet_connection_service_id\":\"conn_$dev\",\"machine_common_name\":\"m_$da\",\"PollInterval\":$POLL_MS}"
    else
      deploy "recv_$da" "$TEMPLATE" \
        "{\"bacnet_connection_service_id\":\"conn_$dev\",\"machine_common_name\":\"m_$da\",\"PollInterval\":$POLL_MS,\"SumRealEnergy\":$energy,\"SumRealPower\":$power,\"SumRealPowerState\":\"enabled\",\"identifier_param\":\"$id\"}"
    fi
  done
}

# Bulk-capture all /combined for $CAP s, exact-assert every receive. Prints "pass total".
integrity_pass() {
  local cap; cap=$(timeout "$CAP" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t 'services/+/+/combined' -F '%t %p' 2>/dev/null || true)
  local pass=0 total=0 da dev energy power id ev pv kind line payload pvarg
  while IFS=$'\t' read -r da dev energy power id ev pv kind; do
    total=$(( total + 1 ))
    line=$(grep "^services/recv_$da/[^ ]*/combined " <<<"$cap" | tail -1); payload="${line#* }"
    pvarg=null; [[ "$pv" != "-" ]] && pvarg="$pv"
    if [[ -n "$payload" ]] && jq -e --argjson ev "$ev" --argjson pv "$pvarg" '
        .sumRealEnergy as $e | .sumRealPower as $p |
        ((($e.value-$ev)|fabs)<0.01) and ($e.unit=="kW·h")
        and (if $pv==null then ($p.value==0 and $p.unit=="NULL") else ((($p.value-$pv)|fabs)<0.01 and $p.unit=="kW") end)
      ' <<<"$payload" >/dev/null 2>&1; then pass=$(( pass + 1 )); fi
  done < <(echo "$MAP" | tail -n +2)
  echo "$pass $total"
}

pm_health() { # since <secs> -> "abort tsm storm crash"
  local log; log=$(docker logs --since "${1}s" "$PM" 2>&1)
  echo "$(grep -ciE 'Buffer Overflow' <<<"$log") $(grep -ciE 'max concurrency|encode failed' <<<"$log") $(grep -ciE 'reconnect|connectlost' <<<"$log") $(grep -ciE 'unhandledrejection|uncaught|fatal' <<<"$log")"
}
pm_mem() { docker stats --no-stream --format '{{.MemUsage}}' "$PM" 2>/dev/null | awk '{print $1}'; }
pm_mem_n() { pm_mem | awk '{m=$1; if(m ~ /GiB/){gsub(/GiB/,"",m); print m*1024} else {gsub(/MiB/,"",m); print m+0}}'; }

cleanup() {
  [[ -n "${_CLEANED:-}" ]] && return; _CLEANED=1   # idempotent: trap + explicit call must not overlap
  echo "$MAP" | tail -n +2 | awk -F'\t' '{print "recv_"$1; print "conn_"$2}' | sort -u | while read -r id; do
    auth -X PUT "$API/services/$id/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1
  done
}

trap cleanup EXIT INT TERM
echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
deploy_fleet
echo "==> settle, T0 exact-integrity over all 32 devices / 106 receives"
sleep $(( POLL_MS * 6 / 1000 ))
read -r p t <<<"$(integrity_pass)"
echo "T0 INTEGRITY: $p/$t receives exact-match"
if [[ "$p" != "$t" ]]; then echo "T0 not clean — aborting soak"; cleanup; exit 1; fi

MEM0=$(pm_mem_n)
echo "==> SOAK ${SOAK_MIN} min — re-verify all $t every 5 min + PM health (mem now: ${MEM0} MiB)"
# Round UP so any SOAK_MIN>0 runs at least one checkpoint — a 30-min soak must
# never silently collapse to a single T0 sample and still print PASS.
checks=$(( (SOAK_MIN + 4) / 5 ))
if [[ "$SOAK_MIN" -gt 0 && "$checks" -lt 1 ]]; then echo "RESULT: FAIL (SOAK_MIN=$SOAK_MIN yields 0 checkpoints)"; exit 1; fi
fail=0; MEM_BASE=""; MEM_LAST=""
for k in $(seq 1 "$checks"); do
  sleep 300
  read -r p t <<<"$(integrity_pass)"
  read -r ab tsm st cr <<<"$(pm_health 320)"
  mem=$(pm_mem); memn=$(awk -v m="$mem" 'BEGIN{if(m~/GiB/){sub(/GiB/,"",m);print m*1024}else if(m~/MiB/){sub(/MiB/,"",m);print m+0}else{print ""}}')
  [[ -n "$memn" ]] && { [[ -z "$MEM_BASE" ]] && MEM_BASE=$memn; MEM_LAST=$memn; }   # baseline = first VALID checkpoint (post warm-up); empty = a stats hiccup, skipped
  ok="OK"; { [[ "$p" != "$t" ]] || [[ "$tsm" -gt 0 ]] || [[ "$cr" -gt 0 ]]; } && { ok="DEGRADED"; fail=1; }
  echo "  [+$(( k * 5 ))m] integrity $p/$t | abort $ab tsm $tsm storm $st crash $cr | mem $mem | $ok"
done

MEMF=$(pm_mem_n)
echo "==> SOAK DONE — final integrity: $(integrity_pass | awk '{print $1"/"$2}'), mem ${MEMF} MiB"
# Leak check — the integrity gate above is memory-blind. Measure STEADY-STATE growth from the
# first checkpoint (after the one-time deploy warm-up) to the last, so the ramp isn't counted
# as a leak. Judge only when the steady window is real (>=15 min); shorter runs are informational.
MEM_WARN_RATE=${MEM_WARN_RATE:-15}; MEM_FAIL_RATE=${MEM_FAIL_RATE:-50}   # MiB/hour (50/h ~ 1.2 GiB/day)
win=$(( (checks - 1) * 5 ))   # minutes spanned between the first and last checkpoint
if [[ "$win" -ge 15 && "$MEM_BASE" =~ ^[0-9.]+$ && "$MEM_LAST" =~ ^[0-9.]+$ ]]; then
  rate=$(awk "BEGIN{printf \"%.1f\", ($MEM_LAST-$MEM_BASE)/($win/60)}")
  echo "==> MEM TREND (steady-state, post-ramp): ${MEM_BASE} -> ${MEM_LAST} MiB over ${win}m = ${rate} MiB/hour (warn>${MEM_WARN_RATE}, fail>${MEM_FAIL_RATE})"
  awk "BEGIN{exit !($rate > $MEM_FAIL_RATE)}" && { echo "MEM LEAK: ${rate} MiB/hour exceeds ${MEM_FAIL_RATE}"; fail=1; }
  awk "BEGIN{exit !($rate > $MEM_WARN_RATE && $rate <= $MEM_FAIL_RATE)}" && echo "MEM WARN: ${rate} MiB/hour — confirm it plateaus over a longer soak before sign-off"
else
  echo "==> MEM TREND: T0 ${MEM0} -> final ${MEMF} MiB (${checks} checkpoint(s); window too short for a steady-state rate — informational, not gated)"
fi
echo "==> cleanup"; cleanup
[[ "$fail" -eq 0 ]] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
