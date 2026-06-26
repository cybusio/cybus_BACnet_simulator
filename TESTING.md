# Testing the BACnet Adapter

The single, step-by-step run guide for the Connectware 2.x BACnet/IP adapter
(polling-only: ReadProperty Tier-1 + ReadRange/indexed Tier-2 array recovery; no
RPM, no read-cache; no COV). **Part 1** is the procedure a junior QA engineer
follows to certify a build (do this, in this order). **Part 2** is the rigorous
deep tier (P1–P8) for production validation. **Part 3** is reference — look things
up when a step needs it.

**One rule to remember:** a healthy adapter is **silent** — a good read produces
data on MQTT and writes nothing to the log. Every check below is really two
questions: *did the data come through correctly?* and *was the log clean (no
`error`/`fatal` lines)?*

**Applies to:** Connectware 2.0 BACnet/IP adapter, branch
`CC-4157-pm-support-bacnet-messages-big`.

```
Level / Part      What                         Needs            Time
Part 1 Step 1     npm run test:bacnet (CI)     no sim, no CW    ~5 min
Part 1 Step 3     qa-trio                      sims, no CW      ~mins
Part 1 Step 4     *-e2e.sh scripts             sims + CW + MQTT ~per script
Part 1 Step 5     scale-soak / rw-soak         sims + CW + MQTT 30 min each
Part 2 P1–P8      the rigorous deep tier       sims + CW + MQTT ~1–2 h full
```

> **Single source of truth for device facts.** Ports, device instances, object
> counts, abort/reject codes, and per-profile behaviour live **only** in
> [docs/PROFILES.md](docs/PROFILES.md). This guide refers to profiles **by name**
> and never restates a port/count/code inline. The per-case coverage matrix lives
> only in [docs/TEST-MATRIX.md](docs/TEST-MATRIX.md).

---

## Setup — repositories, paths & conventions

Two repositories. **Every path below is relative to one of them** — run each
command from the stated repo root.

| Repo (short name) | Origin | You run things from |
|---|---|---|
| **`cybus`** (the adapter) | `bitbucket.org/cybusio/cybus` | `cybus/protocol-mapper/` |
| **`cybus_BACnet_simulator`** (this repo) | `github.com/cybusio/cybus_BACnet_simulator` | repo root |

> **If the two repos are not siblings** (this repo isn't next to `cybus/`), the qa-trio
> step (Step 3) needs the adapter path: prefix it with
> `PM_ROOT=/abs/path/to/cybus/protocol-mapper`. Note it now so Step 3 doesn't surprise you.

**Install these** (run each; install any that errors before continuing):

```bash
docker --version            # Docker must be running: `docker ps` should list containers
node  --version             # must be v24.x (a different major breaks the native addon)
jq --version
mosquitto_sub --help | head -1     # the 'mosquitto-clients' package
```

**Confirm Connectware is up and reachable** (needed for Steps 4–5):

```bash
# 1. the gateway container must be running (Up, not Exited):
docker ps --format '{{.Names}}\t{{.Status}}' | grep connectware

# 2. you can log in (must print a long token, not "NO TOKEN"):
curl -sk -X POST https://localhost/api/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' | jq -r '.token // "NO TOKEN"'
```

- **Empty / `NO TOKEN` / connection refused?** The API isn't serving. If the
  `connectware` container shows `Exited`, start it and wait ~1 min:
  `docker start platform-connectware-1`. **Common cause: a host MQTT broker (e.g.
  `mosquitto`) holding port 1883 blocks Connectware's gateway from binding it** —
  check `ss -tlnp | grep 1883`; if a host process owns it, stop that service
  (`sudo systemctl stop mosquitto`) so the gateway can bind. To bring the whole
  platform up, run `docker compose up -d` from `cybus/platform/` (reads `platform/.env`).
  **Do not start Steps 4–5 until the token check prints a token.**
- **MQTT reading the wrong broker?** `localhost:1883` must be Connectware's broker.
  If a host `mosquitto` is running, your `mosquitto_sub/pub` may talk to *it* —
  confirm with `ss -tlnp | grep 1883` that the listener is `docker-proxy`.
- **CW or sims not on the defaults?** Every Step-4/5 script reads these env
  overrides — export before running: `CW_HOST` (default `localhost`), `CW_PORT`
  (`443`), `MQTT_HOST` (`localhost`), `SIM_HOST` = the sim address as Connectware
  sees it (`172.18.0.1`, the Docker bridge gateway — the host LAN IP fails because
  the protocol-mapper sits on the `platform_default` bridge).

**Constants used everywhere** (scripts default to these):

| | |
|---|---|
| Connectware API | `https://localhost/api`, login `admin` / `admin` |
| MQTT broker | `localhost:1883`, user `admin`, pass `admin` |
| protocol-mapper container | `platform-protocol-mapper-1` |
| A simulator's address, seen from Connectware | `172.18.0.1:<port>` (port per `docs/PROFILES.md`) |

---

# PART 1 — CERTIFY A BUILD (step by step)

Run Steps 1→6 **in order**. Each step shows: ▶ the command · ✓ what a pass looks
like · ✗ what to do if it doesn't. Steps 1–3 don't need Connectware; Steps 4–5 do.

### Step 1 — Unit + integration suite (the CI gate)  ·  ~5 min  ·  no Connectware

Self-contained: builds the native stack, runs the C++ integration/workload suites
+ the in-process JS suite, and cleans up its own sims (UDP 47808–47812). This is
exactly what CI runs. It is a **smoke layer**: it proves the build and core logic
but does NOT exercise device-variance (slow peers, aborts, large arrays) or the
CW→MQTT path — for that, Steps 2+.

▶ Run (from `cybus/protocol-mapper/`). The suite binds its own BACnet client +
servers on **UDP 47808–47812**, so the first line **frees those ports** by stopping
any running sim fleet that would hold them. It is idempotent — a no-op when nothing
is up — so this step can never hit `Address in use`:
```bash
docker ps -q --filter name=bacnet_simulator | xargs -r docker stop   # free 47808–47812 (idempotent)
bash src/protocols/bacnet/stack/build.sh      # build the native addon (first time / after C++ changes)
npm run test:bacnet
echo "exit code: $?"
```
(Step 2 brings the fleet back up.)

✓ Pass: three suites all green, **exit code 0**. Totals: **14** integration +
**1000** workload + **27** lifecycle = **1041**.

✗ If it fails: find the symptom in **R1 → Step-1 failures**. Most common: Docker
not running, a port still in use, or Node not v24.

> After C++ changes, also reload the fresh `.so` into the running adapter:
> `docker restart platform-protocol-mapper-1`.

---

### Step 2 — Start the simulators  ·  ~1 min

Steps 3–5 need the simulator fleet running (host network).

▶ Run (from the `cybus_BACnet_simulator` root):
```bash
docker compose up -d --build
docker ps --format '{{.Names}}' | grep bacnet     # confirm containers are up
```

✓ Pass: you see the sims (Compose prefixes the project name, so they appear as
`bacnet_simulator-bacnet-modern-1`, `…-bacnet-legacy-1`, `…-bacnet-miele-1`,
`…-bacnet-ultra-slow-1`, and others — the `grep bacnet` matches them).

✗ A few tests need an extra sim not in the base fleet. The **CW test catalog (R2)**
lists exactly which sim each script needs — `func-array` needs `bacnet-huge`,
`discovery` needs `bacnet-mega-b`:
```bash
docker compose -f compose/huge.compose.yaml       up -d bacnet-huge     # func-array (port 47860)
docker compose -f compose/largescale.compose.yaml up -d bacnet-mega-b   # discovery   (port 47862)
```

> A single-file `docker compose up` prints a `Found orphan containers … to remove
> them: --remove-orphans` warning — that is **expected and harmless** (the other
> fleets share one compose project). **Ignore it; do not run the suggested
> `--remove-orphans`** — on a single file it deletes the whole shared
> `bacnet_simulator` fleet. Plain `docker compose down` (no flag) is fine.

---

### Step 3 — Protocol realism (qa-trio)  ·  ~5–15 min  ·  no Connectware

In-process tests that talk real BACnet/IP UDP to the sims, driving
`BacnetClient`/`BacnetConnection` directly (no CW). The cheap pre-gate before
paying for CW deploys.

▶ Run (from the `cybus_BACnet_simulator` root):
```bash
cd qa/inproc/qa-trio
./test.sh                       # if the repos are NOT siblings: PM_ROOT=/path/to/protocol-mapper ./test.sh
echo "exit code: $?"
```

✓ Pass: **exit code 0**, with the **4 core suites** (`connection-realism`,
`factory-storm`, `qa-simulator`, `caveat-boundaries`) all green (each prints
`=== <suite> ===` then its pass output). The **extended suites** print `SKIP: …`
unless their full fleet is up — that's normal. (`cov-hybrid-test` is not part of
this release; and `mega-scale-test` needs a 32-device fleet that isn't deployable in
this repo, so it **self-skips** rather than failing — its large-array path is proven
by P2 `func-array`/`discovery`.) With no `bacnet_simulator-*` container up,
everything SKIPs cleanly (exit 0).

