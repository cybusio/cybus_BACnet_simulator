#!/usr/bin/env bash
# =============================================================================
# spectrum-verify.sh — live-read every BACnet read-spectrum topic over MQTT,
# SIMULTANEOUSLY, and print a visual PASS/FAIL table the human can eyeball.
#
# This is the verify half of the pair. It imports the SAME CASES table + id/topic
# helpers from spectrum-deploy.sh (sourced as a library, SPECTRUM_LIB=1) so the
# topics it reads are exactly the ones spectrum-deploy.sh published — they can
# never drift. For each of the ~40 cases it subscribes to services/<SCF id>/read,
# grabs one retained/fresh message with a bounded timeout (all subscribers run in
# PARALLEL, not one-at-a-time), then checks the observed JSON payload's type/shape
# (via jq) against the EXPECTED datatype from the TEST-MATRIX.
#
# Payload contract (BacnetConnection.handleRead → endpoint): the endpoint publishes
#   { "value": <scalar|array>, "timestamp": <number>, ... }
# so every check looks at `.value`. The adapter's value parsers (ASHRAE 135 §20.2.1,
# stack/lib/BacnetClient.js) decode:
#   REAL/UNSIGNED/SIGNED  -> JS number
#   BOOLEAN               -> JS boolean
#   ENUMERATED (binary/MV present-value) -> string ("active"/"inactive"/state text)
#   CHARACTER_STRING (object-name) -> bare string (quote-stripped)
#   OBJECT_ID (object-identifier / object-list element) -> {objectTypeName, objectInstance}
# object-list arrays that exceed one APDU are recovered element-by-element
# (indexed / ReadRange) on the size-abort devices and surface as a full array.
#
# Source of truth: docs/TEST-MATRIX.md + device_profiles.py (via the
# imported CASES table). Nothing here is invented.
#
# Prerequisites:
#   - spectrum-deploy.sh has been run (services enabled, data flowing)
#   - the base simulator stack + Connectware are up
#   - mosquitto_sub (mosquitto-clients) and jq on PATH
#
# Usage:
#   e2e/spectrum-verify.sh            # read all topics in parallel, print table
#   e2e/spectrum-verify.sh --help
#
# Env overrides:
#   MQTT_HOST(localhost) MQTT_PORT(1883) MQTT_USER(admin) MQTT_PASS(admin)
#   READ_TIMEOUT(35)  — seconds to wait for one message per topic. object-list arrays
#                       recover chunk-by-chunk and can take >>8s under fleet load, so
#                       match discovery-e2e's 35s window. Subscribers run in parallel
#                       and return on first message, so fast topics aren't slowed.
#   ID_PREFIX(spectrum) — MUST match what spectrum-deploy.sh used
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-admin}"
MQTT_PASS="${MQTT_PASS:-admin}"
READ_TIMEOUT="${READ_TIMEOUT:-35}"
# ID_PREFIX is consumed by the sourced library; default kept identical to deploy's.
export ID_PREFIX="${ID_PREFIX:-spectrum}"

usage () { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
case "${1:-run}" in -h|--help|help) usage; exit 0 ;; run) ;; *) echo "unknown arg: $1" >&2; usage; exit 2 ;; esac

# ----- import the single source of truth (CASES, scf_id, topic, EP_TOPIC) -----
# SPECTRUM_LIB=1 makes spectrum-deploy.sh define everything and return without
# running its main — so this script reuses the exact same spectrum definition.
# shellcheck source=spectrum-deploy.sh disable=SC1091
SPECTRUM_LIB=1 source "${DIR}/spectrum-deploy.sh"

for c in mosquitto_sub jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found on PATH" >&2; exit 1; }
done

