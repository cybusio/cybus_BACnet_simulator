#!/usr/bin/env bash
# =============================================================================
# spectrum-deploy.sh — deploy the BACnet read-spectrum SCFs onto a live
# Connectware so the adapter's full read surface can be VISUALLY verified over
# MQTT. This is the deploy half; spectrum-verify.sh is the read/assert half and
# derives the exact same SCF ids + topics from the same CASES table below, so
# deploy → verify line up one-to-one.
#
# What it covers (every row carries its TEST-MATRIX id, e.g. A-06 / B-03 / C-11):
#   - scalar present-value across datatypes: REAL (C-05), UNSIGNED (C-03),
#     BOOLEAN/ENUMERATED via binary present-value (C-02/C-09/C-10),
#     OBJECT_ID scalar via device/object-identifier (C-11)
#   - CHARACTER_STRING via object-name (C-09)
#   - object-list ARRAY reads: small that FITS one APDU and needs no indexed
#     recovery (A-11 modern 1476B, A-12 legacy 206B) AND large that ABORTs and
#     recovers element-by-element (A-06 miele, A-08 no_rpm, A-09 abort_seg
#     abort-4, B-03 energy abort-11)
#   - the APDU/segmentation/abort dimension made visible (206B no-seg /
#     480B no-seg abort-1/4/11 / 1476B segmented-both)
#
# Each case deploys a tiny SCF = one Cybus::Connection + one Cybus::Endpoint,
# mirroring qa/tools/generate-scf.sh conventions (deviceInstance !ref +
# deviceAddress !sub, present-value/object-list endpoints). metadata.name is the
# unique SCF id so probes never collide; the endpoint publishes {value,timestamp,...}
# to  services/<SCF id>/read.
#
# Source of truth (do not invent ports/objects/datatypes — all read from these):
#   - docs/TEST-MATRIX.md       (the A/B/C read+datatype+abort matrix)
#   - qa/inproc/device_profiles.py   (device port/id/scf_name/objects)
#   - qa/tools/generate-scf.sh              (SCF structure)
#   - e2e/miele-mqtt-e2e.sh            (REST deploy/enable pattern)
#
# Prerequisites:
#   - the base simulator stack is up:  docker compose up   (compose.yaml — gives
#     miele/energy/legacy/modern/newlift/no_rpm/abort_segmentation/empty/...)
#   - Connectware is running and reachable at https://$CW_HOST
#   - curl, jq, base64 on PATH
#
# Usage:
#   e2e/spectrum-deploy.sh              # clean prior spectrum, deploy ~40 SCFs, print INDEX
#   e2e/spectrum-deploy.sh deploy       # same as no-arg
#   e2e/spectrum-deploy.sh index        # print the INDEX table only (no deploy)
#   e2e/spectrum-deploy.sh cleanup      # disable + delete every spectrum SCF
#   e2e/spectrum-deploy.sh --help
#
# Env overrides:
#   CW_HOST(localhost) CW_USER(admin) CW_PASS(admin)
#   SIM_HOST(172.18.0.1)  — host sim IP as seen by the protocol-mapper container
#   POLL_MS(2000)         — present-value poll interval; object-list is pinned 300000
#   ID_PREFIX(spectrum)   — SCF id / topic-prefix namespace; verify.sh must match
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- config (overridable via env) ------------------------------------------
CW_HOST="${CW_HOST:-localhost}"
CW_USER="${CW_USER:-admin}"
CW_PASS="${CW_PASS:-admin}"
SIM_HOST="${SIM_HOST:-172.18.0.1}"  # host-network sims as seen from the PM container
POLL_MS="${POLL_MS:-2000}"          # present-value cadence
OBJLIST_MS="${OBJLIST_MS:-10000}"   # object-list cadence. must be < the verify window
                                    # or the first poll (one interval after enable) never
                                    # publishes in time. 10s matches discovery-e2e; the
                                    # adapter's skip-doomed-read stops constrained devices
                                    # re-aborting every cycle, so the cost stays low.
ID_PREFIX="${ID_PREFIX:-spectrum}"  # SCF id + MQTT topic-prefix namespace
API="https://${CW_HOST}/api"

