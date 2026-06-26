# BACnet Adapter Test Matrix

Test matrix for the Connectware 2.x BACnet adapter (polling-only, two-tier read model).

The adapter uses a two-tier read strategy:
- **Tier 1 (ReadProperty):** the mandatory BACnet service, always used for single properties.
- **Tier 2 (indexed fallback):** on a too-large ABORT for an array, probes `arrayIndex 0`; a valid count reads elements 1..N, a non-array surfaces the original ABORT.

No RPM (ReadPropertyMultiple), no COV subscriptions, no read-service caching.

Status legend: **✅** covered by the qa-trio or a unit test · **manual** verified manually / not automated · **❌** not coverable without specialized hardware or a malicious server.

> Device facts (ports, APDU sizes, object counts, abort codes) are authoritative in [docs/PROFILES.md](../docs/PROFILES.md); rows below reference devices by name and describe the adapter behavior each one exercises.

---

## Group A: Read Paths

| ID | Path | Property | Device | Expected behavior | Status |
|----|------|----------|--------|-------------------|--------|
| A-01 | 1 (RP) | present-value (scalar) | modern | RP succeeds, value returned | ✅ |
| A-02 | 1 (RP) | present-value (scalar) | newlift | RP succeeds, 106 endpoints | ✅ |
| A-03 | 1 (RP) | present-value (scalar) | legacy (206B, noSeg) | RP works (~25B fits) | ✅ |
| A-04 | 1 (RP) | present-value (scalar) | miele (480B, abort=1) | RP works for scalars | ✅ |
| A-05 | 1 (RP) | present-value (scalar) | energy (480B, abort=11) | RP works for scalars | ✅ |
| A-06 | 1→2 (RP ABORT → indexed) | object-list (array) | miele (480B, 100 objects) | RP ABORTs → indexed 1..100 | ✅ |
| A-07 | 1 (RP) | present-value (scalar) | no_rpm | RP read on a device that never advertised RPM | ✅ |
| A-08 | 1→2 (RP ABORT → indexed) | object-list (array) | no_rpm | RP ABORTs → indexed fallback | ✅ |
| A-09 | 1→2 (RP ABORT(4) → indexed) | object-list (array) | abort_segmentation | ABORT(segNotSupported) triggers indexed reads | ✅ |
| A-10 | 1 (RP) | present-value (scalar) | any | straight RP read, no overhead | ✅ unit |
| A-11 | 1 (RP) | object-list (small array) | modern (1476B, 21 objects) | RP succeeds, fits in 1476B | ✅ |
| A-12 | 1 (RP) | object-list (small array) | legacy (206B, 14 objects) | RP response ~102B < 206B, no indexed needed | ✅ |

---

## Group B: ABORT Code Handling

A too-large ABORT on an array read is classified by `isResponseTooLarge` (size-related codes) and falls to the indexed tier; other codes propagate as errors.

| ID | Code | Name | isResponseTooLarge? | Behavior | Device | Status |
|----|------|------|---------------------|----------|--------|--------|
| B-01 | 1 | bufferOverflow | Yes | indexed fallback | miele | ✅ |
| B-02 | 4 | segmentationNotSupported | Yes | indexed fallback | abort_segmentation | ✅ |
| B-03 | 11 | apduTooLong | Yes | indexed fallback | green_energy_ebmgr | ✅ |
| B-04 | 0 | other | No | error to endpoint | — | ✅ unit |
| B-05 | 8 | applicationExceededReplyTime | No | error to endpoint | miele_overloaded | ✅ |
| B-06 | none | no abort | N/A | RP ACK | modern | ✅ |
| B-07 | 2/3/9/10 | invalidApduInThisState / maxBufferExceeded / outOfResources / tsmTimeout | No | error to endpoint | — | ❌ no simulator producer |

---

## Group C: Value Type Parsing

| ID | Tag | Type | Example | Result | Status |
|----|-----|------|---------|--------|--------|
| C-01 | 0 | NULL | null | `null` | ✅ unit |
| C-02 | 1 | BOOLEAN | "TRUE" | `true` | ✅ |
| C-03 | 2 | UNSIGNED_INT | "42" | `42` | ✅ |
| C-04 | 3 | SIGNED_INT | "-5" | `-5` | ✅ unit |
| C-05 | 4 | REAL | "22.5" | `22.5` | ✅ |
| C-06 | 5 | DOUBLE | "3.14159" | `3.14159` | ✅ unit |
| C-07 | 4 | REAL (NaN) | "nan" | `"nan"` (string fallback) | ✅ unit |
| C-08 | 5 | DOUBLE (Inf) | "inf" | `"inf"` (string fallback) | ✅ unit |
| C-09 | 7 | CHARACTER_STRING | "Room 401" | `"Room 401"` | ✅ |
| C-10 | 9 | ENUMERATED | "active" | `"active"` | ✅ |
| C-11 | 12 | OBJECT_ID | "(analog-value, 100)" | `{objectTypeName, objectInstance}` | ✅ |
| C-12 | 99 | unknown | "raw" | `"raw"` (pass-through) | ✅ unit |
| C-13 | 6 | OCTET_STRING | hex bytes | raw string | ❌ no producer |
| C-14 | 8 | BIT_STRING | "{1,0,1}" | `[1,0,1]` | ❌ no producer |
| C-15 | 10 | DATE | date string | raw string | ❌ no producer |
| C-16 | 11 | TIME | time string | raw string | ❌ no producer |

---

## Group D: Connection Lifecycle