✗ If a core suite fails: re-confirm Step 2's fleet is up, then re-run. A
persistent failure names the suite — capture its output and file a defect.

✗ If a failure says **`EADDRINUSE` / `bind` on a UDP port** (a sim or a leftover
process already holds it, not an adapter bug): find the holder and stop it, then
re-run — `ss -ulnp | grep <port>` then `docker stop <id>` or `kill <pid>`. (The
qa-trio BBMD probes bind an ephemeral port, so they no longer collide with the
fleet; this is for stray sims on the 47808–47812 range.)

---

### Step 4 — End-to-end on Connectware  ·  ~1–5 min each  ·  needs Connectware

Each script **auto-uploads and enables** its SCF(s), checks the data on MQTT, then
deletes them — you don't upload anything by hand. **Which SCF(s) each test uploads,
and the service IDs they create, is in the catalog → R2 (script ↔ SCF ↔ sim) and
R2.1 (exact SCF files + service IDs enabled).** While each runs, watch the adapter
log in a second terminal — see §2 below.

▶ First start the two large-object sims the battery needs:
```bash
docker compose -f compose/huge.compose.yaml       up -d bacnet-huge     # func-array
docker compose -f compose/largescale.compose.yaml up -d bacnet-mega-b   # discovery
```
▶ Then run the core battery (from the `cybus_BACnet_simulator` root):
```bash
for t in lifecycle cadence isolation abort-recovery discovery func-array; do
  echo "########## $t ##########"
  bash qa/e2e/$t-e2e.sh
done
```

✓ Pass: each script ends with `==> RESULT: N passed, 0 failed` **and** the adapter
log stays clean (§2).

✗ If a script prints `ERROR: CW auth failed` → redo the login check in Setup. If
`RESULT: … M failed` (M>0) → the lines above marked `[!] FAIL: …` say exactly
which check failed; capture them + the adapter log window.

> Extended e2e (`miele-spectrum-e2e.sh`, `cert-scf-matrix-e2e.sh`) need extra sims —
> see **R2** for which, then run them the same way.

---

### Step 5 — Reliability soaks  ·  ~30 min each  ·  needs Connectware

The highest bar: sustained 32-device load with exact value integrity, memory and
TSM monitored.

▶ Read-integrity soak — the fleet is **two** composes (synthetic meters + real
concentrators), both required:
```bash
bash qa/gen/gen-scale-fleet.sh                    # generates 28 synth profiles + compose/scale-fleet.compose.yaml
docker compose -f compose/scale-fleet.compose.yaml up -d   # 28 synthetic meter devices  (the 70 synthetic receives)
docker compose -f compose/miele-fleet.compose.yaml  up -d  # 4 real Miele concentrators   (the 36 real receives)
until [ "$(docker ps --filter health=healthy --format '{{.Names}}' | grep -c scale-synth)" -ge 28 ]; do sleep 3; done   # wait until sims answer (a few s after 'healthy')
SOAK_MIN=30 bash qa/e2e/scale-soak-e2e.sh         # exact value-match at T0 + every 5 min; quick: SOAK_MIN=5
```
The soak prints `T0 INTEGRITY: N/106` then aborts if `N<106` — both composes must
be up **and serving** (sims report `healthy` a few seconds before they answer
BACnet) or some receives miss.

