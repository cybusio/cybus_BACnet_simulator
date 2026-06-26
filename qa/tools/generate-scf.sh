#!/usr/bin/env bash
# Generate a Connectware SCF (Service Commissioning File) from a simulator profile.
#
# The profile YAML is the single source of truth — port, device ID, objects, and
# network constraints are all read from it. RPM auto-detects device capabilities,
# so no maxApdu/segmentation overrides are emitted.
# If endpoint count exceeds the profile's base objects, realistic domain-specific
# objects are generated using the profile's padding template.
#
# Output: scf/<name>.yml — ready to upload to Connectware UI or CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"   # qa/tools -> repo root
PYTHON="${PYTHON:-${REPO_DIR}/.venv/bin/python3}"

if [[ $# -lt 1 ]]; then
  cat <<'USAGE'
Usage: ./qa/tools/generate-scf.sh <ip> --all
       ./qa/tools/generate-scf.sh <ip> <profile.yaml> [name] [endpoints] [poll-interval]

  ip              Simulator IP as seen by the protocol-mapper container (e.g., 172.18.0.1)
  --all           Generate SCFs for all profiles in profiles-cybus/
  profile.yaml    Simulator profile (in profiles-cybus/)
  name            SCF service name (default: profile filename without extension)
  endpoints       Target endpoint count (0 = all profile objects, >0 = scale with padding)
  poll-interval   How often CW polls each endpoint in ms (default: 1000)

The generator reads the profile and automatically:
- Emits both deviceInstance + deviceAddress (schema requires both)
- Adds an object-list endpoint for constrained devices where it tests Tier 3 fallback

Examples:
  ./qa/tools/generate-scf.sh 192.168.1.100 --all
  ./qa/tools/generate-scf.sh 192.168.1.100 profiles-cybus/newlift_gateway.yaml
  ./qa/tools/generate-scf.sh 192.168.1.100 profiles-cybus/miele_energy_meter.yaml miele-5000 5000
USAGE
  exit 1
fi

IP="$1"

# --all: generate SCFs for every profile
if [[ "${2:-}" == "--all" ]]; then
  for f in "${REPO_DIR}"/profiles-cybus/*.yaml; do
    "$0" "$IP" "$f"
  done
  exit 0
fi

if [[ $# -lt 2 ]]; then
  echo "ERROR: Missing profile argument. Use --all or specify a profile." >&2
  exit 1
fi

PROFILE="$2"
NAME="${3:-$(basename "$PROFILE" .yaml)}"
ENDPOINTS="${4:-0}"
INTERVAL="${5:-1000}"

[[ ! -f "$PROFILE" ]] && echo "ERROR: Profile not found: $PROFILE" >&2 && exit 1

mkdir -p "${REPO_DIR}/qa/scf"
OUTPUT="${REPO_DIR}/qa/scf/${NAME}.yml"

# Use the simulator's padding generator for scaling
PYTHONPATH="${REPO_DIR}/src" "$PYTHON" - "$IP" "$PROFILE" "$NAME" "$ENDPOINTS" "$INTERVAL" << 'PYEOF' > "$OUTPUT"
import sys, os, yaml

ip = sys.argv[1]
profile_path = os.path.abspath(sys.argv[2])
name = sys.argv[3]
target = int(sys.argv[4])
interval = int(sys.argv[5])

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

# RPM auto-detects device capabilities — no schema overrides needed
overrides = {}

# Slow devices need a longer apduTimeoutMs. This is the ONLY liveness knob accepted
# by the adapter schema — apduRetries and healthTracking are no longer allowed.
# Adapter rule: HEALTHY ⟺ matched response within apduTimeoutMs × 3.
realism = profile.get('realism', {})
delay_ms = realism.get('response_delay_ms', 0)
if delay_ms >= 10000:
    # Device responds slower than default 3000ms — set apduTimeoutMs so
    # the × 3 health window comfortably covers the response time.
    overrides['apduTimeoutMs'] = max(delay_ms + 3000, 15000)

ABBREV = {
    'AnalogInput': 'AI', 'AnalogOutput': 'AO', 'AnalogValue': 'AV',
    'BinaryInput': 'BI', 'BinaryOutput': 'BO', 'BinaryValue': 'BV',
    'MultiStateInput': 'MI', 'MultiStateOutput': 'MO', 'MultiStateValue': 'MV',
    'NotificationClass': 'NO',
}
SCF_TYPE = {
    'AnalogInput': 'analog-input', 'AnalogOutput': 'analog-output', 'AnalogValue': 'analog-value',
    'BinaryInput': 'binary-input', 'BinaryOutput': 'binary-output', 'BinaryValue': 'binary-value',
    'MultiStateInput': 'multi-state-input', 'MultiStateOutput': 'multi-state-output',
    'MultiStateValue': 'multi-state-value', 'NotificationClass': 'notification-class',
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
for k, v in overrides.items():
    val = "'{}'".format(v) if isinstance(v, str) else v
    o.append('        {}: {}'.format(k, val))

# Object types that lack a pollable present-value property
SKIP_TYPES = {'NotificationClass'}

# Commandable types get an MQTT->BACnet write endpoint (<id>cmd/set) when
# WRITABLE_ENDPOINTS=1, making the SCF bidirectional. Default off (read-only).
COMMANDABLE_TYPES = {'analog-output', 'analog-value', 'binary-output',
                     'binary-value', 'multi-state-output', 'multi-state-value'}
WRITE_COMMANDABLE = os.environ.get('WRITABLE_ENDPOINTS') == '1'

for obj in objects:
    obj_type = obj.get('object_type', obj.get('objectType', ''))
    if obj_type in SKIP_TYPES:
        continue
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

    # Commandable point also gets a write endpoint: publishing to
    # <id>cmd/set writes present-value via BACnet WriteProperty (MQTT round-trip).
    if WRITE_COMMANDABLE and scf_type in COMMANDABLE_TYPES:
        o.append(f'')
        o.append(f'  {res_id}write:')
        o.append(f'    type: Cybus::Endpoint')
        o.append(f'    properties:')
        o.append(f'      protocol: Bacnet')
        o.append(f'      connection: !ref connection')
        o.append(f'      topic: {res_id}cmd')
        o.append(f'      write:')
        o.append(f'        property: present-value')
        o.append(f'        objectType: {scf_type}')
        o.append(f'        objectInstance: {inst}')

# Auto-add object-list endpoint when response would exceed device APDU
# NPDU ~8B + APDU header ~15B + each object-id ~5B (tag + 4B value) + framing ~4B
estimated_objlist_size = 27 + (len(objects) + 1) * 5
is_constrained = segmentation == 'noSegmentation' and max_apdu < 1476
if is_constrained and estimated_objlist_size > max_apdu:
    o.append(f'')
    o.append(f'  objectList:')
    o.append(f'    type: Cybus::Endpoint')
    o.append(f'    properties:')
    o.append(f'      protocol: Bacnet')
    o.append(f'      connection: !ref connection')
    o.append(f'      topic: object-list')
    o.append(f'      subscribe:')
    o.append(f'        priority: 12')
    # object-list is a device-static property; 5min poll is plenty.
    # A 10s poll on constrained devices forces indexed fallback every cycle
    # and risks Application-Exceeded-Reply-Time aborts on overloaded devices.
    o.append(f'        interval: 300000')
    o.append(f'        property: object-list')
    o.append(f'        objectType: device')
    o.append(f'        objectInstance: {dev_id}')
    print(f"NOTE: Added object-list endpoint (Tier 3 test: {estimated_objlist_size}B > {max_apdu}B APDU)",
          file=sys.stderr)

print('\n'.join(o))
PYEOF

# Never emit a silent 0-byte SCF (a redirected heredoc failure isn't caught by set -e).
[[ -s "$OUTPUT" ]] || { echo "ERROR: generation produced an empty SCF ($OUTPUT)" >&2; rm -f "$OUTPUT"; exit 1; }

EP_COUNT=$(grep -c 'Cybus::Endpoint' "$OUTPUT" || true)
echo "Generated: $OUTPUT ($EP_COUNT endpoints)"