| ID | Scenario | Start | End | Status |
|----|----------|-------|-----|--------|
| D-01 | First connect | disconnected | connected | ✅ |
| D-02 | Connect to unreachable | disconnected | reconnecting | ✅ |
| D-03 | Device returns after outage | reconnecting | connected | ✅ |
| D-04 | Device disappears | connected | reconnecting | ✅ |
| D-05 | Graceful disconnect | connected | disconnected | ✅ |
| D-06 | Reconnect after disconnect | disconnected | connected | ✅ |
| D-07 | Max APDU logged once per connect | connected | single log | ✅ |
| D-08 | Max APDU re-logged on reconnect | reconnected | new log | ✅ |
| D-09 | Concurrent health-check guard (single in-flight probe) | connected | single probe | manual |
| D-10 | Disconnect during indexed read (error propagates) | reading | error thrown | manual |

---

## Group E: Write Operations

| ID | Scenario | Priority | Expected | Status |
|----|----------|----------|----------|--------|
| E-01 | Write REAL (auto-detected tag) | 15 | value written | ✅ |
| E-02 | Write BOOL (auto-detected tag) | 15 | value written | ✅ |
| E-03 | Write to nonexistent object | 15 | error thrown | ✅ |
| E-04 | Reject non-primitive write value | 15 | throws `must be a primitive` | ✅ |
| E-05 | Write with explicit tag | 15 | forced tag used | manual |
| E-06 | Write to read-only object | 15 | error thrown | manual |
| E-07 | Write priority=1 (highest) | 1 | highest priority | manual |
| E-08 | Write priority=0 → default via `??` | 0→15 | uses default 15 | manual |
| E-09 | Write when disconnected | 15 | error thrown | manual |

---

## Group F: Edge Cases

| ID | Scenario | Expected | Status |
|----|----------|----------|--------|
| F-01 | object-list count=0 (empty device) | `_readArray` returns `[]` | ✅ |
| F-02 | object-list count > MAX_ARRAY_ELEMENTS | Error: exceeds safety limit | ✅ unit |
| F-03 | object-list count = NaN/negative | Error: invalid array count | ✅ unit |
| F-04 | 255 concurrent reads (TSM pool full) | some timeout, no hang, no crash | ✅ |
| F-05 | Multiple connections, same device | shared process-wide singleton client | ✅ |
| F-06 | Sweep fires during indexed read (slow device) | mid-loop element times out, error thrown | manual |
| F-07 | Slow peer near TSM timeout (ultra_slow) | slow response, TSM sweep reclaims iid on timeout | manual |
| F-08 | Device reboots mid-indexed-read | error propagates, partial data dropped | manual |
| F-09 | Malformed value from device | parser tolerates, no unhandled rejection | ❌ no producer |
| F-10 | Spoofed/wrong invoke_id | TSM rejects, callback not found | ❌ cannot simulate |

---

## Group G: Schema Validation

| ID | Field | Value | Expected | Status |
|----|-------|-------|----------|--------|
| G-01 | deviceInstance | 0 (min) | accepted | ✅ unit |
| G-02 | deviceInstance | 4194303 (max) | accepted | ✅ unit |
| G-03 | deviceInstance | -1 | rejected (minimum 0) | ✅ unit |
| G-04 | deviceInstance | 4194304 | rejected (maximum 4194303) | ✅ unit |
| G-05 | deviceInstance | missing | rejected (required) | ✅ unit |
| G-06 | deviceAddress | missing | rejected (required) | ✅ unit |
| G-07 | deviceAddress | "192.168.1.1:47808" | accepted | ✅ |
| G-08 | deviceAddress | "192.168.1.1" (no port) | accepted (default 47808) | ✅ |
| G-09 | unknownProperty | any | rejected (additionalProperties false) | ✅ unit |
| G-10 | connectionStrategy | {initialDelay:5000} | accepted (optional) | ✅ |

---

## Coverage Summary

| Group | Total | ✅ Covered | manual | ❌ Uncoverable |
|-------|-------|-----------|--------|---------------|
| A: Read paths | 12 | 12 | 0 | 0 |
| B: ABORT handling | 7 | 6 | 0 | 1 |
| C: Value parsing | 16 | 12 | 0 | 4 |
| D: Connection lifecycle | 10 | 8 | 2 | 0 |
| E: Write operations | 9 | 4 | 5 | 0 |
| F: Edge cases | 10 | 5 | 3 | 2 |
| G: Schema validation | 10 | 10 | 0 | 0 |
| **Total** | **74** | **57** | **10** | **7** |

> (A "REJECT handling" group from the RPM era was removed — REJECT on ReadProperty simply propagates as an error to the endpoint, exercised under ABORT/error handling.)

---

## Test Coverage Notes

**Automated by the qa-trio 4 core suites (59/59 assertions passing):**
- **connection-realism-test.js** (7) — connection state transitions, reconnection, health checks.
- **factory-storm-test.js** (13) — mixed-class connect, read storm, slow-peer isolation, reconnect storm, 500-read burst, no-rpm device reads via ReadProperty, abort-seg, empty device, abort-storm probe/read/write, indexed fallback.
- **qa-simulator-test.js** (33) — ABORT propagation + `isResponseTooLarge` classification, indexed array reads (newlift/legacy/miele), BBMD foreign-device registration + TTL renewal, TSM 255-slot exhaustion.
- **caveat-boundaries-test.js** (6) — tuning-divergence warn, indexed fallback (array recovers / scalar surfaces the original ABORT), reply-time reason-8 propagation.

**`manual`** rows are verified by hand or are timing/concurrency-sensitive (write-priority variants, sweep-during-read, mid-read reboot) — supported by the adapter, not automated in the core suites.

**`❌`** rows need specialized hardware (OCTET_STRING / DATE / TIME / BIT_STRING producers) or a malicious server (spoofed invoke_id) and are out of scope for the simulator.