▶ Write-integrity soak — fresh random write → poll → exact read-back:
```bash
bash qa/gen/gen-rw-fleet.sh
docker compose -f compose/rw-fleet.compose.yaml up -d
SOAK_MIN=30 bash qa/e2e/rw-soak-e2e.sh            # quick smoke: SOAK_MIN=2 ROUND_S=15
```
Each round writes fresh random REAL/UINT/BOOL to all writable points, reads back,
asserts an **exact round-trip**; DEGRADED on any mismatch / `tsm>0` / write-error>0.

✓ Pass: each ends with `RESULT: PASS`. (Prints `RESULT: FAIL`, exits non-zero, on
any value mismatch, stuck transaction, or write error.)

✗ If `RESULT: FAIL`: the per-checkpoint lines show which device/value diverged.
Capture them + the adapter log + the final `mem` figure, and file a defect.

---

### Step 6 — Functional verification + sign off

After Steps 1–5 pass, work the **functional verification checklist (§3)** — the
human, feature-by-feature confirmation, with the "Part 1 is done when" gate at its
end. For a full **production-validated** sign-off, also run **Part 2** (P1–P8).

---

## §2 — Watch the adapter log while tests run

Run this in a second terminal during Steps 4 and 5 (and any soak). It is the real
signal — a script can pass its own checks while the adapter logs errors underneath.

```bash
PM=platform-protocol-mapper-1
W=$(docker logs --since "300s" "$PM" 2>&1 | grep '"className":"BacnetConnection"')
echo "$W" | grep -oE '"level":[0-9]+' | sort | uniq -c          # 30=info 40=warn 50=error 60=fatal
echo "$W" | grep -cE  '"level":(5[0-9]|6[0-9])'                 # errors+fatals — MUST be 0
echo "$W" | grep -ciE 'unhandledrejection|uncaught|fatal'       # crash       — MUST be 0
echo "$W" | grep -ciE 'maximum concurrency reached'             # TSM exhaustion — MUST be 0
```

