#!/usr/bin/env bash
# Generate a Connectware SCF (Service Commissioning File) from a simulator profile.
#
# The profile YAML is the single source of truth — port, device ID, objects, and
# network constraints are all read from it. Constrained devices (noSegmentation,
# small max_apdu) automatically get maxApdu/segmentation overrides in the SCF.
# If endpoint count exceeds the profile's base objects, realistic domain-specific
# objects are generated using the profile's padding template.
#
# Output: scf/<name>.yml — ready to upload to Connectware UI or CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON="${PYTHON:-${REPO_DIR}/.venv/bin/python3}"

if [[ $# -lt 2 ]]; then
  cat <<'USAGE'
Usage: ./scripts/generate-scf.sh <ip> <profile.yaml> [name] [endpoints] [poll-interval] [use-overrides]

  ip              Simulator IP as seen by the protocol-mapper container (e.g., 172.18.0.1)
  profile.yaml    Simulator profile (in profiles-cybus/)
  name            SCF service name (default: profile filename without extension)
  endpoints       Target endpoint count (0 = all profile objects, >0 = scale with padding)
  poll-interval   How often CW polls each endpoint in ms (default: 1000)
  use-overrides   Whether to enable maxApdu/segmentation overrides (true/false, default: false)

Examples:
  ./scripts/generate-scf.sh 192.168.1.100 profiles-cybus/newlift_gateway.yaml
  ./scripts/generate-scf.sh 192.168.1.100 profiles-cybus/legacy_controller.yaml legacy-1 0 1000 true
  ./scripts/generate-scf.sh 192.168.1.100 profiles-cybus/newlift_gateway.yaml newlift-2000 2000
  ./scripts/generate-scf.sh 192.168.1.100 profiles-cybus/miele_energy_meter.yaml miele-5000 5000
  ./scripts/generate-scf.sh 192.168.1.100 profiles-cybus/modern_controller.yaml modern-1000 1000 2000

  # All profiles at default size
  for f in profiles-cybus/*.yaml; do
    ./scripts/generate-scf.sh 192.168.1.100 "$f"
  done
USAGE
  exit 1
fi

IP="$1"
PROFILE="$2"
NAME="${3:-$(basename "$PROFILE" .yaml)}"
ENDPOINTS="${4:-0}"
INTERVAL="${5:-1000}"
USE_OVERRIDES="${6:-false}"

[[ ! -f "$PROFILE" ]] && echo "ERROR: Profile not found: $PROFILE" >&2 && exit 1

mkdir -p "${REPO_DIR}/scf"
OUTPUT="${REPO_DIR}/scf/${NAME}.yml"

# Use the simulator's padding generator for scaling
PYTHONPATH="${REPO_DIR}/src" "$PYTHON" - "$IP" "$PROFILE" "$NAME" "$ENDPOINTS" "$INTERVAL" "$USE_OVERRIDES" << 'PYEOF' > "$OUTPUT"
import sys, os, yaml

ip = sys.argv[1]
profile_path = os.path.abspath(sys.argv[2])
name = sys.argv[3]
target = int(sys.argv[4])
interval = int(sys.argv[5])
use_overrides_arg = sys.argv[6].lower() == 'true'

def load(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}

def merge(base, over):
    result = {}
    for key in set(base) | set(over):
        if key == 'extends':
            continue
        b, o = base.get(key), over.get(key)
        if isinstance(b, dict) and isinstance(o, dict):
            result[key] = merge(b, o)
        elif o is not None:
            result[key] = o
        elif b is not None:
            result[key] = b
    return result

def resolve(path):
    raw = load(path)
    extends = raw.get('extends', '_base.yaml')
    parent_dir = os.path.dirname(path)
    base_path = os.path.join(parent_dir, extends)
    if not os.path.exists(base_path):
        # Search sibling directories (profiles/ for _base.yaml)
        for d in [os.path.join(os.path.dirname(parent_dir), 'profiles'),
                  os.path.join(parent_dir, '_parents')]:
            candidate = os.path.join(d, extends)
            if os.path.exists(candidate):
                base_path = candidate
                break
    if extends == '_base.yaml':
        base = load(base_path) if os.path.exists(base_path) else {}
    else:
        base = resolve(base_path)
    return merge(base, raw)

profile = resolve(profile_path)

sim = profile.get('simulator', {})
port = sim.get('port', 47808)
dev_id = sim.get('device_id', 100)
net = profile.get('network', {})
max_apdu = net.get('max_apdu', 1476)
segmentation = net.get('segmentation', 'segmentedBoth')
objects = profile.get('objects', []) or []

# Scale with padding if target > base objects
if target > len(objects):
    # Find the padding template from the profile text
    with open(profile_path) as f:
        text = f.read()
    template = None
    for line in text.splitlines():
        stripped = line.strip().lstrip('#').strip()
        if stripped.startswith('template:'):
            template = stripped.split(':')[1].strip().split()[0]
            break
    # If chained profile has no template, check parent
    if not template:
        raw = load(profile_path)
        extends = raw.get('extends', '_base.yaml')
        if extends != '_base.yaml':
            parent_path = os.path.join(os.path.dirname(profile_path), extends)
            if os.path.exists(parent_path):
                with open(parent_path) as f:
                    for line in f:
                        stripped = line.strip().lstrip('#').strip()
                        if stripped.startswith('template:'):
                            template = stripped.split(':')[1].strip().split()[0]
                            break

    if template:
        from bacnet_sim.profiles import _generate_padding
        pad_count = target - len(objects)
        padding = _generate_padding(template, pad_count, objects)
        objects = objects + [{'object_type': p.object_type, 'instance': p.instance,
                              'name': p.name} for p in padding]
        print(f"NOTE: SCF has {len(objects)} endpoints ({pad_count} padded). "
              f"Simulator must be started with BACNET_OBJECT_PADDING={pad_count} "
              f"to serve these objects.", file=sys.stderr)
    else:
        print(f"WARNING: No padding template found, using {len(objects)} base objects",
              file=sys.stderr)

# Derive SCF connection overrides
overrides = {}
if segmentation == 'noSegmentation':
    overrides['segmentation'] = 'no-segmentation'
else:
    overrides['segmentation'] = 'segmented-both'

if max_apdu < 1476:
    overrides['maxApdu'] = max_apdu
else:
    overrides['maxApdu'] = 1476

ABBREV = {
    'AnalogInput': 'AI', 'AnalogOutput': 'AO', 'AnalogValue': 'AV',
    'BinaryInput': 'BI', 'BinaryOutput': 'BO', 'BinaryValue': 'BV',
    'MultiStateInput': 'MI', 'MultiStateOutput': 'MO', 'MultiStateValue': 'MV',
}
SCF_TYPE = {
    'AnalogInput': 'analog-input', 'AnalogOutput': 'analog-output', 'AnalogValue': 'analog-value',
    'BinaryInput': 'binary-input', 'BinaryOutput': 'binary-output', 'BinaryValue': 'binary-value',
    'MultiStateInput': 'multi-state-input', 'MultiStateOutput': 'multi-state-output',
    'MultiStateValue': 'multi-state-value',
}

o = []
o.append(f'# {"—" * 76}')
o.append(f'# Commissioning File — {name}')
o.append(f'# {"—" * 76}')
o.append(f'# Profile: {os.path.basename(profile_path)}')
o.append(f'# Device:  {ip}:{port} (DeviceID {dev_id}), {len(objects)} endpoints')
o.append(f'# {"—" * 76}')
o.append(f'description: |')
o.append(f'  BACnet {name} — {len(objects)} endpoints at {interval}ms poll interval.')
o.append(f'')
o.append(f'metadata:')
o.append(f'  name: {name}')
o.append(f'  provider: cybus')
o.append(f'  version: 1.0.0')
o.append(f'')
o.append(f'parameters:')
o.append(f'  ipAddress:')
o.append(f'    type: string')
o.append(f"    default: '{ip}'")
o.append(f'  port:')
o.append(f'    type: number')
o.append(f'    default: {port}')
o.append(f'  Device_Instance:')
o.append(f'    type: number')
o.append(f'    default: {dev_id}')
if use_overrides_arg:
    o.append(f'  maxApdu:')
    o.append(f'    type: number')
    o.append(f'    default: {overrides["maxApdu"]}')
    o.append(f'  segmentation:')
    o.append(f'    type: string')
    o.append(f"    default: '{overrides['segmentation']}'")
o.append(f'')
o.append(f'resources:')
o.append(f'')
o.append(f'  connection:')
o.append(f'    type: Cybus::Connection')
o.append(f'    properties:')
o.append(f'      protocol: Bacnet')
o.append(f'      targetState: connected')
o.append(f'      connection:')
o.append(f"        deviceInstance: !ref Device_Instance")
o.append(f"        deviceAddress: !sub '${{ipAddress}}:${{port}}'")
if use_overrides_arg:
    o.append(f"        maxApdu: !ref maxApdu")
    o.append(f"        segmentation: !ref segmentation")

for obj in objects:
    obj_type = obj.get('object_type', obj.get('objectType', ''))
    abbr = ABBREV.get(obj_type, obj_type[:2].upper())
    scf_type = SCF_TYPE.get(obj_type, obj_type.lower())
    inst = obj.get('instance', 0)
    res_id = f'{abbr}{inst}'

    o.append(f'')
    o.append(f'  {res_id}:')
    o.append(f'    type: Cybus::Endpoint')
    o.append(f'    properties:')
    o.append(f'      protocol: Bacnet')
    o.append(f'      connection: !ref connection')
    o.append(f'      topic: {res_id}')
    o.append(f'      subscribe:')
    o.append(f'        priority: 12')
    o.append(f'        interval: {interval}')
    o.append(f'        property: present-value')
    o.append(f'        objectType: {scf_type}')
    o.append(f'        objectInstance: {inst}')

print('\n'.join(o))
PYEOF

EP_COUNT=$(grep -c 'Cybus::Endpoint' "$OUTPUT")
echo "Generated: $OUTPUT ($EP_COUNT endpoints)"
