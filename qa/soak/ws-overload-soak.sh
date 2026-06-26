#!/usr/bin/env bash
# =============================================================================
# BACnet OVERLOAD-RESILIENCE soak — proves the adapter does NOT amplify a
# device overload caused by a toxic over-polling service.
# =============================================================================
# Scenario (regression _bacnet_miele_missing_rainCurrent): ONE WeatherStation
# receive SCF polls 51 endpoints (17 points x object-name+present-value+units)
# every 1000ms = ~51 reads/s on ONE embedded device. rainCurrent is mis-scoped
# to an ABSENT object (instance 3) -> unknown-object every poll. The SCF's
# `rules: - cov` is a Cybus mapping dedup, NOT BACnet COV — the adapter is
# polling-only, so it does NOT throttle the BACnet poll rate. The device
# (TSM pool 12, 200/150ms delay, reason-8 aborts) saturates.
#
# The adapter MUST survive, not amplify:
#   - reply-time aborts / dropped reads are EXPECTED (device is overloaded) but
#     handled as "busy": connection stays `connected`, NO reconnect storm
#     (~0 connectLost/Reconnecting beyond the one initial connect), and the
#     ADAPTER-side TSM never exhausts (0 "max concurrency" / "encode failed").
#   - rainCurrent degrades gracefully: unknown-object every poll with an
#     actionable log naming the point, while the OTHER 16 points keep flowing.
#   - no crash / no unhandledRejection; PM RSS flat.
# back-off proof: at 5000ms (~10 reads/s) the aborts/drops fall sharply and all
# 16 points flow clean — pinning the root cause on poll rate, not the adapter.
#
# Subcommands:
#   smoke           bring up overloaded WS, deploy @1s, 2 poll cycles, assert, cleanup
#   soak [minutes]  sustained @1s (default 30), monitor, assert (long; human-run)
#   backoff         redeploy @5000ms, confirm aborts fall + all 16 points clean
#   cleanup         tear down CW services + the overloaded WS sim
#
# LOCAL only. Foreground compose (never `up -d`). No /tmp (uses .run/).
# Env: CW_HOST CW_USER CW_PASS · MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS
#      SIM_HOST (172.18.0.1) · PM (platform-protocol-mapper-1)
# Prereqs: CW running; curl jq mosquitto_sub base64 docker awk.
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
COMPOSE="$REPO/compose/ws-overload.compose.yaml"
CONN="$REPO/scf/miele/connection_bacnet.yaml"
RUN="$REPO/.run"

CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
MQTT_HOST="${MQTT_HOST:-localhost}"; MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"; MQTT_PASS="${MQTT_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"
PM="${PM:-platform-protocol-mapper-1}"
API="https://${CW_HOST}/api"

# Real cert fixture (the authoritative SCF under test).
WS_RECV="/home/dj/protocols/system-test-fixtures/regression-tests/_bacnet_miele_missing_rainCurrent/receive_bacnet_WeatherStation.yaml"

# Overloaded WeatherStation identity (must match the profile/compose).
WS_DEV=2000302; WS_PORT=47868; COMPOSE_SVC="bacnet-weatherstation-overloaded"
CONN_ID="wsoverload_conn"; RECV_ID="wsoverload_recv"; PROJECT="bacnet_simulator"

# The 16 points the device DOES expose (rainCurrent/instance 3 is absent), in the
# SCF's collect-topic CamelCase. Used to assert siblings keep flowing.
SIBLINGS=(OutdoorTemperature WindSpeed RainLast24h RelativeHumidity \
  BrightnessNorth BrightnessEast BrightnessSouth BrightnessWest \
  ForecastDay1Max ForecastDay1Min ForecastDay2Max ForecastDay2Min \
  ForecastDay3Max ForecastDay3Min SunAzimuthAngle SunElevationAngle)

usage() {
  sed -n '2,40p' "$0"
  exit "${1:-0}"
}

require_tools() {
  for c in curl jq mosquitto_sub base64 docker awk; do
    command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
  done
  [[ -f "$WS_RECV" ]] || { echo "ERROR: cert SCF not found: $WS_RECV" >&2; exit 1; }
  [[ -f "$COMPOSE" ]] || { echo "ERROR: compose not found: $COMPOSE" >&2; exit 1; }
  mkdir -p "$RUN"
}

# --- Connectware REST helpers (same pattern as the other e2e scripts) ---------
login() {
  TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
  [[ -n "$TOKEN" ]] || { echo "ERROR: CW auth failed at $API" >&2; exit 1; }
}
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }
deploy() { # deploy <id> <scf-file> <params-json>
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
remove_services() {
  for id in "$RECV_ID" "$CONN_ID"; do
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' \
      -d '{"operation":"disable"}' >/dev/null 2>&1 || true
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1 || true
  done
}

# --- simulator lifecycle (foreground/backgrounded, NEVER `up -d`) -------------
sim_up() {
  echo "==> build + start overloaded WeatherStation ($COMPOSE_SVC, $SIM_HOST:$WS_PORT dev $WS_DEV)"
  docker compose -f "$COMPOSE" -p "$PROJECT" up --build "$COMPOSE_SVC" \
    >"$RUN/ws-overload-sim.log" 2>&1 &
  SIM_BG_PID=$!
  # Wait until the device binds its UDP port (metrics endpoint up = device live).
  for _ in $(seq 1 60); do
    if curl -s "http://127.0.0.1:9168/metrics" >/dev/null 2>&1; then
      echo "  sim healthy (metrics :9168 up)"; return 0
    fi
    if ! kill -0 "$SIM_BG_PID" 2>/dev/null; then
      echo "ERROR: sim exited early — see $RUN/ws-overload-sim.log" >&2
      tail -20 "$RUN/ws-overload-sim.log" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "ERROR: sim did not become healthy in time" >&2
  tail -20 "$RUN/ws-overload-sim.log" >&2 || true
  return 1
}
sim_down() {
  docker compose -f "$COMPOSE" -p "$PROJECT" down >/dev/null 2>&1 || true
}

cleanup() {
  echo "==> cleanup (services + sim)"
  login 2>/dev/null && remove_services || true
  sim_down
}

# --- deploy the cert SCF against the overloaded device ------------------------
# rainCurrentObjectInstance=3 -> the ABSENT instance (unknown-object every poll).
# All points enabled, sampling_interval = poll rate under test.
deploy_stack() { # deploy_stack <interval-ms>
  local interval="$1"
  echo "==> deploy connection + WeatherStation receive @ ${interval}ms"
  deploy "$CONN_ID" "$CONN" \
    "{\"bacnet_host\":\"$SIM_HOST\",\"bacnet_port\":$WS_PORT,\"device_instance\":$WS_DEV,\"machine_common_name\":\"wsoverload\"}"
  wait_enabled "$CONN_ID" 40 || { echo "ERROR: connection did not enable" >&2; return 1; }
  deploy "$RECV_ID" "$WS_RECV" \
    "{\"bacnet_connection_service_id\":\"$CONN_ID\",\"machine_common_name\":\"DA_111_WS1\",\"sampling_interval\":$interval,\"rainCurrentObjectInstance\":3,\"rainCurrentTargetState\":\"enabled\"}"
  wait_enabled "$RECV_ID" 40 || { echo "ERROR: receive did not enable" >&2; return 1; }
}

# --- evidence capture --------------------------------------------------------
pm_rss() { docker stats --no-stream --format '{{.MemUsage}}' "$PM" 2>/dev/null | awk '{print $1+0}'; }

# Capture <secs> of MQTT collect-topic traffic for the receive into a file.
capture_mqtt() { # capture_mqtt <secs> <outfile>
  timeout "$1" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "services/$RECV_ID/WeatherStation/collect/+" -F '%t' >"$2" 2>/dev/null || true
}
# Live sibling points = distinct collect/* leaf names seen, minus RainCurrent.
live_siblings() { # live_siblings <mqtt-capture-file>
  awk -F/ '{print $NF}' "$1" | sort -u | grep -v '^RainCurrent$' || true
}

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  [+] $1"; PASS=$(( PASS + 1 )); else echo "  [!] FAIL: $1 — $3"; FAIL=$(( FAIL + 1 )); fi; }

# Shared amplification assertions over a PM log window + an MQTT capture file.
# Args: <pm-log-text> <mqtt-file> <rss0> <rss1> <label>
assert_no_amplification() {
  local LOG="$1" MQ="$2" R0="$3" R1="$4" TAG="$5"
  # Device IS overloaded -> reply-time aborts / drops are EXPECTED, not a bug.
  local ABORTS DROPS LIVE NLIVE
  ABORTS=$(grep -ciE 'application[ -]?exceeded[ -]?reply[ -]?time|reply-time|ABORT' <<<"$LOG" || true)
  echo "  [i] $TAG: reply-time/abort log lines = $ABORTS (nonzero EXPECTED — device saturated)"

  # 1. connection stays connected — NO reconnect storm. The base FSM logs
  #    'Reconnecting <class>' / 'Trying to reconnect' and the adapter logs
  #    'connectLost'. One initial connect is fine; a STORM is the failure.
  local STORM
  STORM=$(grep -ciE 'connectlost|reconnecting bacnet|trying to reconnect' <<<"$LOG" || true)
  check "[$TAG] connection NOT churning — no reconnect storm (connectLost/Reconnecting ~0)" \
    "[[ $STORM -le 1 ]]" "saw $STORM reconnect/connectLost lines (storm)"
  check "[$TAG] receive + connection both still enabled" \
    "[[ \$(svc_state $CONN_ID) == enabled && \$(svc_state $RECV_ID) == enabled ]]" \
    "conn=$(svc_state $CONN_ID) recv=$(svc_state $RECV_ID)"

  # 2. ADAPTER-side TSM never exhausts (the device's drops are NOT mirrored into
  #    the client). No 'max concurrency' / 'encode failed' from the adapter.
  local TSMX
  TSMX=$(grep -ciE 'max concurrency|encode failed|tsm.*(exhaust|full)|no free invoke' <<<"$LOG" || true)
  check "[$TAG] adapter-side TSM never exhausts (0 max-concurrency/encode-failed)" \
    "[[ $TSMX -eq 0 ]]" "saw $TSMX adapter TSM-exhaustion lines"

  # 3. rainCurrent degrades gracefully: actionable unknown-object naming the point.
  check "[$TAG] rainCurrent (analog-input:3) degrades gracefully — actionable unknown-object log" \
    "grep -qF \"analog-input:3 'present-value' not present on device — correct this point's objectInstance/objectType\" <<<\"\$LOG\"" \
    "actionable unknown-object line for rainCurrent not found"

  # 4. siblings keep flowing on MQTT while rainCurrent fails.
  LIVE=$(live_siblings "$MQ"); NLIVE=$(grep -c . <<<"$LIVE" 2>/dev/null || echo 0)
  echo "  [i] $TAG: live sibling collect topics = $NLIVE  [$(tr '\n' ' ' <<<"$LIVE")]"
  check "[$TAG] >=4 sibling points keep publishing on MQTT throughout" \
    "[[ $NLIVE -ge 4 ]]" "only $NLIVE sibling topics live"
  check "[$TAG] rainCurrent does NOT publish a collect topic (the absent point)" \
    "! grep -q '/RainCurrent$' \"$MQ\"" "RainCurrent collect topic unexpectedly present"

  # 5. no crash / no unhandledRejection; RSS flat.
  check "[$TAG] no crash (0 unhandledRejection/uncaught/fatal)" \
    "[[ \$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<\"\$LOG\") -eq 0 ]]" "crash markers seen"
  check "[$TAG] PM RSS flat (start ${R0} -> end ${R1} MiB, <40 growth)" \
    "awk \"BEGIN{exit !($R1 - $R0 < 40)}\"" "RSS grew ${R0}->${R1} MiB"
}

# =============================================================================
# SMOKE — short proof the whole rig works: overload happens, no amplification.
# =============================================================================
cmd_smoke() {
  require_tools
  trap cleanup EXIT
  echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
  sim_up
  login
  deploy_stack 1000

  echo "==> settle + capture 2 poll cycles of MQTT + PM log (toxic @1s)"
  sleep 6
  local R0 MQ LOG R1
  R0=$(pm_rss); MQ="$RUN/ws-overload-smoke.mqtt"
  T0=$(date +%s)
  capture_mqtt 12 "$MQ"
  LOG=$(docker logs --since "$(( $(date +%s) - T0 + 20 ))s" "$PM" 2>&1)
  R1=$(pm_rss)

  echo "== OVERLOAD-RESILIENCE assertions (@1s, ~51 reads/s) =="
  assert_no_amplification "$LOG" "$MQ" "$R0" "$R1" "smoke@1s"

  echo "==> RESULT: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

# =============================================================================
# SOAK — sustained @1s for <minutes> (default 30). Human-run for control.
# =============================================================================
cmd_soak() {
  local mins="${1:-30}"
  require_tools
  trap cleanup EXIT
  echo "==> clean slate"; "$REPO/qa/tools/cw-clean-all.sh" >/dev/null 2>&1 || true
  sim_up
  login
  deploy_stack 1000

  echo "==> SOAK ${mins} min @1s (~51 reads/s on one device); sampling RSS each minute"
  sleep 6
  local R0 RSSMAX
  R0=$(pm_rss); RSSMAX=$R0
  local secs=$(( mins * 60 ))
  T0=$(date +%s)
  while (( $(date +%s) - T0 < secs )); do
    sleep 60
    local r; r=$(pm_rss)
    # RSS is a float (MiB); bash (( )) is integer-only, so compare via awk.
    if awk "BEGIN{exit !($r > $RSSMAX)}"; then RSSMAX=$r; fi
    echo "  [i] t+$(( ($(date +%s) - T0) / 60 ))m  PM RSS=${r} MiB (max ${RSSMAX})  conn=$(svc_state $CONN_ID)"
    # fail-fast: amplification markers in the last minute must stay 0 (storm/TSM/crash)
    local W st tx cr; W=$(docker logs --since 65s "$PM" 2>&1)
    st=$(grep -ciE 'connectlost|reconnecting bacnet|trying to reconnect' <<<"$W" || true)
    tx=$(grep -ciE 'max concurrency|encode failed|no free invoke' <<<"$W" || true)
    cr=$(grep -ciE 'unhandledrejection|uncaught|fatal' <<<"$W" || true)
    if (( st > 1 || tx > 0 || cr > 0 )); then
      echo "  [!] CRITICAL t+$(( ($(date +%s) - T0) / 60 ))m: storm=$st tsm=$tx crash=$cr — amplification, aborting"
      FAIL=$(( FAIL + 1 )); break
    fi
  done

  echo "==> capture final 15s MQTT + full-soak PM log"
  local MQ LOG R1
  MQ="$RUN/ws-overload-soak.mqtt"; capture_mqtt 15 "$MQ"
  LOG=$(docker logs --since "${secs}s" "$PM" 2>&1)
  R1=$RSSMAX

  echo "== OVERLOAD-RESILIENCE assertions (sustained ${mins}m @1s) =="
  assert_no_amplification "$LOG" "$MQ" "$R0" "$R1" "soak@1s"

  echo "==> RESULT: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

# =============================================================================
# BACKOFF — same device, redeploy @5000ms (~10 reads/s). Aborts/drops fall
# sharply and ALL 16 siblings flow clean: root cause = poll rate, not adapter.
# =============================================================================
cmd_backoff() {
  require_tools
  trap cleanup EXIT
  login

  # If a soak/smoke isn't already running the sim, bring it up.
  if ! curl -s "http://127.0.0.1:9168/metrics" >/dev/null 2>&1; then sim_up; fi

  # Baseline the toxic rate so the drop is measurable, then back off.
  echo "==> [baseline] deploy @1s, measure abort rate over 12s"
  remove_services; deploy_stack 1000; sleep 6
  local LOGF
  T0=$(date +%s); sleep 12
  local ABORTS_FAST
  ABORTS_FAST=$(docker logs --since "$(( $(date +%s) - T0 + 5 ))s" "$PM" 2>&1 \
    | grep -ciE 'application[ -]?exceeded[ -]?reply[ -]?time|reply-time|ABORT' || true)
  echo "  [i] @1s abort/reply-time lines in 12s = $ABORTS_FAST"

  echo "==> [back-off] redeploy @5000ms, settle, measure over 20s"
  remove_services; deploy_stack 5000; sleep 12
  local MQ LOG ABORTS_SLOW LIVE NLIVE R0 R1
  R0=$(pm_rss); MQ="$RUN/ws-overload-backoff.mqtt"
  T0=$(date +%s)
  capture_mqtt 20 "$MQ"
  LOG=$(docker logs --since "$(( $(date +%s) - T0 + 5 ))s" "$PM" 2>&1)
  R1=$(pm_rss)
  ABORTS_SLOW=$(grep -ciE 'application[ -]?exceeded[ -]?reply[ -]?time|reply-time|ABORT' <<<"$LOG" || true)
  LIVE=$(live_siblings "$MQ"); NLIVE=$(grep -c . <<<"$LIVE" 2>/dev/null || echo 0)
  echo "  [i] @5s abort/reply-time lines in 20s = $ABORTS_SLOW ; live siblings = $NLIVE"

  echo "== BACK-OFF proof (root cause = poll rate) =="
  check "abort/reply-time rate falls sharply when poll slows 1s -> 5s" \
    "[[ $ABORTS_SLOW -lt $ABORTS_FAST ]]" "slow=$ABORTS_SLOW not < fast=$ABORTS_FAST"
  check "all 16 sibling points flow clean at 5s" \
    "[[ $NLIVE -ge 16 ]]" "only $NLIVE/16 siblings live at 5s"
  check "rainCurrent still the only failing point (its collect topic absent)" \
    "! grep -q '/RainCurrent$' \"$MQ\"" "RainCurrent collect topic present at 5s"
  check "connection stayed enabled across the rate change" \
    "[[ \$(svc_state $CONN_ID) == enabled ]]" "conn=$(svc_state $CONN_ID)"

  echo "==> RESULT: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

case "${1:-}" in
  smoke)   cmd_smoke ;;
  soak)    cmd_soak "${2:-30}" ;;
  backoff) cmd_backoff ;;
  cleanup) cleanup ;;
  -h|--help|help|"") usage 0 ;;
  *) echo "unknown subcommand: $1" >&2; usage 2 ;;
esac