Always use relative `--since "300s"`, **never** `--since "$(date …)"` (timezone
mis-parse). **Standard:** every `40` line matches a row in **R1**; the `50`/`60`
count is **0**; no crash/restart; `docker stats` memory flat under soak. Anything
else is a finding even if the test said pass. (A `40`-level ABORT that names
`Buffer Overflow` / `Application Exceeded Reply Time` is the benign recovered abort
in R1 — that's why the TSM check matches only the exact `Maximum concurrency reached`.)

---

## §3 — Functional verification checklist (FV-001…009)

The automated Steps prove the code in aggregate; this is the **human,
feature-by-feature** confirmation. Deploy each config against a real or simulated
device — by hand via **R3**, or by watching the matching e2e run — and tick each
box. The **Covered by** column names the automated test that exercises the same
path (so you can spot-check rather than re-derive); **manual** means there is no
automated coverage — you must verify it by hand. Every error/warn below is also in
the **R1** log decoder.

| FV | Feature / scenario | How to exercise it | Expected | Covered by | Pass |
|---|---|---|---|---|---|
| **FV-001** | Read analog-input present-value | deploy `modern_controller` (R3); analog-input, instance 0, present-value, interval 1000 | value updates (e.g. `21.97`), no error | Step 1 integration; `qa-simulator` | ☐ |
| **FV-002** | Read binary active/inactive | binary-input present-value, poll 500 ms | toggles `"active"`/`"inactive"` within a cycle | Step 1; `qa-simulator` | ☐ |
| **FV-003** | Write commandable output at priority | analog-output present-value, write via MQTT `…/set` at priority 12 | device value changes; lower-priority writes rejected | write round-trip: `rw-soak-e2e.sh`; the **priority/rejection: manual** | ☐ |
| **FV-004** | Relinquish priority with NULL | write `null` (propertyTag 0) to priority 12 | the slot releases; value falls back | **manual** (not automated) | ☐ |
| **FV-005** | Large-array recovery (ReadRange/indexed) | object-list or state-text > 1476 B (`func-array-e2e.sh` vs `bacnet-huge`) | first poll ABORT→chunked; full array on MQTT, `unique==len`, `well-formed==len` | Step 1 (CC-4157 tests); `func-array-e2e.sh`; `mega-scale` | ☐ |
| **FV-006** | Reconnect after device loss | `docker stop` the peer, watch logs, `docker start` (`lifecycle-e2e.sh`) | health-check fails ×3 → `reconnecting` → backoff → reconnect → polling resumes | `lifecycle-e2e.sh`; `reconnect-test` | ☐ |
| **FV-007** | Error: unknown-object | analog-input instance 999 (not on device) | `… not present on device — correct this point's objectInstance/objectType … or disable it [<raw>]` | Step 1 (config-hint test); `abort-recovery-e2e.sh` | ☐ |
| **FV-008** | Error: unknown-property | analog-input with a typo'd / unsupported property | error names the property invalid for this object type | **manual** (only unknown-*object* — FV-007 — is automated) | ☐ |
| **FV-009** | Divergent-tuning warning | conn1 `apduTimeoutMs=<a>`; conn2 same agent `apduTimeoutMs=<b>` (b≠a) | WARN `ignoring divergent tuning on reuse: apduTimeoutMs=<b> (in effect <a>) …` (the automated test uses its own values — match the shape, not the numbers) | Step 1 integration (`keeps the first Connection tuning…`) | ☐ |

---

**Part 1 is done when** the FV cases above pass and:

```
[ ] Step 1  npm run test:bacnet → 1041 pass, exit 0
[ ] Step 2  simulator fleet up
[ ] Step 3  qa-trio → exit 0, core 4 suites pass (extended SKIP)
[ ] Step 4  every e2e script → "RESULT: N passed, 0 failed", log clean (§2)
[ ] Step 5  scale-soak AND rw-soak → "RESULT: PASS", zero level-50/60 in the log
[ ] §3      all 9 FV cases (FV-001…009) pass (or WAI-documented)
[ ] Overall every adapter log line seen is a known R1 line; no error/fatal
```

For a **production-validated** sign-off, also run **Part 2** P1→P6 green. If any
check fails, file a defect with reproduction steps and expected-vs-actual.

---

# PART 2 — THE DEEP TIER (rigorous P1–P8)

The exhaustive run that reveals production issues, ordered by **production risk**.
Run top-down; stop on first red. The CI smoke layer (Step 1) triggers none of
these device-variance paths.

## §4 — What "pass" means (the integrity standard)

Presence/typecheck is **not** pass. A phase passes only when one of these holds:
- **EXACT value-match** — each receive equals the device's known static value
  (`scale-soak`; value formula in `docs/PROFILES.md`).
- **Full ordered array** — a recovered large array equals the device's full
  baseline, element-for-element: **0 corrupt / no truncation / reorder / dupe /
  bleed** (`mega-scale`, and the e2e now assert `unique == len` and
  `well-formed == len`, not just length).
- **Exact write→readback** — random write, poll, read back, exact round-trip
  across all writable points (`rw-soak`).
- **Exact type & shape** — every BACnet datatype surfaces in its correct JSON
  type/shape (`spectrum`, `cert-matrix`): REAL precision, bare CharacterString,
  ENUMERATED string, OBJECT_ID `{objectTypeName,objectInstance}`,
  array `[{objectTypeName,objectInstance}]`.
- Plus **no PM red flags** in the log window (§2) — `Buffer Overflow`,
  `Maximum concurrency reached`/`encode failed` (TSM), `reconnect|connectlost`
  (storm), `unhandledrejection|uncaught|fatal` (crash) — and **flat memory** under soak.

## §5 — The risk-ordered phases

Each row: the script that deploys-and-verifies, the SCF + sim profile (facts in
PROFILES), the **integrity oracle**, and the production feature it breaks.

| Phase | Run | Oracle (reveals) |
|---|---|---|
| **P1 — Typed-value marshalling** ⚠️ HIGHEST RISK | `spectrum-deploy.sh` + `spectrum-verify.sh` (40-case TSV across all datatypes/properties/APDU/abort, **39/40** — R5); qa-trio `miele-production-test.js`; `miele-spectrum-e2e.sh` (P8) for `/combined` | per-datatype `jq`: REAL→number, UNSIGNED→int≥0, ENUMERATED→non-empty string, CHARACTER_STRING→non-empty string, OBJECT_ID→`{objectTypeName,objectInstance:number}`; miele analog sums **EXACT ±0.05**, object-name **exact bare string**; typed `/combined` via P8 **and** `cert-scf-matrix` (7/0, all 6 analog profiles flow). **Reveals any type/shape break in the C++→`vrpc::json` marshalling.** |
| **P2 — Large-array recovery >1476** (primary deliverable) | `func-array-e2e.sh` + qa-trio `mega-scale-test.js`; `discovery-e2e.sh`; qa-trio `miele-scenario-test.js`/`miele-load-test.js` | each large array == **FULL ordered baseline, 0 corrupt** under churn (e2e: `len>=N && unique==len && well-formed==len`); ReadRange chunks reassembled in order; scalar re-gate makes **EXACTLY ONE native read**, `reconnects===0`. **Reveals chunk-boundary, reorder, truncation, dupe, MAX_ARRAY (50k cap), skip-doomed-read bugs.** |
| **P3 — ABORT/REJECT classification** (no storm) | `abort-recovery-e2e.sh` + qa-trio `caveat-boundaries-test.js` | array on recoverable size-codes → recovers; scalar surfaces `abortReason` and **stays connected**; non-recovered abort raises no storm; unknown object **must NOT flow**. **Reveals misclassifying alive-but-limited as connection loss.** |
| **P4 — Lifecycle / idle silent-drop / reconnect** (CI-untested) | `lifecycle-e2e.sh` + qa-trio `reconnect-test.js`; qa-trio `cadence-test.js` | **`docker stop` the peer with no reads in flight** → idle health-probe detects silent drop → `reconnecting` → `docker start` → recovers → live read post-recovery → clean disconnect; cadence: first-poll jitter, polling **STOPS after disconnect (0 orphan polls)**. **Reveals the idle health-check path + timer leak.** |
| **P5 — Write integrity** (exact round-trip, 30 min) | `rw-soak-e2e.sh` | fresh random REAL/UINT/BOOL each round, exact round-trip; DEGRADED on any mismatch / `tsm>0` / write-error>0. **Reveals forced-tag, multi-value, payload-shaping, silent write-drop bugs.** |
| **P6 — Scale + soak** (no leak, 30 min) | `scale-soak-e2e.sh`; `soak_monitor.py`; qa-trio `scale-integrity-test.js` | **EXACT value-match** every receive, re-verify all devices every 5 min; mem flat; fingerprinted, **ZERO mismatch**, p99<1500ms; **legacy IID silent = FAIL**. **Reveals corruption-under-load, leak, TSM exhaustion, cross-talk.** |
| **P7 — Constrained-device adaptivity & isolation** | `isolation-e2e.sh` + qa-trio `factory-storm-test.js` | slow/wedged peer doesn't starve healthy reads (≥45/50); **500-burst ≥250 ok, no OOM**; constrained-APDU scalars fit without needless indexed reads. **Reveals APDU adaptivity, bounded queue, slow-peer isolation.** |
| **P8 — Cert / production realism** (real-SCF) | `miele-spectrum-e2e.sh`; qa-trio `weatherstation-test.js` | classifies FLOW/GRACEFUL/DEGRADED/FAIL: FLOW needs `/combined` with exact engineering units; missing one point yields **actionable errors** (`not present on device`) with no faked data, other points keep flowing. **Reveals describeBacnetError + graceful-missing-point + mapping correctness.** |

## §6 — Turnkey run order (this ordered sequence IS the full suite)

No single master "run-all" exists. Every phase brings its sim compose **up first**,
then runs a turnkey script that generates → uploads → enables → verifies → tears
down. Each prints `RESULT: PASS` / `==> RESULT: N passed, 0 failed` and exits
non-zero on failure. Which compose maps to which phase, and the port-collision
pairs you must not co-run, are in `docs/PROFILES.md`.

> Run Part 2 from a **clean baseline** — bring up only the compose each phase needs,
> not every fleet from Part 1 at once. P1's capture windows are generous (object-list
> and `/combined` topics recover slowly), but a host saturated with ~50 stacked sims
> can still starve them. If you just finished Part 1, `docker compose down` the
> Part-1-only fleets before starting here.

