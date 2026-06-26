#!/usr/bin/env bash
# =============================================================================
# ws-integrity-soak.sh — deploy the REAL regression SCF
# (system-test-fixtures/.../_bacnet_miele_missing_rainCurrent/
#  receive_bacnet_WeatherStation.yaml) AS-IS against each WeatherStation sim
# variant, PROVE per-point data integrity over MQTT while watching the
# protocol-mapper, then hammer it in a fail-fast soak to surface production bugs.
#
# SCF = 17 weather points x {object-name, present-value, units} = 51 cov-deduped
# endpoints -> per-point collect topic
#   services/<recv>/WeatherStation/collect/<CamelPoint> = {object-name,present-value,unit}
# Integrity oracle = the sim profile: each point's instance, name, unit, value.
# object-name is read from the SAME instance as present-value, so a wrong name on
# a topic = cross-instance bleed. We subscribe BEFORE deploy to catch every cov
# first-publish, and assemble each point's latest non-null fields from the stream
# (immune to a partial collect record while a slow device's 3 reads are landing).
#
# Accounting (per the constrained-device reality):
#   IPASS   correct data (name+value+unit) OR rainCurrent gracefully absent
#   IWRONG  reported but wrong name/value/unit, or rainCurrent present when absent  -> BUG
#   IMISS   no data this window (device saturated) -> tolerated under hammer
#   deadline 'Read aborted (client deadline)' = healthy load-shedding (counted, not a fail)
#   storm/tsm/crash = reconnect storm / adapter TSM exhaustion / crash -> BUG
#
# Variants:  full (all 17 present) · norain (rainCurrent@3 ABSENT = the regression)
#            · overloaded (norain + abort-8 + delay = constrained device)
# Modes:
#   verify <variant> | verify-all     integrity proof per variant
#   soak <variant> <min>              fast hammer, continuous integrity, FAIL-FAST
#   cleanup
# Sims up via weatherstation.compose.yaml + ws-overload.compose.yaml. LOCAL only.
# Env: CW_* MQTT_* SIM_HOST PM · SAMPLING_MS(verify 1000 / soak 500) · VAL_TOL_PCT(0.06) VAL_TOL_ABS(0.6)
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
RUN="$REPO/.run"
CONN_SCF="$REPO/scf/miele/connection_bacnet.yaml"
RECV_SCF="/home/dj/protocols/system-test-fixtures/regression-tests/_bacnet_miele_missing_rainCurrent/receive_bacnet_WeatherStation.yaml"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"
VAL_TOL_PCT="${VAL_TOL_PCT:-0.06}"; VAL_TOL_ABS="${VAL_TOL_ABS:-0.6}"
CONN_ID="wsint_conn"; RECV_ID="wsint_recv"

read -r -d '' ORACLE <<'TSV' || true
outdoorTemperature	0	18.5	degrees-celsius	OutdoorTemperature
windSpeed	1	4.2	no-units	WindSpeed
relativeHumidity	2	65.0	no-units	RelativeHumidity
rainCurrent	3	0.0	no-units	RainCurrent
rainLast24h	4	12.3	no-units	RainLast24h
brightnessEast	5	8500.0	no-units	BrightnessEast
brightnessNorth	6	3200.0	no-units	BrightnessNorth
brightnessSouth	7	12000.0	no-units	BrightnessSouth
brightnessWest	8	9100.0	no-units	BrightnessWest
forecastDay1Max	9	22.0	degrees-celsius	ForecastDay1Max
forecastDay1Min	10	11.0	degrees-celsius	ForecastDay1Min
forecastDay2Max	11	24.0	degrees-celsius	ForecastDay2Max
forecastDay2Min	12	12.0	degrees-celsius	ForecastDay2Min
forecastDay3Max	13	21.0	degrees-celsius	ForecastDay3Max
forecastDay3Min	14	10.0	degrees-celsius	ForecastDay3Min
sunAzimuthAngle	15	180.0	no-units	SunAzimuthAngle
sunElevationAngle	16	45.0	no-units	SunElevationAngle
TSV

variant_cfg() {
  case "$1" in
    full)       echo "47866 2000300 yes" ;;
    norain)     echo "47867 2000301 no" ;;
    overloaded) echo "47868 2000302 no" ;;
    *) echo ""; return 1 ;;
  esac
}

for c in curl jq mosquitto_sub base64 docker awk; do
  command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done
[[ -f "$RECV_SCF" ]] || { echo "ERROR: regression SCF not found: $RECV_SCF" >&2; exit 1; }
mkdir -p "$RUN"

login() { TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
  [[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed at $API" >&2; exit 1; }; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"commissioningFile\":\"$(base64 -w0 < "$2")\",\"parameters\":$3}" >/dev/null
  auth -X PUT "$API/services/$1/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null; }
svc_state() { auth "$API/v2/services?pageSize=500" | jq -r --arg id "$1" '[.data[]|select(.serviceId==$id)][0].currentState // "absent"'; }
wait_enabled() { local id="$1" t="${2:-40}"; for _ in $(seq 1 "$t"); do [[ "$(svc_state "$id")" == enabled ]] && return 0; sleep 1; done; return 1; }
remove() { local id; for id in "$RECV_ID" "$CONN_ID"; do
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' -d '{"operation":"disable"}' >/dev/null 2>&1 || true
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1 || true; done
  for _ in $(seq 1 30); do
    [[ "$(auth -o /dev/null -w '%{http_code}' "$API/services/$RECV_ID")" == 404 \
       && "$(auth -o /dev/null -w '%{http_code}' "$API/services/$CONN_ID")" == 404 ]] && return; sleep 1; done; }

recv_params() { local json p inst rest; json="{\"bacnet_connection_service_id\":\"$CONN_ID\",\"machine_common_name\":\"DA_111_WS1\",\"identifier_param\":\"DA_111_WS1\",\"sampling_interval\":$1"
  while IFS=$'\t' read -r p inst rest; do [[ -z "$p" ]] && continue; json="$json,\"${p}ObjectInstance\":$inst"; done <<<"$ORACLE"
  printf '%s}' "$json"; }

deploy_variant() { local cfg port dev rain; cfg=$(variant_cfg "$1") || { echo "bad variant $1" >&2; return 1; }
  read -r port dev rain <<<"$cfg"; remove
  # Retry the connection enable: absorbs post-restart SM/PM readiness and any
  # connect-after-disconnect delay. Attempts/time-to-enable is an A/B signal.
  local attempt ok=0 secs i
  for attempt in 1 2 3 4 5; do
    deploy "$CONN_ID" "$CONN_SCF" "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$port,\"device_instance\":$dev,\"machine_common_name\":\"$1\"}"
    secs=0
    for i in $(seq 1 50); do [[ "$(svc_state "$CONN_ID")" == enabled ]] && { ok=1; secs=$i; break; }; sleep 1; done
    [[ "$ok" -eq 1 ]] && { echo "  connection enabled (attempt $attempt, ~${secs}s)"; break; }
    echo "  [.] connection not enabled in 50s (attempt $attempt) — retry"; remove; sleep 8
  done
  [[ "$ok" -eq 1 ]] || { echo "  [!] connection did not enable after $attempt attempts"; return 1; }
  deploy "$RECV_ID" "$RECV_SCF" "$(recv_params "$2")"
  wait_enabled "$RECV_ID" 40 || { echo "  [!] receive did not enable"; return 1; }; }

in_band() { awk -v a="$1" -v e="$2" -v p="$VAL_TOL_PCT" -v f="$VAL_TOL_ABS" \
  'BEGIN{ t=e*p; if(t<0)t=-t; if(t<f)t=f; d=a-e; if(d<0)d=-d; exit !(d<=t) }'; }

# assert_integrity <capfile> <rainPresent> -> sets IPASS IWRONG IMISS; prints per-point lines
assert_integrity() {
  local cap="$1" rain="$2" p inst ev eu camel; IPASS=0; IWRONG=0; IMISS=0
  while IFS=$'\t' read -r p inst ev eu camel; do [[ -z "$p" ]] && continue
    local aname="" aval="" aunit="" line n v u nmsgs=0
    while IFS= read -r line; do [[ -z "$line" ]] && continue; nmsgs=$((nmsgs+1))
      n=$(jq -r '."object-name" // empty' <<<"$line" 2>/dev/null); [[ -n "$n" ]] && aname="$n"
      v=$(jq -r '."present-value" // empty' <<<"$line" 2>/dev/null); [[ -n "$v" ]] && aval="$v"
      u=$(jq -r '.unit // empty' <<<"$line" 2>/dev/null); [[ -n "$u" ]] && aunit="$u"
    done < <(grep -F "WeatherStation/collect/$camel " "$cap" | sed "s#^.*WeatherStation/collect/$camel ##")
    if [[ "$p" == rainCurrent && "$rain" == no ]]; then
      if [[ "$nmsgs" -eq 0 ]]; then echo "  [+] rainCurrent ABSENT — graceful"; IPASS=$((IPASS+1))
      else echo "  [!] rainCurrent UNEXPECTEDLY present ($nmsgs msgs)"; IWRONG=$((IWRONG+1)); fi
      continue
    fi
    if [[ "$nmsgs" -eq 0 ]]; then echo "  [.] $p ($camel): no data this window"; IMISS=$((IMISS+1)); continue; fi
    # CORRUPT = a field is present but WRONG (real bug). incomplete = a field was
    # shed by the device under load (empty) — tolerated on a constrained device.
    local corrupt=0 incomplete=0 why=""
    if [[ -n "$aname" ]]; then [[ "$aname" == "$p" ]] || { corrupt=1; why="name='$aname'!='$p' "; }
    else incomplete=1; why="${why}name-shed "; fi
    if [[ -n "$aval" ]]; then in_band "$aval" "$ev" || { corrupt=1; why="${why}val=$aval!~$ev "; }
    else incomplete=1; why="${why}val-shed "; fi
    if [[ -n "$aunit" ]]; then [[ "$aunit" == "$eu" ]] || { corrupt=1; why="${why}unit='$aunit'!='$eu' "; }
    else incomplete=1; why="${why}unit-shed "; fi
    if [[ "$corrupt" -eq 1 ]]; then echo "  [!] $p ($camel): CORRUPT $why($nmsgs msgs)"; IWRONG=$((IWRONG+1))
    elif [[ "$incomplete" -eq 1 ]]; then echo "  [.] $p ($camel): incomplete $why($nmsgs msgs)"; IMISS=$((IMISS+1))
    else echo "  [+] $p: name='$aname' val=$aval unit=$aunit ($nmsgs msgs)"; IPASS=$((IPASS+1)); fi
  done <<<"$ORACLE"
}

# pm_scan <since-s> -> STORM TSMX CRASH UNKNOWN DEADLINE (scoped to this connection)
pm_scan() {
  local w; w=$(docker logs --since "${1}s" "$PM" 2>&1 | grep -F "$CONN_ID-bacnet_connection")
  STORM=$(grep -ciE 'connectlost|reconnecting' <<<"$w" || true)
  TSMX=$(grep -ciE 'max concurrency|encode failed|no free invoke' <<<"$w" || true)
  UNKNOWN=$(grep -ciE 'unknown-object|not present on device' <<<"$w" || true)
  DEADLINE=$(grep -ciE 'client deadline|read aborted' <<<"$w" || true)
  CRASH=$(docker logs --since "${1}s" "$PM" 2>&1 | grep -ciE 'unhandledrejection|uncaughtexception|fatal' || true)
}
pm_rss() { docker stats --no-stream --format '{{.MemUsage}}' "$PM" 2>/dev/null | awk '{print $1+0}'; }

cmd_verify() {
  local v="$1" cfg port dev rain cap; cfg=$(variant_cfg "$v") || { echo "unknown variant: $v" >&2; exit 2; }
  read -r port dev rain <<<"$cfg"
  echo "=== VERIFY [$v]  $SIM_HOST:$port dev $dev  (rainCurrent present=$rain) ==="
  cap="$RUN/wsint-$v.cap"; : >"$cap"
  local cap_s=15; [[ "$v" == overloaded ]] && cap_s=45  # constrained device needs longer to serve all 51 endpoints
  timeout $((cap_s+12)) mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "services/$RECV_ID/WeatherStation/collect/+" -F '%t %p' >"$cap" 2>/dev/null &
  local sub=$!
  deploy_variant "$v" "${SAMPLING_MS:-1000}" || { kill "$sub" 2>/dev/null; remove; return 1; }
  sleep "$cap_s"
  kill "$sub" 2>/dev/null; wait "$sub" 2>/dev/null || true
  assert_integrity "$cap" "$rain"
  pm_scan 25
  local total; total=$(grep -c . <<<"$ORACLE")
  echo "  PM: storm=$STORM tsm=$TSMX crash=$CRASH unknown=$UNKNOWN deadline=$DEADLINE(handled)  recv=$(svc_state "$RECV_ID")"
  local verdict=FAIL healthy=0
  [[ "$STORM" -le 1 && "$TSMX" -eq 0 && "$CRASH" -eq 0 ]] && healthy=1
  if [[ "$IWRONG" -eq 0 && "$healthy" -eq 1 ]]; then
    if [[ "$v" == overloaded ]]; then
      [[ "$IPASS" -ge 14 ]] && verdict=PASS   # constrained: no corruption + most points complete; shed fields tolerated
    else
      [[ "$IMISS" -eq 0 && "$IPASS" -eq "$total" ]] && verdict=PASS   # clean device: everything complete + correct
    fi
  fi
  echo "=== [$v] $verdict — correct=$IPASS wrong=$IWRONG miss=$IMISS / $total, storm=$STORM tsm=$TSMX crash=$CRASH deadline=$DEADLINE ==="
  remove
  [[ "$verdict" == PASS ]]
}

cmd_soak() {
  local v="$1" mins="${2:-15}" cfg port dev rain; cfg=$(variant_cfg "$v") || { echo "unknown variant: $v" >&2; exit 2; }
  read -r port dev rain <<<"$cfg"
  local samp="${SAMPLING_MS:-500}" total; total=$(grep -c . <<<"$ORACLE")
  echo "=== SOAK [$v] ${mins}min @ ${samp}ms (~$(( 51*1000/samp )) reads/s hammer), FAIL-FAST on corruption/TSM/crash/storm/leak ==="
  deploy_variant "$v" "$samp" || { remove; return 1; }
  local t0 r0 rmax rounds=0 cwrong=0 cmiss=0 cdead=0 cstorm=0 ctsm=0 ccrash=0 r FAILED=0 reason=""
  t0=$(date +%s); r0=$(pm_rss); rmax=$r0
  while (( $(date +%s) - t0 < mins*60 )); do
    local cap="$RUN/wsint-soak.cap"; : >"$cap"
    timeout 11 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
      -t "services/$RECV_ID/WeatherStation/collect/+" -F '%t %p' >"$cap" 2>/dev/null || true
    assert_integrity "$cap" "$rain" >"$RUN/wsint-soak-round.txt"
    pm_scan 14
    r=$(pm_rss); if awk "BEGIN{exit !($r>$rmax)}"; then rmax=$r; fi
    rounds=$((rounds+1)); cwrong=$((cwrong+IWRONG)); cmiss=$((cmiss+IMISS)); cdead=$((cdead+DEADLINE))
    cstorm=$((cstorm+STORM)); ctsm=$((ctsm+TSMX)); ccrash=$((ccrash+CRASH))
    printf "  t+%02dm  correct=%d/%d wrong=%d miss=%d  unknown=%d(rainCurrent) deadline=%d storm=%d tsm=%d crash=%d  RSS=%s(max %s)\n" \
      "$(( ($(date +%s)-t0)/60 ))" "$IPASS" "$total" "$IWRONG" "$IMISS" "$UNKNOWN" "$DEADLINE" "$STORM" "$TSMX" "$CRASH" "$r" "$rmax"
    (( IWRONG>0 )) && { FAILED=1; reason="CORRUPTION ($IWRONG wrong)"; }
    (( TSMX>0 ))   && { FAILED=1; reason="adapter TSM exhaustion ($TSMX)"; }
    (( CRASH>0 ))  && { FAILED=1; reason="crash ($CRASH)"; }
    (( STORM>1 ))  && { FAILED=1; reason="reconnect storm ($STORM)"; }
    awk "BEGIN{exit !($r > $r0+60)}" && { FAILED=1; reason="RSS leak ($r0->$r MiB)"; }
    if (( FAILED )); then
      echo "  [!] FAIL-FAST t+$(( ($(date +%s)-t0)/60 ))m: $reason — context:"; grep -E '\[!\]' "$RUN/wsint-soak-round.txt" | head -8; break
    fi
  done
  echo "=== SOAK [$v] $([[ $FAILED -eq 0 ]] && echo PASS || echo FAIL): $rounds rounds, RSS ${r0}->${rmax} MiB,"
  echo "    cum wrong=$cwrong miss=$cmiss deadline=$cdead(handled) storm=$cstorm tsm=$ctsm crash=$ccrash ${reason:+— $reason} ==="
  remove
  (( FAILED==0 ))
}

case "${1:-}" in
  verify)     login; cmd_verify "${2:?variant}" ;;
  verify-all) login; rc=0; for v in full norain overloaded; do cmd_verify "$v" || rc=1; sleep 10; done; exit $rc ;;
  soak)       login; cmd_soak "${2:?variant}" "${3:-15}" ;;
  cleanup)    login; remove; echo "removed" ;;
  *) sed -n '2,40p' "$0"; exit 0 ;;
esac