# =============================================================================
# CASES — the authoritative spectrum, shared verbatim with spectrum-verify.sh.
# One row per deployed SCF. Tab-separated columns:
#
#   1 n           ordinal (stable, 1-based)
#   2 key         short SCF-id suffix (final id = <ID_PREFIX>_<key>)
#   3 profile     source device-profile name in device_profiles.py (informational;
#                 these are purpose-built single-endpoint probes, so each gets its
#                 OWN unique metadata.name == the SCF id to avoid topic collisions —
#                 the published subject is services/<SCF id>/read, NOT services/<profile>/..)
#   4 device      human device label
#   5 dev_id      deviceInstance (device_profiles.py)
#   6 port        sim UDP port (device_profiles.py)
#   7 max_apdu    device max APDU (drives the size/abort dimension)
#   8 obj_type    BACnet objectType for the endpoint
#   9 obj_inst    objectInstance
#  10 property    BACnet property (present-value / object-name / object-identifier
#                 / object-list)
#  11 datatype    expected application datatype (TEST-MATRIX Group C)
#  12 shape       scalar | array
#  13 matrix      TEST-MATRIX id(s) this row exercises
#  14 expect      EXPECTED summary (human + verify.sh oracle key, see verify.sh)
#  15 note        size/APDU / abort behaviour note
#
# Every device/port/id/object below is taken from device_profiles.py; every
# matrix id from TEST-MATRIX.md. Nothing here is invented.
# =============================================================================
read -r -d '' CASES <<'TSV' || true
1	modern_pv_real	modern_controller	Trane Tracer SC+	400001	47811	1476	analog-input	1	present-value	REAL	scalar	C-05,A-01	REAL number	1476B seg-both, no abort
2	modern_av_real	modern_controller	Trane Tracer SC+	400001	47811	1476	analog-value	1	present-value	REAL	scalar	C-05,A-01	REAL number	1476B seg-both, no abort
3	modern_bi_enum	modern_controller	Trane Tracer SC+	400001	47811	1476	binary-input	1	present-value	ENUMERATED	scalar	C-10,C-02,A-01	active/inactive enum	binary present-value renders as enum string
4	modern_bv_enum	modern_controller	Trane Tracer SC+	400001	47811	1476	binary-value	1	present-value	ENUMERATED	scalar	C-10,C-02,A-01	active/inactive enum	binary present-value renders as enum string
5	modern_mv_uint	modern_controller	Trane Tracer SC+	400001	47811	1476	multi-state-value	1	present-value	UNSIGNED_INT	scalar	C-03,A-01	UNSIGNED int	multi-state present-value is an unsigned ordinal
6	modern_name_str	modern_controller	Trane Tracer SC+	400001	47811	1476	analog-input	1	object-name	CHARACTER_STRING	scalar	C-09,A-01	bare CHARACTER_STRING	object-name is a CharacterString (quote-stripped)
7	modern_devid_oid	modern_controller	Trane Tracer SC+	400001	47811	1476	device	400001	object-identifier	OBJECT_ID	scalar	C-11,A-01	OBJECT_ID {objectTypeName,objectInstance}	device fingerprint == deviceInstance
8	modern_objlist_small	modern_controller	Trane Tracer SC+	400001	47811	1476	device	400001	object-list	OBJECT_ID	array	A-11	small array fits 1 APDU (no indexed)	21 objects in 1476B → single ReadProperty, no abort
9	newlift_pv_real	newlift_gateway	MBS UGW Elevator	2000	47812	1476	analog-value	1	present-value	REAL	scalar	C-05,A-02	REAL number	1476B seg-both, 107-endpoint device
10	newlift_bv_enum	newlift_gateway	MBS UGW Elevator	2000	47812	1476	binary-value	2	present-value	ENUMERATED	scalar	C-10,A-02	active/inactive enum	binary present-value as enum string
11	newlift_mv_uint	newlift_gateway	MBS UGW Elevator	2000	47812	1476	multi-state-value	6	present-value	UNSIGNED_INT	scalar	C-03,A-02	UNSIGNED int	multi-state ordinal
12	newlift_name_str	newlift_gateway	MBS UGW Elevator	2000	47812	1476	analog-value	1	object-name	CHARACTER_STRING	scalar	C-09,A-02	bare CHARACTER_STRING	object-name CharacterString
13	newlift_objlist_small	newlift_gateway	MBS UGW Elevator	2000	47812	1476	device	2000	object-list	OBJECT_ID	array	A-11	array fits 1476B APDU (seg-both)	107 objects, segmented-both → no indexed needed
14	legacy_pv_real	legacy_controller	Siemens PXC36	300001	47810	206	analog-input	1	present-value	REAL	scalar	C-05,A-03	REAL number	206B no-seg; scalar ~25B fits
15	legacy_bi_enum	legacy_controller	Siemens PXC36	300001	47810	206	binary-input	1	present-value	ENUMERATED	scalar	C-10,A-03	active/inactive enum	binary present-value as enum string
16	legacy_name_str	legacy_controller	Siemens PXC36	300001	47810	206	analog-input	1	object-name	CHARACTER_STRING	scalar	C-09,A-03	bare CHARACTER_STRING	object-name fits 206B
17	legacy_devid_oid	legacy_controller	Siemens PXC36	300001	47810	206	device	300001	object-identifier	OBJECT_ID	scalar	C-11,A-03	OBJECT_ID {objectTypeName,objectInstance}	scalar object-id fits 206B
18	legacy_objlist_small	legacy_controller	Siemens PXC36	300001	47810	206	device	300001	object-list	OBJECT_ID	array	A-12	small array ~102B < 206B (no indexed)	14 objects fit 206B → single ReadProperty, no abort
19	miele_pv_real	miele_energy_meter	Miele EnergyMeter	1014006	47808	480	analog-value	101009	present-value	REAL	scalar	C-05,A-04	REAL number	480B no-seg abort-1; scalars read straight
20	miele_ai_real	miele_energy_meter	Miele EnergyMeter	1014006	47808	480	analog-input	1	present-value	REAL	scalar	C-05,A-04	REAL number	480B no-seg; scalar fits
21	miele_name_str	miele_energy_meter	Miele EnergyMeter	1014006	47808	480	analog-value	101009	object-name	CHARACTER_STRING	scalar	C-09,A-04	bare CHARACTER_STRING	object-name CharacterString fits 480B
22	miele_devid_oid	miele_energy_meter	Miele EnergyMeter	1014006	47808	480	device	1014006	object-identifier	OBJECT_ID	scalar	C-11,A-04	OBJECT_ID {objectTypeName,objectInstance}	device fingerprint
23	miele_objlist_big	miele_energy_meter	Miele EnergyMeter	1014006	47808	480	device	1014006	object-list	OBJECT_ID	array	A-06,B-01	array recovered after too-large ABORT (reason 1)	100+ objs > 480B → bufferOverflow(1) → indexed/ReadRange
24	energy_pv_real	green_energy_ebmgr	GreenEnergy eBmgr	2000001	47809	480	analog-value	1	present-value	REAL	scalar	C-05,A-05	REAL number	480B no-seg abort-11; scalars read straight
25	energy_bv_enum	green_energy_ebmgr	GreenEnergy eBmgr	2000001	47809	480	binary-value	1	present-value	ENUMERATED	scalar	C-10,A-05	active/inactive enum	binary present-value as enum string
26	energy_ai_real	green_energy_ebmgr	GreenEnergy eBmgr	2000001	47809	480	analog-input	1	present-value	REAL	scalar	C-05,A-05	REAL number	480B no-seg; scalar fits
27	energy_devid_oid	green_energy_ebmgr	GreenEnergy eBmgr	2000001	47809	480	device	2000001	object-identifier	OBJECT_ID	scalar	C-11,A-05	OBJECT_ID {objectTypeName,objectInstance}	device fingerprint
28	energy_objlist_big	green_energy_ebmgr	GreenEnergy eBmgr	2000001	47809	480	device	2000001	object-list	OBJECT_ID	array	B-03,A-06	array recovered after too-large ABORT (reason 11)	44 objs > 480B → apduTooLong(11) → indexed/ReadRange
29	norpm_pv_real	no_rpm_controller	Honeywell XL50 (no RPM)	600001	47816	480	analog-input	1	present-value	REAL	scalar	C-05,A-07	REAL number	device never advertised RPM; plain ReadProperty
30	norpm_bv_enum	no_rpm_controller	Honeywell XL50 (no RPM)	600001	47816	480	binary-value	1	present-value	ENUMERATED	scalar	C-10,A-07	active/inactive enum	binary present-value as enum string
31	norpm_name_str	no_rpm_controller	Honeywell XL50 (no RPM)	600001	47816	480	analog-input	1	object-name	CHARACTER_STRING	scalar	C-09,A-07	bare CHARACTER_STRING	object-name on a no-RPM device
32	norpm_objlist_big	no_rpm_controller	Honeywell XL50 (no RPM)	600001	47816	480	device	600001	object-list	OBJECT_ID	array	A-08,B-01	array recovered after too-large ABORT (reason 1)	object-list > 480B on a no-RPM device → indexed fallback
33	abortseg_pv_real	abort_segmentation	Schneider SmartX (abort 4)	600002	47817	480	analog-input	1	present-value	REAL	scalar	C-05	REAL number	480B no-seg abort-4; scalars read straight
34	abortseg_bv_enum	abort_segmentation	Schneider SmartX (abort 4)	600002	47817	480	binary-value	1	present-value	ENUMERATED	scalar	C-10	active/inactive enum	binary present-value as enum string
35	abortseg_objlist_big	abort_segmentation	Schneider SmartX (abort 4)	600002	47817	480	device	600002	object-list	OBJECT_ID	array	A-09,B-02	array recovered after segNotSupported ABORT (reason 4)	object-list aborts seg-not-supported(4) → indexed reads
36	ultraslow_pv_real	ultra_slow	Generic SlowGateway	600003	47818	480	analog-input	1	present-value	REAL	scalar	C-05	REAL number	slow responder; scalar still flows within deadline
37	ultraslow_bi_enum	ultra_slow	Generic SlowGateway	600003	47818	480	binary-input	1	present-value	ENUMERATED	scalar	C-10	active/inactive enum	binary present-value as enum string
38	ultraslow_name_str	ultra_slow	Generic SlowGateway	600003	47818	480	analog-input	1	object-name	CHARACTER_STRING	scalar	C-09	bare CHARACTER_STRING	object-name on a slow device
39	empty_devid_oid	empty_device	Generic EmptyDevice	600004	47819	1476	device	600004	object-identifier	OBJECT_ID	scalar	C-11	OBJECT_ID {objectTypeName,objectInstance}	device responds though it owns no I/O objects
40	empty_objlist_zero	empty_device	Generic EmptyDevice	600004	47819	1476	device	600004	object-list	OBJECT_ID	array	F-01,A-11	array of just the device object (count ~1, no abort)	empty device: object-list fits 1476B, near-empty array
TSV

