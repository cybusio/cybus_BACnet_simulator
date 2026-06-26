#!/usr/bin/env bash
# Clean slate: disable + delete EVERY service on a running Connectware.
#   qa/tools/cw-clean-all.sh
# The CW services list paginates (and has duplicate-page quirks), so this drains
# in passes — list the visible services, delete them, repeat until empty.
# Env: CW_HOST (localhost) · CW_USER/CW_PASS (admin)
set -uo pipefail
CW_HOST="${CW_HOST:-localhost}"; CW_USER="${CW_USER:-admin}"; CW_PASS="${CW_PASS:-admin}"
API="https://${CW_HOST}/api"
for c in curl jq; do command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }; done

TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$CW_USER\",\"password\":\"$CW_PASS\"}" | jq -r '.token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: auth failed at $API" >&2; exit 1; }
auth() { curl -skL -H "Authorization: Bearer $TOKEN" "$@"; }  # -L: GET /api/services 301s to /api/v2

total=0
for pass in $(seq 1 20); do
  ids=$(auth "$API/services" | jq -r '.data[].serviceId' | sort -u)
  [[ -z "$ids" ]] && break
  for id in $ids; do
    auth -X PUT "$API/services/$id/operation" -H 'Content-Type: application/json' -d '{"operation":"disable"}' >/dev/null 2>&1
    auth -X DELETE "$API/services/$id" >/dev/null 2>&1
    echo "  removed $id"
    total=$(( total + 1 ))
  done
  sleep 3
done
left=$(auth "$API/services" | jq -r '.meta.pagination.totalRows // (.data | length)')
echo "clean-slate done — removed $total, services remaining: $left"
[[ "$left" == "0" ]]
