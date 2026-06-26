#!/usr/bin/env bash
# Functional large object-list recovery: deploy zz_objectlist against the huge sim
# (1001 objects = 100 base + device + 900 padding), verify the full array flows
# through MQTT intact and recovers from the size-abort.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$(dirname "$DIR")")"
SCF="$REPO/qa/scf/zz_objectlist.yml"
API="https://localhost/api"; PM=platform-protocol-mapper-1
SIM="${SIM:-172.18.0.1}"; PORT="${PORT:-47860}"; DEV="${DEV:-2000100}"; ID=funcarr
# huge_controller object-list: 100 base objects + 1 device object + 900 padding = 1001.
# Floor just below the exact count catches the 101-of-1000 truncation false-pass.
MIN_OBJS="${MIN_OBJS:-1000}"
TOK=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' | jq -r '.token//empty')
[ -n "$TOK" ] || { echo "RESULT: FAIL (auth)"; exit 1; }
auth(){ curl -skL -H "Authorization: Bearer $TOK" "$@"; }
cleanup(){ auth -X PUT "$API/services/$ID/operation" -d '{"operation":"disable"}' >/dev/null 2>&1
  auth -X DELETE "$API/services/$ID" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
docker inspect "$PM" >/dev/null 2>&1 || { echo "RESULT: FAIL (PM container $PM not found)"; exit 1; }
auth -X DELETE "$API/services/$ID" >/dev/null 2>&1; sleep 1
auth -X POST "$API/services" -H 'Content-Type: application/json' \
  -d "{\"id\":\"$ID\",\"commissioningFile\":\"$(base64 -w0 <"$SCF")\",\"parameters\":{\"ipAddress\":\"$SIM\",\"port\":$PORT,\"Device_Instance\":$DEV}}" >/dev/null
auth -X PUT "$API/services/$ID/operation" -H 'Content-Type: application/json' -d '{"operation":"enable"}' >/dev/null
sleep 20
cap=$(timeout 12 mosquitto_sub -h localhost -p 1883 -u admin -P admin -R -t "services/$ID/objectList" -F '%p' 2>/dev/null | tail -1)
val=$(jq -c '.value' <<<"$cap" 2>/dev/null || echo null)
# Strict integrity, not just length: the recovered array must be exactly as long as
# it is UNIQUE (no chunk overlap/dup) and WELL-FORMED (every element a typed
# object-id). A truncated, duplicated, or garbage array of the right length all fail.
len=$(jq -r 'if type=="array" then length else 0 end' <<<"$val" 2>/dev/null || echo 0)
uniq=$(jq -r 'if type=="array" then (unique | length) else 0 end' <<<"$val" 2>/dev/null || echo 0)
wf=$(jq -r 'if type=="array" then ([.[] | select(.objectTypeName != null and .objectInstance != null)] | length) else 0 end' <<<"$val" 2>/dev/null || echo 0)
LOG=$(docker logs --since 35s "$PM" 2>&1)
crash=$(grep -ciE "unhandledrejection|uncaught|fatal" <<<"$LOG" || true)
echo "object-list len=$len unique=$uniq well-formed=$wf  (expect len>=$MIN_OBJS, unique==len, well-formed==len; crash=$crash)"
if [ "$len" -ge "$MIN_OBJS" ] && [ "$uniq" -eq "$len" ] && [ "$wf" -eq "$len" ] && [ "$crash" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL (len=$len unique=$uniq well-formed=$wf crash=$crash)"; exit 1
fi