# ----- prerequisites + auth --------------------------------------------------
require_tools () {
  local c
  for c in curl jq base64; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found on PATH" >&2; exit 1; }
  done
}

login () {
  local token
  token=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
  [[ -n "$token" ]] || { echo "ERROR: Connectware auth failed at $API (user=$CW_USER)" >&2; exit 1; }
  printf '%s' "$token"
}

# auth <curl-args...> — authenticated curl; -L because GET /api/services 301s to /api/v2.
auth () { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }

scf_id ()    { printf '%s_%s' "$ID_PREFIX" "$1"; }            # final service id == metadata.name
EP_TOPIC=read                                                # endpoint resource id / topic, fixed
topic ()     { printf 'services/%s/%s' "$(scf_id "$1")" "$EP_TOPIC"; }  # services/<SCF id>/read

# ----- SCF rendering ---------------------------------------------------------
# Emit one connection + one endpoint SCF on stdout, following generate-scf.sh
# conventions (deviceInstance !ref, deviceAddress !sub, present-value/object-list
# endpoint, topic == resource id). metadata.name == the unique SCF id and the
# single endpoint topic is the fixed "${EP_TOPIC}", so the published subject is
# exactly services/<SCF id>/${EP_TOPIC} — globally unique, no cross-probe collision.
render_scf () {
  local scf_meta="$1" dev_id="$2" port="$3" obj_type="$4" obj_inst="$5" property="$6" interval="$7"
  cat <<YAML
# ${scf_meta} — single-endpoint read-spectrum probe (auto-generated by spectrum-deploy.sh)
# Device ${SIM_HOST}:${port} (DeviceID ${dev_id}) — reads ${obj_type}:${obj_inst} '${property}'.
description: |
  BACnet read-spectrum probe: ${obj_type}:${obj_inst} '${property}'.
metadata:
  name: ${scf_meta}
  provider: cybus
  version: 1.0.0
parameters:
  ipAddress:
    type: string
    default: '${SIM_HOST}'
  port:
    type: number
    default: ${port}
  Device_Instance:
    type: number
    default: ${dev_id}
resources:
  connection:
    type: Cybus::Connection
    properties:
      protocol: Bacnet
      targetState: connected
      connection:
        deviceInstance: !ref Device_Instance
        deviceAddress: !sub '\${ipAddress}:\${port}'
  ${EP_TOPIC}:
    type: Cybus::Endpoint
    properties:
      protocol: Bacnet
      connection: !ref connection
      topic: ${EP_TOPIC}
      subscribe:
        priority: 12
        interval: ${interval}
        property: ${property}
        objectType: ${obj_type}
        objectInstance: ${obj_inst}
YAML
}