```bash
# from the cybus_BACnet_simulator root
qa/tools/cw-clean-all.sh                                    # wipe prior services

# fast in-process pre-gate (real UDP, no CW) — catches logic bugs in minutes
( cd qa/inproc/qa-trio && ./test.sh )

docker compose -f compose.yaml up -d                       # baseline sims

# P1 — value-type marshalling integrity (run FIRST — the highest-risk path)
# NOTE: these two scripts EXIT NON-ZERO by design (the documented known-misses below) —
# judge them by the SUMMARY/RESULT text, NOT $?. Every other script in this guide exits 0.
qa/e2e/spectrum-deploy.sh && qa/e2e/spectrum-verify.sh   # expect: SUMMARY: 39/40 PASS (1 known edge: EmptyDevice 1-elem object-list, R5)
qa/e2e/cert-scf-matrix-e2e.sh                             # expect: RESULT: 7 passed, 0 failed (6 analog profiles flow /combined, empty has none)

# P2 — large-array recovery >1476
docker compose -f compose/mega.compose.yaml -f compose/bigarray.compose.yaml -f compose/largescale.compose.yaml -f compose/huge.compose.yaml up -d
qa/e2e/func-array-e2e.sh                                  # expect: RESULT: PASS
qa/e2e/discovery-e2e.sh                                   # expect: ==> RESULT: N passed, 0 failed

# P3 — abort/reject classification (no storm)
qa/e2e/abort-recovery-e2e.sh                             # expect: ==> RESULT: N passed, 0 failed

# P4 — idle silent-drop reconnect (CI-untested path)
docker compose -f compose/reconnect.compose.yaml up -d
qa/e2e/lifecycle-e2e.sh                                  # expect: ==> RESULT: N passed, 0 failed

# P5 — write soak 30 min  (quick: SOAK_MIN=2 ROUND_S=15 qa/e2e/rw-soak-e2e.sh)
docker compose -f compose/rw-fleet.compose.yaml up -d
qa/e2e/rw-soak-e2e.sh                                    # expect: RESULT: PASS

# P6 — scale soak 30 min  (quick: SOAK_MIN=5 qa/e2e/scale-soak-e2e.sh)
docker compose -f compose/scale-fleet.compose.yaml -f compose/miele-fleet.compose.yaml up -d   # synth meters + real concentrators
qa/e2e/scale-soak-e2e.sh                                 # expect: RESULT: PASS

# P7 — isolation + cadence
qa/e2e/isolation-e2e.sh ; qa/e2e/cadence-e2e.sh         # expect: ==> RESULT: N passed, 0 failed

# P8 — cert / production realism
docker compose -f compose/weatherstation.compose.yaml up -d
qa/e2e/miele-spectrum-e2e.sh                             # expect: every profile FLOW or GRACEFUL, no FAIL

qa/tools/cw-clean-all.sh                                    # teardown
```

**Minimum bar to call the branch production-validated:** green, in order,
**P1 → P2 → P3 → P4 → P5 → P6** (P7/P8 are the realism confirmation). Any
`RESULT: FAIL`, non-zero exit, or PM red flag → stop and triage that phase.

## §7 — Gaps — DO NOT claim these are covered

| Not covered | Why |
|---|---|
| **Real cross-subnet BBMD forwarding** | only FDR frame + TTL renewal tested (`bbmd_service.py` sink); everything is loopback. Needs real 2-subnet hardware. |
| **Some ABORT codes** (no simulator producer) | see the abort-code coverage in [docs/TEST-MATRIX.md](docs/TEST-MATRIX.md). |
| **OCTET_STRING / BIT_STRING / DATE / TIME values** | bacpypes objects don't emit these tags — marshalling kept as bactext string by design; confirm by unit if it matters. |
| **Malformed value / spoofed invoke_id** | requires a malicious server. |
| **Write depth** (explicit tag, read-only object, priority extremes, write-when-disconnected) | `manual`; only exact round-trip on commandable points is automated. |
| **Native protocol COV** | this branch is polling-only; COV sims/tests belong to the separate COV feature. |

---

# PART 3 — REFERENCE

## R1. Log lines — what each one means

Levels: `20` debug · `30` info · `40` warn · `50` error · `60` fatal. **Healthy =
only ≤40.** Messages quoted exactly from the code (`protocol-mapper/src/protocols/bacnet/`).
Poll-read failures appear wrapped as `BestEffortPoll: Read failed when polling
because: <message>` — match the `<message>` part against the rows below.

### Normal — you will see these, they are fine
| Message | Lvl | Means |
|---|---|---|
| `Property exceeds one APDU; switching to chunked array reads` | 30 | A big array didn't fit one frame; adapter switched to chunked reads. Working as designed — confirm the full array reaches MQTT. |
| `Liveness probe got ABORT/REJECT; peer alive, not counting as loss` | 40 | Health probe got a busy-reply, not silence. Device alive; correctly not a disconnect. |
| `BACnet device reachable but returned "<err>" on connect probe; proceeding` | 40 | Device answered the connect probe busy; adapter connects anyway. Fine unless reads also fail. |

### Seen during tests (and only a worry in production)
| Message | Lvl | When it's expected |
|---|---|---|
| `Maximum concurrency reached, request canceled` | thrown | Workload (Step 1) and pool-pressure tests. In prod = too many stuck devices (R4). |
| `BACnet write value must be a primitive, got array\|object` | thrown | The "reject a non-primitive write" test. In prod = a bad write payload. |
| `BACnet liveness probe timed out` → `Health check failed (n/3)` | 40 | Reconnect tests (sim dropped on purpose). In prod = device actually down. |
| `Failed to reach BACnet device[ on reconnect]: <err>` | 40 | Connect/reconnect tests; also a **fleet not finished starting**. In prod = device/network down. |
| `<point> read failed: BACnet ABORT (…): Application Exceeded Reply Time` | 40 | abort-recovery / func-array / busy-device tests. In prod = device too slow or response too large; the adapter recovers (array → ReadRange) or retries. |

