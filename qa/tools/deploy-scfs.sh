#!/usr/bin/env bash
# Deploy all generated SCFs to a Connectware 2.x instance.
#
# Usage:
#   ./qa/tools/deploy-scfs.sh <cw-host>
#   ./qa/tools/deploy-scfs.sh <cw-host> scf/modern_controller.yml   # single SCF
#   CW_USER=admin CW_PASS=admin ./qa/tools/deploy-scfs.sh <cw-host>
#
# Prerequisites:
#   - SCFs generated: ./qa/tools/generate-scf.sh <sim-ip> --all
#   - curl and jq installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SCF_DIR="${REPO_DIR}/qa/scf"

CW_USER="${CW_USER:-admin}"
CW_PASS="${CW_PASS:-admin}"
CW_PORT="${CW_PORT:-443}"

if [[ $# -lt 1 ]]; then
  echo "Usage: ./qa/tools/deploy-scfs.sh <cw-host> [scf-file]"
  echo ""
  echo "  Deploys all SCFs in scf/ (or a single file) to Connectware."
  echo ""
  echo "Environment:"
  echo "  CW_USER   Connectware username (default: admin)"
  echo "  CW_PASS   Connectware password (default: admin)"
  echo "  CW_PORT   Connectware HTTPS port (default: 443)"
  exit 1
fi

CW_HOST="$1"
BASE_URL="https://${CW_HOST}:${CW_PORT}/api"

# Require curl and jq
for cmd in curl jq; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

# Step 1: Authenticate
echo "Authenticating to ${CW_HOST}..."
TOKEN=$(curl -sk -X POST "${BASE_URL}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${CW_USER}\",\"password\":\"${CW_PASS}\"}" \
  | jq -r '.token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to authenticate. Check CW_USER/CW_PASS." >&2
  exit 1
fi
echo "  Authenticated."

# Step 2: Build file list
if [[ -n "${2:-}" ]]; then
  FILES=("$2")
else
  FILES=("${SCF_DIR}"/*.yml)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: No SCF files found in ${SCF_DIR}/. Run generate-scf.sh --all first." >&2
  exit 1
fi

# Step 3: Deploy each SCF
PASS=0; FAIL=0; SKIP=0

for scf_file in "${FILES[@]}"; do
  [[ ! -f "$scf_file" ]] && continue
  name=$(basename "$scf_file" .yml)

  # Base64-encode the SCF
  scf_b64=$(base64 -w0 < "$scf_file")

  # Check if service already exists (follow redirects)
  status=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/services/${name}")

  if [[ "$status" == "200" ]]; then
    # Service exists — disable then delete
    echo "  ${name}: exists, removing..."
    curl -sk -X PUT \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"operation":"disable"}' \
      "${BASE_URL}/services/${name}/operation" > /dev/null 2>&1
    sleep 2
    curl -sk -X DELETE \
      -H "Authorization: Bearer ${TOKEN}" \
      "${BASE_URL}/services/${name}" > /dev/null 2>&1
    # Wait for deletion to complete
    for i in $(seq 1 30); do
      s=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${BASE_URL}/services/${name}")
      [[ "$s" == "404" ]] && break
      sleep 1
    done
  fi

  # Deploy (follow redirects)
  response=$(curl -sk -X POST "${BASE_URL}/services" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"id\": \"${name}\",
      \"commissioningFile\": \"${scf_b64}\",
      \"parameters\": {},
      \"targetState\": \"enabled\"
    }" -w "\n%{http_code}" 2>&1)

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  case "$http_code" in
    201)
      # 201 only means accepted — poll until it actually commissions to enabled,
      # else a service that uploads then fails to connect would count as a pass.
      state=""
      for _ in $(seq 1 40); do
        state=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
          "${BASE_URL}/v2/services?pageSize=500" \
          | jq -r --arg id "$name" '[.data[]|select(.serviceId==$id)][0].currentState // ""' 2>/dev/null)
        [[ "$state" == "enabled" ]] && break
        sleep 1
      done
      if [[ "$state" == "enabled" ]]; then
        echo "  ${name}: deployed + enabled (${http_code})"
        PASS=$((PASS + 1))
      else
        echo "  ${name}: FAIL — uploaded (${http_code}) but never reached enabled (state=${state:-unknown})" >&2
        FAIL=$((FAIL + 1))
      fi
      ;;
    409)
      echo "  ${name}: SKIP — conflict (still deleting?)" >&2
      SKIP=$((SKIP + 1))
      ;;
    ""|000)
      echo "  ${name}: FAIL — no HTTP response from ${CW_HOST} (connection error)" >&2
      FAIL=$((FAIL + 1))
      ;;
    *)
      err=$(echo "$body" | jq -r '.message // .error // "unknown"' 2>/dev/null || echo "$body")
      echo "  ${name}: FAIL (${http_code}) — ${err}" >&2
      FAIL=$((FAIL + 1))
      ;;
  esac
done

echo ""
echo "Done: ${PASS} deployed, ${SKIP} skipped, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