# ----- service lifecycle (mirrors miele-mqtt-e2e.sh) -------------------------
deploy_one () { # deploy_one <id> <scf-yaml-on-stdin-via-file>
  local id="$1" file="$2"
  auth -X POST "$API/services" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$id\",\"commissioningFile\":\"$(base64 -w0 < "$file")\"}" >/dev/null
  auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' \
    -d '{"operation":"enable"}' >/dev/null
}

# Poll until the service reports enabled (bounded). Returns 0 enabled, 1 timed out.
wait_enabled () {
  local id="$1" state
  for _ in $(seq 1 30); do
    state=$(auth "$API/v2/services?pageSize=500" \
      | jq -r --arg id "$id" '.data[]? | select(.serviceId==$id) | .currentState' 2>/dev/null | head -1)
    [[ "$state" == "enabled" ]] && return 0
    sleep 1
  done
  return 1
}

# Every spectrum SCF id, derived purely from the CASES table.
spectrum_ids () {
  while IFS=$'\t' read -r n key _rest; do
    [[ -z "${n// }" ]] && continue
    scf_id "$key"
  done <<<"$CASES"
}

cleanup () {
  echo "==> cleanup: disabling + deleting every '${ID_PREFIX}_*' service"
  local id
  while read -r id; do
    [[ -z "$id" ]] && continue
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' \
      -d '{"operation":"disable"}' >/dev/null 2>&1 || true
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1 || true
  done < <(spectrum_ids)
  # bounded wait until all are 404 so a redeploy starts from a clean slate
  local pending
  for _ in $(seq 1 30); do
    pending=0
    while read -r id; do
      [[ -z "$id" ]] && continue
      [[ "$(auth -o /dev/null -w '%{http_code}' "$API/services/$id")" != "404" ]] && { pending=1; break; }
    done < <(spectrum_ids)
    [[ "$pending" -eq 0 ]] && break
    sleep 1
  done
  echo "    done"
}