### Config errors — the SCF is wrong, not the adapter  (point format: `objectType:objectInstance 'property'`)
| Message | Fix |
|---|---|
| `<point> not present on device — correct this point's objectInstance/objectType … or disable it [<raw>]` | The object isn't on the device. Check its object list; fix or remove the endpoint. |
| `<point> present but property is invalid for this object — correct the endpoint's property … [<raw>]` | Usually a typo — property names are case-sensitive, hyphenated (`present-value`, not `present_value`). |
| `<point> <read\|write> failed: <raw>` | Other protocol error (access denied, type mismatch, read-only). Read `<raw>`. |

### Investigate
| Message | Lvl | Means |
|---|---|---|
| `BacnetClient - WARN ignoring divergent tuning on reuse: <keys>; first-Connection values stay in effect process-wide` | warn | Two Connections asked for different tuning; first wins. Align tuning or split instances (R4). |
| `BBMD registration to <addr> failed` | 40 | Remote-subnet registration failed; those devices won't be reachable. Check the BBMD address. |
| any `"level":50` / `"level":60` | 50/60 | Never expected in a healthy run. Capture and file a defect. |

> Brief base-class lines during fast disconnect/redeploy (`bestEffortPoll …
> callback … does not exist`, `subscription … no longer available`) are harmless
> teardown races — note, don't block.

### Step-1 failures
| Symptom | Cause → fix |
|---|---|
| `EADDRINUSE :::4780x` | Old sim still up → `lsof -i :47808-:47812`, stop it, wait 10 s |
| `Connection refused` / build fails | Docker not running → `docker ps` must work |
| `SKIP: simulator not ready` | Sim didn't come up → re-run; check the `bacnet-server` container logs |
| coverage below floor (tests pass, run red) | A code path lost test coverage → see the `nyc` report under `test/coverage` |
| an `it()` fails | Real regression → the test title names the behavior; capture logs, file a defect |
| won't start at all | Node not v24 → fix `node --version` first |

---

## R2. CW test catalog — which script uploads which SCF, and which sim it needs

Two SCF shapes: **standalone** (`qa/scf/*.yml` — one self-contained file) and
**connection + receive pair** (`qa/scf/<area>/…` — a parameterized connection SCF plus
a receive SCF that references it; the script uploads both and fills host/port/
instance). Per-device facts (ports, instances) are in `docs/PROFILES.md`.

| Script (`qa/e2e/`) | SCF(s) it uploads | Sim(s) that must be up | What it verifies |
|---|---|---|---|
| `lifecycle-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml` + `qa/scf/lifecycle/lifecycle_recv.yaml` | `bacnet-modern` | connect → idle drop → health-check → reconnect |
| `cadence-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml` + `qa/scf/cadence/cad_recv.yaml` | `bacnet-modern` | poll timing + first-poll jitter; no orphan poll |
| `func-array-e2e.sh` | `qa/scf/zz_objectlist.yml` | `bacnet-huge` *(`compose/huge.compose.yaml`, port 47860)* | big-array recovery — every element on MQTT (`len`/`unique`/`well-formed`) |
| `abort-recovery-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml` + `qa/scf/abort/abort_recv.yaml` | `bacnet-miele` + `bacnet-reply-time-storm` | ABORT/REJECT handled, no reconnect storm |
| `discovery-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml` + `qa/scf/discovery/discovery_recv.yaml` | `bacnet-modern` + `bacnet-legacy` + `bacnet-mega-b` *(`compose/largescale.compose.yaml`)* | capability discovery + 20k object-list (strict integrity) |
| `isolation-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml` + `qa/scf/lifecycle/lifecycle_recv.yaml` | `bacnet-modern` + `bacnet-ultra-slow` | one slow/dead device doesn't affect others |
| `miele-mqtt-e2e.sh` | generated by `gen-miele-map.sh` from `qa/scf/miele/` | 4 concentrators (`gen-miele-profiles.sh` + `compose/miele-fleet.compose.yaml`) | real Miele fleet, typed integrity |
| `miele-spectrum-e2e.sh` | generated by `spectrum-deploy.sh` from `qa/scf/miele/` | core `compose.yaml` fleet | full production spectrum |
| `cert-scf-matrix-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml` + cert fixtures (`system-test-fixtures/.../_bacnet_miele_missing_rainCurrent/`) | core sim fleet | real customer cert SCFs |
| `scale-soak-e2e.sh` | generated by `gen-scale-fleet.sh` | `compose/scale-fleet.compose.yaml` (28 synth) **+** `compose/miele-fleet.compose.yaml` (4 concentrators) | 30-min read integrity, no leak |
| `rw-soak-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml` + `qa/scf/rw/rw_recv.yaml` | `compose/rw-fleet.compose.yaml` | 30-min write→readback integrity |

**Helpers:** `cw-clean-all.sh` (wipe all CW services) · `verify.sh <cw-host> <scf>`
(deploy one SCF, check MQTT + log → `PASS: All endpoints publishing`) ·
`deploy-scfs.sh` (bulk deploy+enable) · `generate-scf.sh <ip> <profile|--all> [name]`.

### R2.1 — exact SCFs uploaded & service IDs enabled, per script

