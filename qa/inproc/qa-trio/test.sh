#!/usr/bin/env bash
# QA trio runner — runs the realism + factory-storm + qa-simulator test files
# against the BACnet protocol adapter living in a sibling protocol-mapper repo.
# Requires the multi-device BACnet simulator stack to be up.
#
# Usage:
#   PM_ROOT=/path/to/protocol-mapper ./test.sh
# Defaults PM_ROOT to ../../CW/CW_2.x/cybus/protocol-mapper relative to this
# repo (the dev layout).

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SIM_REPO=$(cd "$SCRIPT_DIR/../../.." && pwd)   # qa/inproc/qa-trio -> repo root
export PM_ROOT="${PM_ROOT:-$SIM_REPO/../../CW/CW_2.x/cybus/protocol-mapper}"

if [ ! -f "$PM_ROOT/src/protocols/bacnet/BacnetConnection.js" ]; then
  echo "[qa-trio] ERROR: protocol-mapper not found at $PM_ROOT"
  echo "[qa-trio]        set PM_ROOT to the adapter repo root"
  exit 2
fi

probe_simulator() {
  docker ps --filter "name=bacnet_simulator" --format '{{.Names}}' 2>/dev/null \
    | grep -q '^bacnet_simulator-'
}

if ! probe_simulator; then
  echo "[qa-trio] SKIP: no bacnet_simulator-* container running"
  echo "[qa-trio] SKIP: start it via 'cd $SIM_REPO && docker compose up -d --build'"
  exit 0
fi

cd "$PM_ROOT"
export NODE_CONFIG_DIR="${NODE_CONFIG_DIR:-$PM_ROOT/config}"
export NODE_ENV="${NODE_ENV:-test}"
NODE_BIN="${NODE_BIN:-node}"
NYC_ARGS="${NYC_ARGS:-}"
RUN="${NYC_ARGS} ${NODE_BIN} --require $PM_ROOT/src/protocols/bacnet/test/qa-loader.js"

OVERALL=0
for script in connection-realism-test factory-storm-test qa-simulator-test caveat-boundaries-test; do
  echo "[qa-trio] === ${script} ==="
  # shellcheck disable=SC2086
  ${RUN} "$SCRIPT_DIR/${script}.js"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[qa-trio] FAIL: ${script} exited $rc"
    OVERALL=1
  fi
done

# Extended suites — each needs an opt-in device (cert/production/scale composes).
# Run when the device is present; SKIP cleanly otherwise so the core run is portable.
device_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$1"; }
run_ext() { # $1 = test script, $2 = required container substring
  if device_up "$2"; then
    echo "[qa-trio] === $1 ==="
    # shellcheck disable=SC2086
    ${RUN} "$SCRIPT_DIR/$1.js" || { echo "[qa-trio] FAIL: $1"; OVERALL=1; }
  else
    echo "[qa-trio] SKIP: $1 (device '$2' not running)"
  fi
}
run_ext cert-matrix-test      bacnet-modern
run_ext miele-scenario-test   bacnet-miele-1
run_ext miele-load-test       bacnet-miele-1
run_ext miele-production-test bacnet-miele-real
run_ext weatherstation-test   bacnet-weatherstation-1
run_ext reconnect-test        bacnet-reconnect-target
run_ext cadence-test          bacnet-miele-clone-001
run_ext scale-fleet-test      bacnet-miele-clone-019
run_ext scale-integrity-test  bacnet-miele-clone-019
run_ext mega-scale-test       bacnet-mega-b
run_ext cov-hybrid-test       pxc100-cov

exit $OVERALL
