#!/usr/bin/env node
/**
 * Cert read-pattern × device-profile matrix.
 *
 * Takes the cert WeatherStation/cov-endpoint read shape — a scalar analog-input
 * point read for {object-name, present-value, units}, plus a deliberately-absent
 * point — and runs it against every core device profile (fast/slow, big/small
 * APDU, segmented/not, RPM/no-RPM, abort-prone, empty). The question this answers
 * is "which device characteristic breaks the cert scalar read path, and how".
 *
 * Each present point must read EXACT (name == point name, present-value == the
 * profile's static default, units == the device unit). Each absent point must
 * degrade gracefully — an actionable "not present on device" error, no faked
 * data, connection stays connected, no abort storm. Profiles with no analog-input
 * (empty, newlift) exercise the all-missing degradation path. Strict + realistic:
 * built to surface adapter read-path regressions per device class, not to pass.
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const {
  SIM, mkResults, record: _record, cleanup,
} = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)

const PROPS = ['object-name', 'present-value', 'units']
const ABSENT_INST = 9999 // no profile defines this analog-input -> missing-object path
const DRIFT_BAND = 0.03 // sim drives analog-input with ±2% jitter; 3% band clears it, still catches a wrong/garbage read

// Per-profile cert read target: a known-present analog-input point (exact name /
// value / unit from the profile YAML), or present:false for devices with none.
// devKey maps into the shared SIM map (the running core compose fleet).
const MATRIX = [
  { devKey: 'modern', devId: 400001, label: 'fast 1476B segmented (baseline)', present: true, inst: 1, name: 'zone_temp', value: 22.0, units: 'degrees-celsius' },
  { devKey: 'legacy', devId: 300001, label: '206B noSeg slow (constrained APDU)', present: true, inst: 1, name: 'zone_temp_1', value: 22.3, units: 'degrees-celsius' },
  { devKey: 'miele', devId: 1014006, label: 'array-ABORT(1) device, scalar read', present: true, inst: 1, name: 'voltage_L1_N', value: 230.1, units: 'volts' },
  { devKey: 'energy', devId: 2000001, label: 'array-ABORT(11) device, scalar read', present: true, inst: 1, name: 'circuit1_supply_temp', value: 55.3, units: 'degrees-celsius' },
  { devKey: 'noRpm', devId: 600001, label: 'no ReadPropertyMultiple', present: true, inst: 1, name: 'zone_temp_1', value: 22.5, units: 'degrees-celsius' },
  { devKey: 'abortSeg', devId: 600002, label: 'ABORT(4) segNotSupported', present: true, inst: 1, name: 'zone_temp', value: 21.8, units: 'degrees-celsius' },
  { devKey: 'ultraSlow', devId: 600003, label: '12s response delay (deadline stress)', present: true, inst: 1, name: 'sensor_temp', value: 20.5, units: 'degrees-celsius' },
  { devKey: 'empty', devId: 600004, label: '0 objects (all-missing degradation)', present: false },
]

let nextPort = 48600
const mkConn = (devKey, devId) => new BacnetConnection({
  id: `certmx-${devKey}`,
  connection: {
    localInterface: 'lo',
    localPort: nextPort++,
    deviceAddress: SIM[devKey].addr,
    deviceInstance: devId,
    healthCheck: { intervalMs: 0 },
  },
  targetState: 'disconnected',
})

// One read; resolves { ok, value } | { ok:false, error } — never throws.
const readOne = (conn, inst, property) => conn
  .handleRead({ objectType: 'analog-input', objectInstance: inst, property })
  .then((r) => ({ ok: true, value: r && r.value }), (e) => ({ ok: false, error: e.message || String(e) }))

// A graceful missing-object error names the object + the SCF-actionable fix.
const isActionable = (err, inst) => err.includes(`analog-input:${inst}`)
  && err.includes('not present on device')
  && err.includes('objectInstance/objectType')

const probeAbsent = async (conn) => {
  let errored = 0
  let actionable = 0
  for (const prop of PROPS) {
    // eslint-disable-next-line no-await-in-loop -- sequential, mirrors a poll cycle
    const r = await readOne(conn, ABSENT_INST, prop)
    if (!r.ok) { errored += 1; if (isActionable(r.error, ABSENT_INST)) actionable += 1 }
  }
  return { errored, actionable }
}

// Returns a one-line verdict for the report: how this device class behaved.
const runProfile = async (m) => {
  const c = mkConn(m.devKey, m.devId)
  await c.connect().catch(() => null)
  await c.waitUntilStateEnters('connected', 16000).catch(() => null)
  const connected = c.getState() === 'connected'
  record(`[${m.devKey}] ${m.label}: connects`, connected, c.getState())

  if (m.present) {
    const [nm, pv, un] = await Promise.all(PROPS.map((p) => readOne(c, m.inst, p)))
    // name + units are static -> exact; present-value is a driven sensor with the
    // sim's ±2% drift, so assert a tight band around the profile default (strict
    // enough to catch a wrong-property/garbage/cross-object read, honest about live data).
    const nameOk = nm.ok && nm.value === m.name
    const pvOk = pv.ok && typeof pv.value === 'number' && Math.abs(pv.value - m.value) <= m.value * DRIFT_BAND
    const unitsOk = un.ok && un.value === m.units
    record(`[${m.devKey}] present point flows (name+units exact, value in ±2% drift band)`,
      nameOk && pvOk && unitsOk,
      `name=${nm.ok ? nm.value : nm.error.slice(0, 40)} value=${pv.ok ? pv.value : 'ERR'}(~${m.value}) units=${un.ok ? un.value : 'ERR'}`)
  } else {
    // No analog-input on this device: the "present" read is itself a miss -> must degrade.
    const r = await readOne(c, 1, 'present-value')
    record(`[${m.devKey}] all-missing: read of absent point degrades (no crash/fake)`,
      !r.ok && isActionable(r.error, 1), r.ok ? `FAKED value=${r.value}` : r.error.slice(0, 70))
  }

  const absent = await probeAbsent(c)
  record(`[${m.devKey}] absent point (inst ${ABSENT_INST}) errors gracefully + actionably`,
    absent.errored === 3 && absent.actionable === 3,
    `${absent.errored}/3 errored, ${absent.actionable}/3 actionable`)
  record(`[${m.devKey}] connection stays connected through the missing point`,
    c.getState() === 'connected', c.getState())

  await cleanup([c])
  return { devKey: m.devKey, connected, label: m.label }
}

const main = async () => {
  console.log(`[cert-matrix] cert scalar read {${PROPS.join(', ')}} + missing-object probe x ${MATRIX.length} device profiles`)
  const summary = []
  for (const m of MATRIX) {
    // eslint-disable-next-line no-await-in-loop -- one device at a time (shared C-stack listener)
    summary.push(await runProfile(m))
  }
  console.log(`\n  [i] per-profile: ${summary.map((s) => `${s.devKey}=${s.connected ? 'flowed' : 'NO-CONNECT'}`).join(' ')}`)
  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