# ----- the jq oracle: does OBSERVED match EXPECTED for (datatype, shape)? ------
# Returns 0 PASS / 1 FAIL. `payload` is the raw MQTT JSON; the checks read `.value`.
# Arrays additionally require every element to carry the object-id shape. `expect`
# (the deploy CASES text) lets the empty/device-only object-list accept length 0.
matches () {
  local datatype="$1" shape="$2" payload="$3" expect="${4:-}"
  [[ -n "$payload" ]] || return 1
  if [[ "$shape" == "array" ]]; then
    # object-list: an array whose every element is {objectTypeName,objectInstance}.
    # An empty device legitimately serves a near-empty list, so only require a
    # non-empty array when the expectation isn't the "just the device object" case.
    # A per-device REAL object count would give true partial-recovery
    # detection. Not done here: the CASES `note` counts are stale (legacy/modern carry
    # +200 padding → ~215/223 objs, energy +50 → ~95; norpm/abortseg notes claim
    # ">480B" but only have ~11), and live counts shift with BACNET_OBJECT_PADDING,
    # so a hard-coded per-row floor would flake. Element-shape (below) is enforced.
    local minlen=1
    [[ "$expect" == *"device object"* ]] && minlen=0
    jq -e --argjson minlen "$minlen" '
      .value as $v
      | ($v | type == "array")
      and (($v | length) >= $minlen)
      and ($v | all(type == "object" and has("objectTypeName") and has("objectInstance")))
    ' <<<"$payload" >/dev/null 2>&1
    return $?
  fi
  case "$datatype" in
    REAL)
      jq -e '.value | type == "number"' <<<"$payload" >/dev/null 2>&1 ;;
    UNSIGNED_INT)
      # unsigned ordinal: a non-negative integer number
      jq -e '.value | (type == "number") and (. == floor) and (. >= 0)' <<<"$payload" >/dev/null 2>&1 ;;
    ENUMERATED)
      # Every enum row here is a binary present-value → exactly "active"/"inactive".
      # Discriminated from object-name so a misrendered name can't pass as an enum.
      jq -e '.value | (type == "string") and (. == "active" or . == "inactive")' <<<"$payload" >/dev/null 2>&1 ;;
    CHARACTER_STRING)
      # object-name: a non-empty bare string that is NOT a binary enum token
      # (an object-name rendered as active/inactive would be wrong).
      jq -e '.value | (type == "string") and (length > 0) and (. != "active") and (. != "inactive")' <<<"$payload" >/dev/null 2>&1 ;;
    OBJECT_ID)
      jq -e '.value | (type == "object") and has("objectTypeName") and has("objectInstance") and (.objectInstance | type == "number")' <<<"$payload" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Short, human OBSERVED rendering of `.value` for the table (truncated for arrays).
render_observed () {
  local payload="$1"
  [[ -n "$payload" ]] || { printf '(no message)'; return; }
  jq -r '
    .value as $v
    | if   ($v | type) == "array"  then "array[\($v|length)] e.g. \(($v[0]|tojson)? // "?")"
      elif ($v | type) == "object" then ($v | tojson)
      elif ($v | type) == "string" then "\"\($v)\""
      else ($v | tojson) end
  ' <<<"$payload" 2>/dev/null || printf '%s' "${payload:0:48}"
}

# Element count + recovery note for array rows (per the device's abort behaviour,
# which the deploy CASES `expect` text already encodes as "recovered"/"fits").
array_detail () {
  local payload="$1" expect="$2"
  local len recov
  len=$(jq -r '.value | if type=="array" then length else "-" end' <<<"$payload" 2>/dev/null || echo '-')
  if [[ "$expect" == *recovered* ]]; then recov="indexed-recovered (too-large ABORT)"; else recov="single-APDU (no indexed)"; fi
  printf 'len=%s · %s' "$len" "$recov"
}

# ----- parallel collection ----------------------------------------------------
# Fire one `mosquitto_sub -C 1` per topic into the background, each writing its
# single payload to a per-ordinal file; then wait for all. This reads the whole
# spectrum SIMULTANEOUSLY rather than serially.
COL='\033[36m'; BOLD='\033[1m'; DIM='\033[2m'; GRN='\033[32m'; RED='\033[31m'; YEL='\033[33m'; RST='\033[0m'

