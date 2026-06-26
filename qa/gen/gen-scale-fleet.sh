#!/usr/bin/env bash
# Generate a 32-device scale fleet for exact-integrity soak testing and print the
# full fleet map to stdout (TSV: da device energy power id ev pv kind):
#   - idx 0-3  : the 4 real Miele concentrators (real production SCFs)  [kind=real]
#   - idx 4-31 : 28 synthetic mixed-size meter devices                  [kind=synth]
# Every analog-input is STATIC and UNIQUELY valued: ev/pv = 40000 + idx*1000 +
# instance (float32-exact, globally unique) so any MQTT reading pins exactly one
# (device,instance). Side effects: writes the 28 synthetic sim profiles to
# profiles-cybus/ and scale-fleet.compose.yaml (synthetic services; the 4
# concentrators come from miele-fleet.compose.yaml).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
SYN_DEV=3000000; SYN_PORT=47880; SYN_METRICS=9180   # synthetic device_id/port/metrics = base + idx
VENDORS=(Siemens Trane JohnsonControls Carrier Tridium Honeywell Schneider ABB MBS Generic)  # mixed vendors

printf 'da\tdevice\tenergy\tpower\tid\tev\tpv\tkind\n'

# idx 0-3: real concentrators (from the real Miele SCFs)
"$DIR/gen-miele-map.sh" | tail -n +2 | while IFS=$'\t' read -r da dev energy power id ev pv; do
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\treal\n' "$da" "$dev" "$energy" "$power" "$id" "$ev" "$pv"
done

# idx 4-31: 28 synthetic mixed-size meters
syn_compose="services:"
for idx in $(seq 4 31); do
  dev=$(( SYN_DEV + idx )); port=$(( SYN_PORT + idx )); met=$(( SYN_METRICS + idx ))
  meters=$(( 1 + idx % 4 ))            # 1-4 meters per device (mixed sizes)
  vendor=${VENDORS[$(( idx % ${#VENDORS[@]} ))]}   # mixed vendor per device
  prof="$REPO/profiles-cybus/scale_synth_${dev}.yaml"
  {
    echo "# Synthetic scale meter $dev (idx $idx, $meters meters) — static unique values, exact-integrity"
    echo "extends: _base.yaml"
    echo "simulator:"; echo "  port: $port"; echo "  device_id: $dev"
    echo "device:"; echo "  vendor: $vendor"; echo "  vendor_name: \"$vendor\""; echo "  model_name: \"$vendor-Meter-$dev\""; echo "  protocol_revision: 22"
    echo "network:"; echo "  max_apdu: 1476"; echo "  segmentation: noSegmentation"
    echo "realism:"; echo "  drift_pct: 0"
    echo "objects:"
    for r in $(seq 0 $(( meters - 1 ))); do
      e=$(( 2 * r )); p=$(( 2 * r + 1 ))
      printf '  - { object_type: AnalogInput, instance: %s, name: AnalogInput_%s, units: kilowattHours, default: %s.0 }\n' "$e" "$e" "$(( 40000 + idx * 1000 + e ))"
      printf '  - { object_type: AnalogInput, instance: %s, name: AnalogInput_%s, units: kilowattHours, default: %s.0 }\n' "$p" "$p" "$(( 40000 + idx * 1000 + p ))"
    done
  } > "$prof"
  for r in $(seq 0 $(( meters - 1 ))); do
    e=$(( 2 * r )); p=$(( 2 * r + 1 ))
    printf 'SYN%02d_%d\t%s\t%s\t%s\tSYN%02d_%d\t%s\t%s\tsynth\n' \
      "$idx" "$r" "$dev" "$e" "$p" "$idx" "$r" "$(( 40000 + idx*1000 + e ))" "$(( 40000 + idx*1000 + p ))"
  done
  syn_compose="$syn_compose
  bacnet-scale-synth-${dev}:
    build: ${REPO}
    network_mode: host
    environment:
      BACNET_PROFILES_DIR: /app/profiles
      BACNET_METRICS_PORT: \"${met}\"
    volumes:
      - ${REPO}/profiles-cybus/scale_synth_${dev}.yaml:/app/profiles/scale_synth_${dev}.yaml:ro
      - ${REPO}/profiles/_base.yaml:/app/profiles/_base.yaml:ro
      - ${REPO}/profiles/vendors.yaml:/app/profiles/vendors.yaml:ro"
done
echo "$syn_compose" > "$REPO/compose/scale-fleet.compose.yaml"
