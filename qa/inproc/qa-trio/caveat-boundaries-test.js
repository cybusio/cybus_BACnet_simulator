#!/usr/bin/env node
/**
 * Caveat-boundary test — proves the documented limits of the adapter's
 * three "honest caveats" with real simulator traffic (no mocks over the SUT).
 *
 * Each scenario pins a boundary that a future refactor might silently cross:
 *
 *   C1  indexed-array fallback is NOT real segmentation. It recovers a
 *       too-large ARRAY (object-list) element-by-element, but a too-large
 *       SCALAR (present-value) has no element decomposition and must surface
 *       as an error — never silently fabricated into data.
 *       (property-gating: same too-large reason, opposite outcome by property)
 *
 *   C2  APDU tuning is process-wide, first-writer-wins. Two Connections with
 *       divergent apduTimeoutMs share one C-stack global; production
 *       _warnIfTuningDiverges keeps the first value and warns that the second
 *       is ignored. The warning is the observable behaviour we assert.
 *
 *   C3  a reply-time abort (reason 8) is surfaced, never recovered. On the
 *       SAME property C1 recovers (object-list), reason 8 is not a size
 *       problem, so the indexed fallback must not engage — the abort
 *       propagates and the connection stays connected (an ABORT is alive).
 *       (reason-gating: same property, opposite outcome by abort reason)
 *
 * Run:
 *   NODE_CONFIG_DIR=$PWD/config NODE_ENV=test \
 *     node --require ./src/protocols/bacnet/test/qa-loader.js \
 *     <simulator-repo>/qa/inproc/qa-trio/caveat-boundaries-test.js
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const assert = require('assert')
const pmRoot = process.env.PM_ROOT || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)

const {
  SIM, mkResults, record: _record, cleanup, buildConn: _buildConn,
} = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)
const buildConn = (id, localPort, devKey, extra = {}) =>
  _buildConn(BacnetConnection, id, localPort, devKey, extra)

// Capture console.warn emitted during fn(); restore unconditionally.
const captureWarn = async (fn) => {
  const warnings = []
  const orig = console.warn
  console.warn = (...args) => { warnings.push(args.join(' ')) }
  try {
    await fn()
  } finally {
    console.warn = orig
  }
  return warnings
}

// ── C2: process-wide APDU timeout is first-writer-wins ──────────────────
// MUST run first: the BacnetClient singleton — and the C-stack timeout global —
// is created by the first BacnetConnection constructed in this process.
const c2_apduTimeoutLww = async () => {
  console.log('\n── C2: process-wide APDU timeout is first-writer-wins ──')
  const connA = buildConn('c2-a', 48010, 'miele', {
    apduTimeoutMs: 3000, healthCheck: { intervalMs: 0 },
  })
  let connB
  // The divergence warning fires at connB's construction (singleton reuse):
  // production _warnIfTuningDiverges keeps the first value and ignores the
  // second. That warn is the observable production behaviour we assert.
  const warnings = await captureWarn(() => {
    connB = buildConn('c2-b', 48011, 'modern', {
      apduTimeoutMs: 10000, healthCheck: { intervalMs: 0 },
    })
  })
  await connA.connect()
  await connB.connect()
  await Promise.all([
    connA.waitUntilStateEnters('connected', 5000).catch(() => null),
    connB.waitUntilStateEnters('connected', 5000).catch(() => null),
  ])
  const warned = warnings.some((w) => w.includes('apduTimeoutMs=10000') && w.includes('3000'))
  await cleanup([connA, connB])
  record('apdu-timeout: divergent second value (10000ms) warned, first (3000ms) stays',
    warned, warnings.find((w) => w.includes('apduTimeoutMs')) || 'no divergence warn captured')
}

// ── C1: indexed fallback recovers arrays, never scalars ─────────────────
const c1_indexedFallbackScope = async () => {
  console.log('\n── C1: indexed fallback recovers arrays, never scalars ──')

  // Array side: miele aborts the whole object-list as too-large (reason 1) but
  // serves each element — indexed fallback (ASHRAE 135 §15.7) recovers it.
  const arrConn = buildConn('c1-miele', 48012, 'miele', { healthCheck: { intervalMs: 0 } })
  let arr
  try {
    await arrConn.connect()
    await arrConn.waitUntilStateEnters('connected', 5000)
    const r = await arrConn.handleRead({
      objectType: 'device', objectInstance: SIM.miele.id, property: 'object-list',
    })
    arr = { ok: true, isArr: Array.isArray(r.value), n: Array.isArray(r.value) ? r.value.length : 1 }
  } catch (err) {
    arr = { ok: false, err: err.message }
  }
  await cleanup([arrConn])
  record('indexed-fallback: too-large array (object-list) recovered element-by-element',
    arr.ok && arr.isArr && arr.n >= 50,
    arr.ok ? `elements=${arr.n}` : `err=${arr.err}`)

  // Scalar side: a too-large abort on present-value has no element-wise
  // decomposition — it must surface as an error, never become data.
  const scalarConn = buildConn('c1-abortStorm', 48013, 'abortStorm', { healthCheck: { intervalMs: 0 } })
  let scalar
  try {
    await scalarConn.connect()
    await scalarConn.waitUntilStateEnters('connected', 5000)
    const r = await scalarConn.handleRead({
      objectType: 'analog-value', objectInstance: 101009, property: 'present-value',
    })
    scalar = { recovered: true, value: r.value }
  } catch (err) {
    scalar = { recovered: false, abortReason: err.abortReason }
  }
  const state = scalarConn.getState()
  await cleanup([scalarConn])
  record('indexed-fallback: too-large scalar (present-value) surfaced, not recovered',
    scalar.recovered === false && scalar.abortReason === 1 && state === 'connected',
    scalar.recovered ? `WRONGLY recovered value=${scalar.value}`
      : `rejected abortReason=${scalar.abortReason} state=${state}`)
}

// ── C3: reply-time abort (reason 8) is surfaced, never recovered ────────
const c3_replyTimeSurfaced = async () => {
  console.log('\n── C3: reply-time abort (reason 8) is surfaced, never recovered ──')
  const conn = buildConn('c3-replyTimeStorm', 48014, 'replyTimeStorm', { healthCheck: { intervalMs: 0 } })
  let list = { recovered: false }
  let scalar = { recovered: false }
  try {
    await conn.connect()
    await conn.waitUntilStateEnters('connected', 5000)
    // Same property C1 recovers, but reason 8 is not a size problem: the
    // indexed fallback must not engage — the abort propagates unchanged.
    try {
      const r = await conn.handleRead({
        objectType: 'device', objectInstance: SIM.replyTimeStorm.id, property: 'object-list',
      })
      list = { recovered: true, n: Array.isArray(r.value) ? r.value.length : 1 }
    } catch (err) {
      list = { recovered: false, abortReason: err.abortReason }
    }
    try {
      const r = await conn.handleRead({
        objectType: 'analog-value', objectInstance: 101009, property: 'present-value',
      })
      scalar = { recovered: true, value: r.value }
    } catch (err) {
      scalar = { recovered: false, abortReason: err.abortReason }
    }
  } catch (err) {
    list = { recovered: false, err: err.message }
    scalar = { recovered: false, err: err.message }
  }
  const state = conn.getState()
  await cleanup([conn])
  record('reply-time: object-list (a fallback-eligible property) NOT recovered under reason 8',
    list.recovered === false && list.abortReason === 8,
    list.recovered ? `WRONGLY recovered n=${list.n}` : `rejected abortReason=${list.abortReason}`)
  record('reply-time: scalar present-value also surfaces reason 8',
    scalar.recovered === false && scalar.abortReason === 8,
    scalar.recovered ? `WRONGLY recovered value=${scalar.value}` : `rejected abortReason=${scalar.abortReason}`)
  record('reply-time: connection stays connected (an ABORT is proof-of-life)',
    state === 'connected', `state=${state}`)
}

const main = async () => {
  console.log('═══════════════════════════════════════════════════════════')
  console.log(' BACnet adapter — CAVEAT-BOUNDARY TEST')
  console.log(' Profiles: miele, abortStorm, replyTimeStorm, modern')
  console.log('═══════════════════════════════════════════════════════════')

  const overallStart = Date.now()
  try {
    await c2_apduTimeoutLww()
    await c1_indexedFallbackScope()
    await c3_replyTimeSurfaced()
  } catch (err) {
    console.error('\n[FATAL]', err.message)
    if (err.stack) console.error(err.stack)
    RESULTS.fail += 1
  }
  const totalSec = ((Date.now() - overallStart) / 1000).toFixed(1)

  console.log('\n═══════════════════════════════════════════════════════════')
  console.log(`RESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed (${totalSec}s)`)
  console.log('═══════════════════════════════════════════════════════════')
  if (RESULTS.fail > 0) {
    console.log('\nFailed scenarios:')
    RESULTS.tests.filter((t) => !t.ok)
      .forEach((t) => console.log(`  [${t.name}] ${t.detail}`))
  }
  try { assert.strictEqual(RESULTS.fail, 0) } catch (_) {
    process.exitCode = 1
  }
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 500)
}

main()
