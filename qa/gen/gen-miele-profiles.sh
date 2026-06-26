#!/usr/bin/env bash
# Generate the 4 Miele concentrator sim profiles + miele-fleet.compose.yaml from
# the fleet map (gen-miele-map.sh). Each concentrator exposes one AnalogInput per
# SumRealEnergy/SumRealPower instance its meters read, with a UNIQUE STATIC
# presentValue (realism.drift_pct: 0) = 40000+device_index*1000+instance — so each
# MQTT reading pins exactly one (device,instance) for data-integrity verification.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
MAP="$("$DIR/gen-miele-map.sh")"
declare -A PORT=( [2098177]=47870 [2098183]=47871 [2098184]=47872 [2098185]=47873 )
declare -A METRICS=( [2098177]=9170 [2098183]=9171 [2098184]=9172 [2098185]=9173 )

COMPOSE="$REPO/compose/miele-fleet.compose.yaml"
echo "services:" > "$COMPOSE"
for dev in $(printf '%s\n' "${!PORT[@]}" | sort); do
  # unique (instance, value) objects: energy on every row, power where enabled
  objs=$(awk -F'\t' -v d="$dev" 'NR>1 && $2==d { print $3"\t"$6; if ($4 != "-") print $4"\t"$7 }' <<<"$MAP" | sort -n | awk '!seen[$1]++')
  prof="$REPO/profiles-cybus/miele_concentrator_${dev}.yaml"
  {
    echo "# Miele concentrator $dev — SumRealEnergy + SumRealPower analog-inputs, unique static values (integrity-verifiable)"
    echo "extends: _base.yaml"
    echo "simulator:"
    echo "  port: ${PORT[$dev]}"
    echo "  device_id: $dev"
    echo "device:"
    echo "  vendor: MIELE"
    echo "  vendor_name: \"Miele\""
    echo "  model_name: \"Miele-Concentrator-$dev\""
    echo "  protocol_revision: 22"
    echo "network:"
    echo "  max_apdu: 1476"
    echo "  segmentation: noSegmentation"
    echo "realism:"
    echo "  drift_pct: 0   # static presentValue per object -> exact data-integrity verification"
    echo "objects:"
    while IFS=$'\t' read -r inst v; do
      [[ -z "$inst" ]] && continue
      printf '  - { object_type: AnalogInput, instance: %s, name: AnalogInput_%s, units: kilowattHours, default: %s.0 }\n' "$inst" "$inst" "$v"
    done <<<"$objs"
  } > "$prof"
  cat >> "$COMPOSE" <<EOF
  bacnet-miele-conc-${dev}:
    build: ${REPO}
    network_mode: host
    environment:
      BACNET_PROFILES_DIR: /app/profiles
      BACNET_METRICS_PORT: "${METRICS[$dev]}"
    volumes:
      - ${REPO}/profiles-cybus/miele_concentrator_${dev}.yaml:/app/profiles/miele_concentrator_${dev}.yaml:ro
      - ${REPO}/profiles/_base.yaml:/app/profiles/_base.yaml:ro
      - ${REPO}/profiles/vendors.yaml:/app/profiles/vendors.yaml:ro
EOF
done
echo "generated 4 concentrator profiles (static, unique values) + $(basename "$COMPOSE")"