collect_all () {
  local outdir="$1"
  local n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note
  while IFS=$'\t' read -r n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note; do
    [[ -z "${n// }" ]] && continue
    local t; t="$(topic "$key")"
    # Background subscriber: one message, bounded by READ_TIMEOUT; empty file on timeout.
    timeout "$READ_TIMEOUT" mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
      -u "$MQTT_USER" -P "$MQTT_PASS" -t "$t" -C 1 >"${outdir}/${n}.json" 2>/dev/null &
  done <<<"$CASES"
  # A timed-out subscriber (slow/missing topic) exits non-zero by design; never let
  # that abort the run under `set -e`.
  wait || true
}

# Script-scope so the EXIT trap can still reference it after main returns (set -u).
OUTDIR=""
trap '[[ -n "$OUTDIR" ]] && rm -rf "$OUTDIR"' EXIT

main () {
  OUTDIR="$(mktemp -d "${DIR}/.spectrum-verify.XXXXXX")"
  local outdir="$OUTDIR"

  echo -e "${BOLD}Reading ${ID_PREFIX} read-spectrum topics over MQTT (parallel, ${READ_TIMEOUT}s/topic)...${RST}"
  echo -e "${DIM}broker ${MQTT_HOST}:${MQTT_PORT} · subject services/${ID_PREFIX}_*/${EP_TOPIC}${RST}"
  collect_all "$outdir"

  echo ""
  echo -e "${BOLD}BACnet READ-SPECTRUM — LIVE VERIFICATION${RST}"
  printf "${COL}%-10s %-22s %-20s %-18s %-12s %-7s %-34s %-30s %s${RST}\n" \
    "matrix" "device" "object:instance" "property" "datatype" "shape" "EXPECTED" "OBSERVED (live)" "RESULT"
  printf "${DIM}%s${RST}\n" "$(printf '%.0s-' {1..200})"

  local pass=0 total=0
  local n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note
  while IFS=$'\t' read -r n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note; do
    [[ -z "${n// }" ]] && continue
    total=$((total + 1))
    local payload observed result expected_col detail
    payload="$(cat "${outdir}/${n}.json" 2>/dev/null || true)"
    observed="$(render_observed "$payload")"
    # EXPECTED column: the matrix expectation + the size/APDU dimension.
    expected_col="${expect} [${max_apdu}B]"
    # Array rows carry their element-count + recovery note as an un-truncated
    # trailing field so the most important signal is never cut off.
    detail=""
    [[ "$shape" == "array" ]] && detail="$(array_detail "$payload" "$expect")"
    if matches "$datatype" "$shape" "$payload" "$expect"; then
      result="${GRN}PASS${RST}"; pass=$((pass + 1))
    else
      result="${RED}FAIL${RST}"
    fi
    printf "%-10s %-22s %-20s %-18s %-12s %-7s %-34s %-30s %b  %s\n" \
      "$matrix" "$device" "${obj_type}:${obj_inst}" "$property" "$datatype" "$shape" \
      "${expected_col:0:34}" "${observed:0:30}" "$result" "$detail"
  done <<<"$CASES"

  printf "${DIM}%s${RST}\n" "$(printf '%.0s-' {1..200})"
  local color="$GRN"; [[ "$pass" -ne "$total" ]] && color="$YEL"
  echo -e "${BOLD}SUMMARY:${RST} ${color}${pass}/${total} PASS${RST}"
  echo ""
  echo -e "${BOLD}Legend${RST}"
  echo -e "  ${GRN}PASS${RST}  observed .value JSON type/shape matches the matrix datatype"
  echo -e "  ${RED}FAIL${RST}  no message within ${READ_TIMEOUT}s, or wrong JSON type/shape"
  echo -e "  ${DIM}datatypes${RST}  REAL/UNSIGNED_INT -> number · ENUMERATED/CHARACTER_STRING -> string"
  echo -e "  ${DIM}         ${RST}  OBJECT_ID -> {objectTypeName,objectInstance} · array -> object-list of object-ids"
  echo -e "  ${DIM}arrays${RST}     len=N is the recovered element count; 'indexed-recovered' = the array"
  echo -e "  ${DIM}      ${RST}     exceeded one APDU (too-large ABORT) and was rebuilt element-by-element"
  echo -e "  ${DIM}matrix${RST}     IDs map back to docs/TEST-MATRIX.md (A read paths, B aborts, C value types)"

  [[ "$pass" -eq "$total" ]]
}

main
