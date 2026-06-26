#!/usr/bin/env node
/**
 * Miele-faithful e2e. The real SCFs read 6 analog-value present-values per meter
 * (SumRealPower 101009, SumRealEnergy, ...) on devices hosting large object
 * inventories, polled at 1s. This exercises all three real paths against the SUT:
 *
 *   1. Failing meter  — device ABORTs present-value (reason 1 buffer-overflow, the
 *      Mar-4 mode): must surface honestly, stay connected (no storm), and after the
 *      array re-gate make exactly ONE read (no index-0 probe doubling load).
 *   2. Healthy meter  — present-value returns real data.
 *   3. Large array    — a too-large object-list recovered element-by-element on a
 *      small-APDU device (the feature is NOT cut by the scalar re-gate).
 *
 * Read-count is measured by spying the native readProperty (the C-stack boundary),
 * with the liveness probe disabled so the count is exact. No mocks over the SUT.
 */
'use strict'
process.env.NODE_CONFIG_DIR = '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = 'test'
const pmRoot = '/home/dj/CW/CW_2.x/cybus/protocol-mapper'
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const {
  SIM, mkResults, record: _record, cleanup,
} = require('./_harness')
const RESULTS = mkResults()
const record = (n, ok, d) => _record(RESULTS, n, ok, d)
const sleep = (ms) => new Promise((r) => { setTimeout(r, ms) })

const mk = (key) => {
  const d = SIM[key]
  return new BacnetConnection({
    id: `miele-${key}`,
    connection: {
      localInterface: 'lo',
      localPort: 49100,
      deviceAddress: d.addr,
      deviceInstance: d.id,
      healthCheck: { intervalMs: 0 }, // disable probe so the read-count spy is exact
    },
    targetState: 'disconnected',
  })
}

// Spy the native readProperty (C-stack boundary) to count reads per logical op.
const instrument = (conn) => {
  const c = conn._bacnetClient
  const orig = c.readProperty.bind(c)
  const ctr = { n: 0 }
  c.readProperty = (...a) => { ctr.n += 1; return orig(...a) }
  return { ctr, restore: () => { c.readProperty = orig } }
}

const main = async () => {
  console.log('=== Miele-faithful e2e: present-value energy reads + large arrays ===')

  // 1. Failing meter — present-value ABORTs reason 1 (Mar-4 mode).
  const ab = mk('abortStorm')
  await ab.connect().catch(() => {})
  await ab.waitUntilStateEnters('connected', 8000).catch(() => {})
  const spyA = instrument(ab)
  spyA.ctr.n = 0
  let reason = null
  try {
    await ab.handleRead({ objectType: 'analog-value', objectInstance: 101009, property: 'present-value' })
  } catch (e) { reason = e.abortReason }
  const reads = spyA.ctr.n
  spyA.restore()
  record('failing meter: present-value surfaces reason 1 (no faked data)', reason === 1, `abortReason=${reason}`)
  record('failing meter: scalar re-gate makes exactly ONE read (no index-0 probe)', reads === 1, `native readProperty calls=${reads}`)
  record('failing meter: stays connected (no reconnect storm)', ab.getState() === 'connected', ab.getState())
  await cleanup([ab])
  await sleep(300)

  // 2. Healthy meter — present-value returns real data.
  const ok = mk('modern')
  await ok.connect().catch(() => {})
  await ok.waitUntilStateEnters('connected', 8000).catch(() => {})
  let pvVal; let pvOk = false
  try {
    const r = await ok.handleRead({ objectType: 'analog-value', objectInstance: 1, property: 'present-value' })
    // modern AV1 (cooling_setpoint) is a static 24.0 — assert the exact reading,
    // not merely "not null" (which would pass for 0 / false / '' / a string).
    pvOk = r && typeof r.value === 'number' && Math.abs(r.value - 24) < 0.01
    pvVal = r.value
  } catch (e) { pvVal = e.message }
  record('healthy meter: present-value == 24 (real numeric reading, not faked)', pvOk, `value=${JSON.stringify(pvVal)}`)
  await cleanup([ok])
  await sleep(300)

  // 3. Large array — too-large object-list recovered element-by-element (NOT cut).
  const big = mk('miele')
  await big.connect().catch(() => {})
  await big.waitUntilStateEnters('connected', 8000).catch(() => {})
  const spyM = instrument(big)
  spyM.ctr.n = 0
  let arr = null; let arrErr = null
  try {
    const r = await big.handleRead({ objectType: 'device', objectInstance: SIM.miele.id, property: 'object-list' })
    arr = r && r.value
  } catch (e) { arrErr = e.message }
  const arrReads = spyM.ctr.n
  spyM.restore()
  record('large array: too-large object-list recovered element-by-element (NOT cut)',
    Array.isArray(arr) && arr.length > 10,
    Array.isArray(arr) ? `${arr.length} elements via ${arrReads} indexed reads` : `err=${arrErr}`)
  await cleanup([big])

  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