Each script `POST`s every SCF below (base64'd) to `/api/services` then
`PUT …/operation {enable}`. The **service IDs** are the names you'll see in
Connectware and on MQTT (`services/<id>/…`). Connection and receive SCFs deploy as
**separate** services (receive `!ref`s the connection).

| Script | SCF file(s) uploaded | Service IDs created + enabled |
|---|---|---|
| *(by hand, R3)* | `modern_controller` (generated on demand — R3) | `demo` |
| `lifecycle-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml`, `qa/scf/lifecycle/lifecycle_recv.yaml` | `conn_life`, `recv_life` (+ `conn_dead`) |
| `cadence-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml`, `qa/scf/cadence/cad_recv.yaml` | `conn_cad`, `recv_cad` |
| `isolation-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml`, `qa/scf/lifecycle/lifecycle_recv.yaml` | `conn_fast`+`recv_fast`, `conn_slow`+`recv_slow`, `conn_bogus`+`recv_bogus` |
| `abort-recovery-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml`, `qa/scf/abort/abort_recv.yaml` | `conn_miele`+`recv_miele`, `conn_rts`+`recv_rts` |
| `discovery-e2e.sh` | `qa/scf/lifecycle/connection_hc.yaml`, `qa/scf/discovery/discovery_recv.yaml` | `conn_modern`+`recv_modern`, `conn_legacy`+`recv_legacy`, `conn_mega`+`recv_mega` |
| `func-array-e2e.sh` | `qa/scf/zz_objectlist.yml` | `funcarr` |
| `rw-soak-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml`, `qa/scf/rw/rw_recv.yaml` | per device ×32: `conn_rw_<instance>`, `recv_rw_<instance>` |
| `scale-soak-e2e.sh` | `qa/scf/miele/connection_bacnet.yaml`; real: `qa/scf/miele/receive_services/receive_bacnet_TotalElectricalEnergyConsumption_DA_115_<da>.yaml`; synth: a generated receive template | per device ×32: `conn_<instance>`; receives `recv_<da>` (106 total) |

---

## R3. Deploy + read a point by hand (and the MQTT primer)

A quick manual check. Device SCFs are **generated on demand** from their sim
profile (the profile is the source of truth for port/instance/objects) — generate
the `modern` device SCF, then deploy it as service id `demo`.

```bash
# from the cybus_BACnet_simulator root, with bacnet-modern up:
bash qa/tools/generate-scf.sh 172.18.0.1 profiles-cybus/modern_controller.yaml modern_controller  # -> qa/scf/modern_controller.yml

API=https://localhost/api
TOKEN=$(curl -sk -X POST "$API/login" -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"admin"}' | jq -r .token)

curl -sk -H "Authorization: Bearer $TOKEN" -X POST "$API/services" -H 'Content-Type: application/json' \
  -d "{\"id\":\"demo\",\"commissioningFile\":\"$(base64 -w0 < qa/scf/modern_controller.yml)\",\"parameters\":{}}"
curl -sk -H "Authorization: Bearer $TOKEN" -X PUT "$API/services/demo/operation" \
  -H 'Content-Type: application/json' -d '{"operation":"enable"}'

mosquitto_sub -h localhost -p 1883 -u admin -P admin -v -t 'services/demo/#'
```

Under the hood every upload does: `POST /api/login`→token · `POST /api/services
{id, commissioningFile:<base64 -w0 SCF>, parameters}` · `PUT …/operation
{"operation":"enable"}` · poll `GET /api/v2/services` until `currentState==enabled`
· MQTT on `services/<metadata.name>/#` · teardown `disable`→`DELETE`.

### Subscribe (read) — payload is always `{"value": <v>, "timestamp": <ms>}`
```bash
mosquitto_sub -h localhost -p 1883 -u admin -P admin -v -t 'services/demo/#'   # everything
mosquitto_sub -h localhost -p 1883 -u admin -P admin    -t 'services/demo/AI1'  # one point
```

| BACnet object | Example payload | JS type |
|---|---|---|
| analog-input / analog-value (REAL) | `{"value":21.97,"timestamp":…}` | float |
| analog-output | `{"value":50,"timestamp":…}` | number |
| binary-input / binary-value | `{"value":"active"}` / `{"value":"inactive"}` | string enum |
| multi-state-value | `{"value":3}` | int |
| character-string | `{"value":"Boiler-2"}` | string |

### Publish (write) — a write endpoint exposes a `.../set` topic
The read `demo` above (`modern_controller`) is **read-only**. Writes need a writable
endpoint: the `qa/scf/rw/rw_recv.yaml` pair exposes `rw/av0w` (it `!ref`s a connection,
so it's deployed together with `qa/scf/miele/connection_bacnet.yaml`) — this is the pair
`rw-soak-e2e.sh` deploys. Against the service it's enabled as (`<svc>`), publish the
**raw** value, then read the paired read-topic back; `write.propertyTag` in the SCF
forces the BACnet type (this catches forced-tag / payload bugs):

```bash
mosquitto_pub -h localhost -p 1883 -u admin -P admin -t 'services/<svc>/rw/av0w/set' -m '42.5'
mosquitto_sub -h localhost -p 1883 -u admin -P admin -t 'services/<svc>/rw/av0' -C 1
```

| Write datatype | `propertyTag` | Example `-m` |
|---|---|---|
| REAL (AnalogValue) | 4 | `42.5` |
| Unsigned (MultiStateValue) | 2 | `3` |
| Boolean/Enumerated (BinaryValue) | see `qa/scf/rw/rw_recv.yaml` | `1` / `active` |

Tear down: `PUT /api/services/demo/operation {"operation":"disable"}` then
`DELETE /api/services/demo`, and `rm qa/scf/modern_controller.yml` (the generated SCF —
it isn't committed). `cw-clean-all.sh` wipes all CW services between runs.

---

## R4. What the adapter can and can't do

**Can:** read/write any of the 60 BACnet object types and any property, by name,
on a poll (default 1000 ms, min 100 ms, or cron) · typed values (REAL→number,
ENUMERATED→text like `"active"`, OBJECT_ID→`{type,instance}`, etc.) · write
priority 1–16, `null` to relinquish · auto-recover big arrays · BBMD for remote
subnets · auto-reconnect on lost link.

**Can't — and why it matters:**

| Can't | Why | What to tell the customer |
|---|---|---|
| Event push (COV) | polling-only this release | every value is on an interval; use 100–500 ms for fast points |
| Recover an oversized **single** value (huge string/list) | the stack can't segment a non-array | rare; shows as one failed read and is skipped (never partial data) |
| Tune devices independently in one instance | all Connections share one client + tuning set (first-writer-wins) | put slow/legacy devices in a separate protocol-mapper instance |
| Handle unlimited stuck devices | shared 255-slot pool; ~**32 stuck** (not 32 healthy) peers saturate it | past that → `Maximum concurrency reached`; lengthen intervals or split instances |
| Discover devices (Who-Is) | static addressing only | devices need fixed IPs / DHCP reservations |
| More than one BBMD per instance | single process-wide registration | one instance per subnet/BBMD |

---

## R5. Scripts & SCFs catalog

### `qa/e2e/` — the certification battery (the scripts this guide runs)
Each is turnkey: clean-slate CW → upload+enable its SCF(s) → assert on MQTT → tear
down (which SCF each uses is in **R2 / R2.1**).
- **Device-variance e2e** (Step 4): `lifecycle-e2e` · `cadence-e2e` · `isolation-e2e`
  · `abort-recovery-e2e` · `discovery-e2e` · `func-array-e2e`.
- **Soaks** (Step 5 / P5–P6): `scale-soak-e2e` (read integrity) · `rw-soak-e2e`
  (write round-trip).
- **Typed-marshalling** (P1): `spectrum-deploy` + `spectrum-verify` (~40-case
  read-spectrum → `SUMMARY: 39/40 PASS`; the lone miss is the `F-01` EmptyDevice
  1-element object-list — a benign shape edge, not a read failure; object-list
  recovery itself is proven by `func-array`/`discovery`). `cert-scf-matrix-e2e`
  (real cert WeatherStation, **7/0** — 6 profiles flow `/combined`, empty has none).
- **Production realism** (P8): `miele-spectrum-e2e` · `miele-mqtt-e2e`.

### `qa/` support utilities — `gen/` `tools/` `soak/` `bbmd/` (the battery calls these; rarely run by hand)
**`qa/gen/` — fleet generators** the soaks invoke to build their sim fleets on demand:
- `gen-scale-fleet.sh` — read-soak fleet: 28 synthetic profiles + `compose/scale-fleet.compose.yaml`,
  each device a unique static value for exact integrity.
- `gen-rw-fleet.sh` — write-soak fleet: N writable devices (REAL/UINT/BOOL), static
  so a read-back == the last write, + `compose/rw-fleet.compose.yaml`.
- `gen-miele-profiles.sh` / `gen-miele-map.sh` — the 4 real Miele concentrators +
  `compose/miele-fleet.compose.yaml` from the production SCFs (the value map is the baseline).

**`qa/tools/` — helpers** — `cw-clean-all.sh` (wipe all CW services; run between
phases) · `deploy-scfs.sh <cw-host> [scf]` (bulk deploy + auto-enable `qa/scf/*.yml`).

**`qa/tools/` — manual device-onboarding, NOT part of the certification battery.** No `*-e2e.sh`
uses these; they're for ad-hoc testing of a *new or real* device that has no
committed scenario SCF:
- `generate-scf.sh <ip> <profile|--all> [name]` — turn a sim **profile** into a
  deployable **SCF**. The profile is the single source of truth, so device SCFs are
  generated on demand, not committed.
- `verify.sh <cw-host> <scf>` — deploy that one SCF and check its data flows on MQTT
  (live only) + the PM log is clean → `RESULT: PASS`.

**`qa/soak/` — auxiliary soaks** (not in the cert battery) — `ws-integrity-soak` ·
`ws-overload-soak` · `memory-qualify`.

**`qa/bbmd/`** — `bbmd_service.py` (FDR sink; loopback only).

### SCFs (`qa/scf/`)
Device SCFs are **generated on demand** from sim profiles — the profile is the
single source of truth (port, instance, object count, abort/reject code; all in
`docs/PROFILES.md`). Generate one with `generate-scf.sh <sim-ip> profiles-cybus/<name>.yaml`,
or all at once with `generate-scf.sh <sim-ip> --all`; check one by hand with
`verify.sh <cw-host> <scf>`.

- **Device SCFs — generated, not committed.** One per profile in `profiles-cybus/`:
  `modern_controller` · `legacy_controller` · `green_energy_ebmgr` · `newlift_gateway`
  · `no_rpm_controller` · `abort_segmentation` · `ultra_slow` · `empty_device` ·
  `miele_energy_meter` · `miele_overloaded` · the miele clones (and the soak/spectrum
  fleets, built by their `gen-*` scripts). The only **committed** standalone is
  `qa/scf/zz_objectlist.yml` (the large object-list fixture for `func-array-e2e.sh`).
- **Connection + receive pairs:** `qa/scf/lifecycle/` (`connection_hc.yaml` +
  `lifecycle_recv.yaml`) · `qa/scf/cadence/cad_recv.yaml` · `qa/scf/discovery/discovery_recv.yaml`
  · `qa/scf/abort/abort_recv.yaml` · `qa/scf/rw/rw_recv.yaml` · `qa/scf/miele/`
  (`connection_bacnet.yaml` + `connections/` + `receive_services/` — the production fleet).
- **Cert SCF** (real regression fixture, deployed by `cert-scf-matrix-e2e.sh`):
  `../system-test-fixtures/regression-tests/_bacnet_miele_missing_rainCurrent/receive_bacnet_cov-endpoint_with-mapping_service.yaml`.

---

## R6. Related docs

| Doc | What it covers |
|---|---|
| [docs/PROFILES.md](docs/PROFILES.md) | **single source of truth** — per-profile ports, instances, object counts, abort/reject codes, behaviour, port-collision pairs |
| [docs/TEST-MATRIX.md](docs/TEST-MATRIX.md) | the per-case coverage matrix (what's tested, what's not) |
| `README.md` | simulator overview + how to run the simulator |
| `docs/qa-handover/README.md` | the hybrid-COV acceptance hand-off (separate COV feature) |

**Confluence reference set** (adapter behaviour, schema, operations — published, not in this repo):
Overview · Configuration Reference · Operator Runbook · Troubleshooting & Errors ·
Capabilities & Limitations · QA Verification Guide.

---

**End.**
