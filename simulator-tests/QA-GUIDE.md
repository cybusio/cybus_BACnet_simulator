# BACnet QA Test Suite

## Production Connectware Tests

### Setup

```bash
# 1. Start simulator
docker compose up --build

# 2. Generate SCFs (SIM_IP = simulator address as seen by protocol-mapper)
SIM_IP=172.18.0.1
for f in profiles-cybus/*.yaml; do
  ./scripts/generate-scf.sh "$SIM_IP" "$f"
done

# 3. Deploy each SCF to Connectware (UI or CLI)

# 4. Verify
CW_IP=192.168.178.71
for f in scf/*.yml; do
  ./scripts/verify.sh "$CW_IP" "$f"
done
```

---

## What Each SCF Tests

| SCF | Endpoints | Tests | Expected | Pass criteria |
|-----|-----------|-------|----------|---------------|
| **modern_controller** | 21 | Happy path — no constraints, full segmentation | All 21 publish in <5s, zero errors in logs | 21/21 topics, no ABORT, no timeout |
| **newlift_gateway** | 106 | Large device, capability discovery, segmentedBoth | All 106 publish in <5s, logs show `max_apdu=1476, segmentation=segmented-both` | 106/106 topics |
| **legacy_controller** | 14 | Constrained device (206B, noSeg, TSM=4, 50ms delay) | All 14 publish in <15s (slow device, reads queue through TSM=4) | 14/14 topics, `max_apdu=206` in logs |
| **miele_energy_meter** | 100 | Abort code 1 (bufferOverflow), 100 objects on noSeg device | All 100 publish in <45s. Some initial timeouts normal when 6 services compete for invoke_ids | 100/100 topics, no "Maximum concurrency reached" |
| **green_energy_ebmgr** | 44 | Abort code 11 (apduTooLong) — was "Reserved for ASHRAE" before fix | All 44 publish in <5s | 44/44 topics, no "Reserved for Use by ASHRAE" in logs |
| **miele_overloaded** | 100 | Stress test — 200ms delay, TSM=12, abort code 8 | NOT all endpoints will publish. Device can serve ~5 reads/s but 100 endpoints poll at 1/s. Partial coverage is expected. | No "Maximum concurrency reached", adapter stays alive, some data flows |

### Understanding Overloaded Device Results

The overloaded profile is designed to fail partially. With 200ms + 150ms jitter per response and TSM pool=12, the device can answer ~43 reads/second. But 100 endpoints polling at 1s = 100 reads/second demanded. The math doesn't work — most reads timeout.

When 6 services run simultaneously (385 total endpoints sharing one BACnet client with 255 invoke_ids), the overloaded device gets further starved. 14/100 in 120s is realistic and correct.

**The pass criteria is NOT "all endpoints publish" — it is:**
- No `Maximum concurrency reached` (invoke_ids aren't leaking)
- No adapter crash or hang
- Connection stays `connected`
- The endpoints that do succeed have correct data

---

## Log Patterns

### `BestEffortPoll: Read failed ... Read request timed out`

The device didn't respond in time. The adapter retries next poll cycle. Expected on slow/overloaded devices under concurrent load. If you see this on modern or newlift — something is wrong.

### `BACnet ABORT (invoke_id=N, server=0): Buffer Overflow`

Device response exceeded its APDU limit. The adapter catches codes 1, 4, 11 and falls back to indexed reads. Before the fix, this hung for 15s — now it's immediate.

### `Response too large, using indexed reads for ...`

Adapter switched to element-by-element reads after an APDU abort. Working as intended.

### `Device capabilities: max_apdu=N, segmentation=X, indexed_reads=Y`

Capability discovery worked. The adapter knows the device's limits.

### `Maximum concurrency reached, request canceled`

**Should NEVER appear.** All 255 invoke_ids exhausted — means abort handlers aren't freeing them. This is a regression.

---

## Simulator Device Reference

| Device | Port | DeviceID | Objects | max_apdu | Segmentation | Abort | Delay | TSM |
|--------|------|----------|---------|----------|-------------|-------|-------|-----|
| modern | 47811 | 400001 | 21 | 1476 | segmentedBoth | none | 5ms | unlimited |
| miele | 47808 | 1014006 | 100 | 480 | noSegmentation | 1 (bufferOverflow) | 25ms | 12 |
| energy | 47809 | 2000001 | 44 | 480 | noSegmentation | 11 (apduTooLong) | 15ms | 16 |
| legacy | 47810 | 300001 | 14 | 206 | noSegmentation | 1 (bufferOverflow) | 50ms | 4 |
| newlift | 47812 | 2000 | 106 | 1476 | segmentedBoth | none | 5ms | unlimited |
| overloaded | 47813 | 1014007 | 100 | 480 | noSegmentation | 8 (replyTimeout) | 200ms | 12 |

---

## Troubleshooting

**Connection stays `connecting`:**
- Is the simulator running? `docker compose ps`
- Does the SCF `deviceAddress` IP match what protocol-mapper can reach?
- SCFs use direct unicast (`deviceAddress`), so no BBMD needed

**All reads failing:**
- Simulator probably crashed — check `docker compose logs`
- verify.sh ignores retained MQTT messages, so stale data won't hide a dead simulator

**`Maximum concurrency reached`:**
- Regression — should never happen after the fix

**`Reserved for Use by ASHRAE`:**
- Old protocol-mapper code, needs the fix

---

## Standalone Simulator Self-Test (optional)

Verifies the simulator itself responds correctly before pointing CW at it.
Uses BAC0 (Python BACnet client) — not part of the production test path.

```bash
docker compose up --build
bash simulator-tests/qa-simulator-test.sh
```

Requires simulator venv with BAC0 (`uv sync --dev`).
