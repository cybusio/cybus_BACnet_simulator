#!/usr/bin/env bash
# Generate N writable R/W devices for round-trip soak testing: each exposes a
# writable AnalogValue (REAL), MultiStateValue (UNSIGNED) and BinaryValue (BOOL),
# static (drift_pct:0) so a read-back reflects exactly the last write. Writes the
# profiles to profiles-cybus/ and rw-fleet.compose.yaml. Env: N (default 32).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$DIR")")"
N="${N:-32}"; BASE_DEV=4000000; BASE_PORT=47950; BASE_MET=9250

echo "services:" > "$REPO/compose/rw-fleet.compose.yaml"
for i in $(seq 0 $(( N - 1 ))); do
  dev=$(( BASE_DEV + i )); port=$(( BASE_PORT + i )); met=$(( BASE_MET + i ))
  cat > "$REPO/profiles-cybus/rw_dev_${dev}.yaml" <<EOF
# R/W device $dev — writable AnalogValue(REAL)/MultiStateValue(UINT)/BinaryValue(BOOL), static
extends: _base.yaml
simulator:
  port: $port
  device_id: $dev
device:
  vendor: MIELE
  vendor_name: "Miele"
  model_name: "RW-Dev-$dev"
  protocol_revision: 22
network:
  max_apdu: 1476
  segmentation: noSegmentation
realism:
  drift_pct: 0
objects:
  - { object_type: AnalogValue, instance: 0, name: AV_0, units: kilowattHours, default: 0.0 }
  - { object_type: MultiStateValue, instance: 0, name: MV_0, default: 1 }
  - { object_type: BinaryValue, instance: 0, name: BV_0, default: 0 }
EOF
  cat >> "$REPO/compose/rw-fleet.compose.yaml" <<EOF
  bacnet-rw-dev-${dev}:
    build: ${REPO}
    network_mode: host
    environment:
      BACNET_PROFILES_DIR: /app/profiles
      BACNET_METRICS_PORT: "${met}"
    volumes:
      - ${REPO}/profiles-cybus/rw_dev_${dev}.yaml:/app/profiles/rw_dev_${dev}.yaml:ro
      - ${REPO}/profiles/_base.yaml:/app/profiles/_base.yaml:ro
      - ${REPO}/profiles/vendors.yaml:/app/profiles/vendors.yaml:ro
EOF
done
echo "generated $N R/W device profiles + compose/rw-fleet.compose.yaml"
