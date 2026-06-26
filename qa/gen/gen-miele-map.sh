#!/usr/bin/env bash
# Derive the Miele fleet map from the production SCFs and print it to stdout (TSV):
#   da  device  energy  power  id  ev  pv
# energy/power = SumRealEnergy/SumRealPower object instances (power/pv = "-" when
# that point is disabled). ev/pv = the UNIQUE STATIC presentValue the sim assigns
# that object = 40000 + device_index*1000 + instance, so a single reading pins
# exactly one (device,instance) — the basis for data-integrity verification.
# Single source of truth for gen-miele-profiles.sh and miele-mqtt-e2e.sh.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MIELE="${MIELE_DIR:-$(dirname "$DIR")/scf/miele}"
declare -A IDX=( [2098177]=0 [2098183]=1 [2098184]=2 [2098185]=3 )

pdef() { # default value of a top-level SCF param: pdef <file> <param>
  awk -v k="$2" '
    $0 ~ ("^  " k ":[[:space:]]*$") { f = 1; next }
    f && /default:/ { sub(/.*default:[[:space:]]*/, ""); print; exit }
    f && /^  [A-Za-z]/ { f = 0 }
  ' "$1"
}
val() { echo $(( 40000 + IDX["$1"] * 1000 + $2 )); } # val <device> <instance>

printf 'da\tdevice\tenergy\tpower\tid\tev\tpv\n'
for r in "$MIELE"/receive_services/*.yaml; do
  da=$(basename "$r" .yaml); da=${da##*_DA_115_}
  conn="$MIELE/connections/connection_bacnet_DA_115_${da}_Bacnet.yaml"
  dev=$(pdef "$conn" device_instance)
  energy=$(pdef "$r" SumRealEnergy); ev=$(val "$dev" "$energy")
  if [[ "$(pdef "$r" SumRealPowerState)" == "enabled" ]]; then
    power=$(pdef "$r" SumRealPower); pv=$(val "$dev" "$power")
  else
    power="-"; pv="-"
  fi
  id=$(pdef "$r" identifier_param | tr -d "\"'")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$da" "$dev" "$energy" "$power" "$id" "$ev" "$pv"
done
