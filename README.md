# BACnet Simulator (alpha)

Six virtual BACnet/IP devices for testing the Connectware adapter against
realistic device behaviors — aborts, constrained APDUs, slow responses, TSM
exhaustion. Deploy SCFs to Connectware, point them at the simulator, verify
data flows through MQTT.

## Quick Start

```bash
# Start simulator (6 devices on host network)
docker compose up --build

# Generate SCFs for all devices (use simulator IP as seen by protocol-mapper)
for f in profiles-cybus/*.yaml; do
  ./scripts/generate-scf.sh 172.30.0.100 "$f"
done

# Upload SCFs to Connectware UI, then verify
./scripts/verify.sh 192.168.178.168 scf/newlift_gateway.yml
```

## Profiles

| Service | What it simulates | Why you test with it |
|---------|-------------------|---------------------|
| `bacnet-modern` | Fast, fully compliant controller | Baseline — if this fails, everything is broken |
| `bacnet-newlift` | 106-object elevator gateway | Large device, capability discovery, segmentation |
| `bacnet-legacy` | Old controller (206B, noSeg, slow) | Constrained APDU, indexed reads, TSM queuing |
| `bacnet-miele` | Energy meter that aborts (code 1) | Abort propagation, indexed read fallback |
| `bacnet-energy` | Building manager that aborts (code 11) | The "Reserved for ASHRAE" bug reproduction |
| `bacnet-miele-overloaded` | CPU-saturated device (200ms, TSM=12) | Stress test — adapter must survive, not crash |

See **[QA Guide](simulator-tests/QA-GUIDE.md)** for pass/fail criteria, expected log patterns,
and what each message means.

## Generate SCFs

Reads the profile and produces a ready-to-upload SCF. Constrained devices
automatically get the right `maxApdu`/`segmentation` overrides.

```bash
# Single device
./scripts/generate-scf.sh 172.18.0.1 profiles-cybus/newlift_gateway.yaml

# All devices
for f in profiles-cybus/*.yaml; do ./scripts/generate-scf.sh 172.18.0.1 "$f"; done

# Scale NewLift to 2000 endpoints (simulator must also start with BACNET_OBJECT_PADDING=2000)
./scripts/generate-scf.sh 172.18.0.1 profiles-cybus/newlift_gateway.yaml newlift-2000 2000
```

## Verify

Checks that endpoints publish fresh data via MQTT and scans adapter logs for regressions.

```bash
./scripts/verify.sh 192.168.178.71 scf/newlift_gateway.yml
./scripts/verify.sh 192.168.178.71 scf/miele_overloaded.yml --timeout 120
```

## Scaling NewLift

Real MBS UGW goes from 106 to 2500+ objects. Both sides must match:

```bash
BACNET_OBJECT_PADDING=2000 docker compose up bacnet-newlift
./scripts/generate-scf.sh 172.18.0.1 profiles-cybus/newlift_gateway.yaml newlift-2000 2000
```

Only newlift scales realistically — other devices are fixed-function hardware.

## Profile Tuning

Each profile in `profiles-cybus/` extends `profiles/_base.yaml`:

```yaml
simulator:
  port: 47812              # UDP port
  device_id: 2000          # BACnet device instance

network:
  max_apdu: 1476           # response size limit
  segmentation: segmentedBoth

realism:
  response_delay_ms: 50    # per-response latency
  tsm_pool_size: 4         # concurrent transactions (0 = unlimited)
  abort_reason: 1          # ASHRAE abort code (0 = disabled)
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACNET_OBJECT_PADDING` | 0 | Extra objects for NewLift scaling |
| `BACNET_LOG_LEVEL` | INFO | DEBUG shows every APDU on the wire |
| `BACNET_PROFILES_DIR` | profiles | Profile YAML directory |
| `BACNET_METRICS_PORT` | 9100 | Prometheus `/metrics` port |

## Dev

```bash
uv sync --dev
uv run pytest tests/ -v
uv run ruff check src/ tests/
uv run mypy src/
```

Python 3.12+, [uv](https://docs.astral.sh/uv/).
