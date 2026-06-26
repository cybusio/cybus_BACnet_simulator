# BACnet Simulator — Device Reference

This is the single source of truth for BACnet simulator device facts (ports, device instances, object counts, abort codes, key timing). Machine truth lives in `qa/inproc/device_profiles.py` and `profiles-cybus/*.yaml`; the tables below mirror them. Change a profile there, reflect it here — and link here from other docs instead of re-stating any of these values.

## Core devices

The 13 `compose.yaml` services: the 10 core profiles in `device_profiles.ALL_DEVICES` plus the three variant emitters (`abort_storm`, `reply_time_storm`, `cov_emitter`). Port and device instance come from each profile's `simulator:` block.

| Profile | Port | Device instance | Objects | Key behavior / abort |
|---------|------|-----------------|---------|----------------------|
| `modern_controller` | 47811 | 400001 | 21 | Fast, fully compliant baseline (1476 APDU, segmentedBoth); read + writable AVs. No abort. |
| `legacy_controller` | 47810 | 300001 | 14 | 206B APDU, noSegmentation → forces single-property ReadProperty; abort **1** (bufferOverflow) on oversized RPM. |
| `miele_energy_meter` | 47808 | 1014006 | 101 | 100 data objects + `object-list`; abort **1** (bufferOverflow) → indexed array fallback. |
| `green_energy_ebmgr` | 47809 | 2000001 | 44 | 480 APDU, noSegmentation; abort **11** (apduTooLong, code >9) → indexed fallback. |
| `newlift_gateway` | 47812 | 2000 | 106 | Elevator gateway; scales to ~2500 via `BACNET_OBJECT_PADDING`. Large array reads via indexed fallback. No abort. |
| `miele_overloaded` | 47813 | 1014007 | 101 | CPU-saturated: `response_delay_ms` 200, `tsm_pool_size` 12, abort **8** (reply-time). Stress/survival, not crash. |
| `no_rpm_controller` | 47816 | 600001 | 10 | `disable_rpm` → REJECT **9** (unrecognizedService) on any RPM; ReadProperty-only path. Abort **1** on oversized RP. |
| `abort_segmentation` | 47817 | 600002 | 10 | 10 scalars; abort **4** (segmentationNotSupported) on reads needing segmentation. |
| `ultra_slow` | 47818 | 600003 | 4 | `response_delay_ms` 2500 + 200ms jitter (< peer apduTimeout 3000ms); `tsm_pool_size` 0 (unlimited). TSM timeout/sweep. No abort. |
| `empty_device` | 47819 | 600004 | 0 | Device object only; graceful 0-endpoint handling. No abort. |
| `cov_emitter` | 47820 | 900001 | 5 | Subscribe-COV server (3 driven AVs + 2 toggled BVs); emits COV notifications. Adapter is polling-only — variant, not core coverage. |
| `abort_storm` | 47821 | 1014008 | 101 | `force_abort` on every read incl. liveness probe; abort **1**. ABORT = proof-of-life → must stay connected, no reconnect storm. |
| `reply_time_storm` | 47822 | 1014009 | 101 | Sibling of `abort_storm` with abort **8** (reply-time) — not recoverable by any smaller request; must surface even on `object-list`. |

Notes (only where behavior is special):
- **`no_rpm_controller`** is the only profile that rejects ReadPropertyMultiple (REJECT 9); every other profile supports RPM.
- **`ultra_slow`** delay is tuned just under the 3000ms peer apduTimeout — there is no "9-second window"; `response_delay_ms` ≥ 3000 silently drops responses.
- **Abort codes diverge by case**: reason **1** (bufferOverflow) and **4** (segmentationNotSupported) are recoverable via the indexed array fallback; reason **8** (reply-time) and **11** (apduTooLong, unrecognized by older C++ stacks) are surfaced, not worked around.
- **`abort_storm` / `reply_time_storm`** abort their own device/object-name reads too (`abort_device_reads`), so the connect probe aborts — the client classifies any ABORT as "alive" and connects regardless.
- **`miele_overloaded` / `abort_storm` / `reply_time_storm`** extend `miele_energy_meter` (101 endpoints); only the realism/abort knobs differ.

## Fleets

Generated fleets for soak/scale/integrity testing. Each generator writes sim profiles to `profiles-cybus/` plus a `*.compose.yaml`. All analog-input values are static (`drift_pct: 0`) and globally unique so any MQTT reading pins exactly one `(device, instance)`.

| Fleet | Generator | Devices | Device instances | Ports | Value formula |
|-------|-----------|---------|------------------|-------|---------------|
| scale | `qa/gen/gen-scale-fleet.sh` | 32 (4 real Miele concentrators + 28 synth, 1–4 meters each) | synth 3000004–3000031 | synth 47884–47911 | `40000 + idx*1000 + instance` (idx = device index 4–31) |
| rw | `qa/gen/gen-rw-fleet.sh` | 32 writable (`N`, default 32) | 4000000–4000031 | 47950–47981 | writable AV/MV/BV, read-back = last write |
| miele concentrators | `qa/gen/gen-miele-profiles.sh` | 4 real | 2098177, 2098183, 2098184, 2098185 | 47870–47873 | `40000 + device_index*1000 + instance` |

Generate:

```bash
./qa/gen/gen-scale-fleet.sh        # → scale-fleet.compose.yaml (+ 28 synth profiles); prints the fleet map (TSV)
N=32 ./qa/gen/gen-rw-fleet.sh      # → rw-fleet.compose.yaml (+ 32 rw profiles)
./qa/gen/gen-miele-profiles.sh     # → miele-fleet.compose.yaml (+ 4 concentrator profiles)
```

The scale fleet's 4 concentrators come from `miele-fleet.compose.yaml`; run `gen-miele-profiles.sh` alongside `gen-scale-fleet.sh` for the full 32.

## Bringing devices up

All services use `network_mode: host`; ports come from each profile's `simulator:` block (metrics ports are set per-service in compose).

```bash
# Core 13 (compose.yaml)
docker compose up --build
docker compose up bacnet-legacy        # single core device

# Fleets (generate first, then bring up the per-fleet compose)
docker compose -f scale-fleet.compose.yaml up --build
docker compose -f rw-fleet.compose.yaml up --build
docker compose -f miele-fleet.compose.yaml up --build
```

## Source of truth

Regenerate or verify every fact above from `qa/inproc/device_profiles.py` (`ALL_DEVICES` + variant profiles) and `profiles-cybus/*.yaml`.