# ----- the INDEX table (printed after deploy, or standalone via 'index') -----
COL='\033[36m'; BOLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
print_index () {
  echo ""
  echo -e "${BOLD}BACnet READ-SPECTRUM INDEX${RST}  (${ID_PREFIX}_* · present-value @ ${POLL_MS}ms · object-list @ ${OBJLIST_MS}ms)"
  echo -e "${DIM}Each row = one deployed SCF; verify with: e2e/spectrum-verify.sh${RST}"
  echo ""
  # header
  printf "${COL}%-3s %-26s %-20s %-8s %-22s %-18s %-10s %-7s %-16s %s${RST}\n" \
    "#" "SCF id" "device" "maxAPDU" "object:instance" "property" "datatype" "shape" "matrix-ID" "what it verifies"
  printf "${DIM}%s${RST}\n" "$(printf '%.0s-' {1..170})"
  local n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note
  while IFS=$'\t' read -r n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note; do
    [[ -z "${n// }" ]] && continue
    printf "%-3s %-26s %-20s %-8s %-22s %-18s %-10s %-7s %-16s %s\n" \
      "$n" "$(scf_id "$key")" "$device" "${max_apdu}B" \
      "${obj_type}:${obj_inst}" "$property" "$datatype" "$shape" "$matrix" "$expect — $note"
  done <<<"$CASES"
  echo ""
  echo -e "${BOLD}Topics${RST} (subscribe here / what spectrum-verify.sh reads):"
  while IFS=$'\t' read -r n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note; do
    [[ -z "${n// }" ]] && continue
    printf "  %-3s %-16s %s\n" "$n" "$matrix" "$(topic "$key")"
  done <<<"$CASES"
}

# ----- deploy driver ---------------------------------------------------------
# Script-scope tmpdir so cleanup survives `set -u` after the function returns (a
# `local` would be out of scope when the trap fires at exit). The EXIT trap is set
# only when run as a program (not when sourced as a lib by spectrum-verify.sh,
# which installs its own trap) — see the SPECTRUM_LIB guard near main.
SCF_TMPDIR=""

deploy_all () {
  require_tools
  TOKEN="$(login)"
  cleanup
  echo "==> deploying ${ID_PREFIX} read-spectrum SCFs onto ${API}"
  SCF_TMPDIR="$(mktemp -d "${DIR}/.spectrum-deploy.XXXXXX")"
  local tmpdir="$SCF_TMPDIR"

  local n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note
  local count=0 enabled=0 interval id file
  while IFS=$'\t' read -r n key profile device dev_id port max_apdu obj_type obj_inst property datatype shape matrix expect note; do
    [[ -z "${n// }" ]] && continue
    count=$((count + 1))
    [[ "$property" == "object-list" ]] && interval="$OBJLIST_MS" || interval="$POLL_MS"
    id="$(scf_id "$key")"
    file="${tmpdir}/${id}.yml"
    # metadata.name == id (unique); endpoint topic is the fixed EP_TOPIC, derived
    # identically by verify.sh → services/<id>/<EP_TOPIC>.
    render_scf "$id" "$dev_id" "$port" "$obj_type" "$obj_inst" "$property" "$interval" >"$file"
    deploy_one "$id" "$file"
    if wait_enabled "$id"; then
      enabled=$((enabled + 1))
      printf "  [%-2s] %-16s %-26s -> %s\n" "$n" "$matrix" "$id" "$(topic "$key")"
    else
      printf "  [%-2s] %-16s %-26s -> NOT ENABLED (check PM/service log)\n" "$n" "$matrix" "$id"
    fi
  done <<<"$CASES"

  echo ""
  echo "==> ${enabled}/${count} spectrum services enabled"
  print_index
  echo ""
  echo "Next: e2e/spectrum-verify.sh   (live-reads all ${count} topics and prints a PASS/FAIL table)"
}

usage () { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main () {
  case "${1:-deploy}" in
    deploy)        deploy_all ;;
    index)         print_index ;;
    cleanup)       require_tools; TOKEN="$(login)"; cleanup ;;
    -h|--help|help) usage ;;
    *) echo "unknown subcommand: $1" >&2; usage; exit 2 ;;
  esac
}

# When sourced as a library (SPECTRUM_LIB=1, used by spectrum-verify.sh) export the
# CASES table + id/topic helpers and do NOT run main — keeps ONE source of truth for
# the spectrum so deploy and verify can never drift apart.
[[ "${SPECTRUM_LIB:-0}" == 1 ]] && return 0

# Run-as-program: own the EXIT cleanup of the rendered-SCF tmpdir.
trap '[[ -n "$SCF_TMPDIR" ]] && rm -rf "$SCF_TMPDIR"' EXIT
main "$@"
