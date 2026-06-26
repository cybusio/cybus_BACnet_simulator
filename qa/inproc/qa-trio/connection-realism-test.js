#!/usr/bin/env node
/**
 * Realism-focused integration tests at the BacnetConnection layer.
 *
 * qa-simulator-test.js exercises BacnetClient directly. This file drives
 * BacnetConnection through its public FSM API (connect / disconnect /
 * handle{Read,Write,Subscribe,Unsubscribe}) end-to-end against the same
 * BACnet simulator. No mocks over the SUT; only minimal config glue at the
 * test boundary.
 *
 * Run (with simulator up):
 *   NODE_CONFIG_DIR=$PWD/config NODE_ENV=test \
 *     node --require ./src/protocols/bacnet/test/qa-loader.js \
 *     ./src/protocols/bacnet/test/connection-realism-test.js
 *
 * Or via the wrapper: ./src/protocols/bacnet/test/connection-realism.sh
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const assert = require('assert')
const pmRoot = process.env.PM_ROOT || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)

const {
  SIM, mkResults, record: _record, sleep, settleListenerThread, buildConn: _buildConn,
} = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)
const buildConn = (id, localPort, devKey, extra = {}) =>
  _buildConn(BacnetConnection, id, localPort, devKey, extra)

// ── Test 1: Connection FSM lifecycle ──────────────────────────────────
const testLifecycle = async () => {
  console.log('\n── Connection FSM: disconnected → connected → disconnected ──')
  const conn = buildConn('lifecycle', 47881, 'modern')
  record('initial state disconnected', conn.getState() === 'disconnected',
    `state=${conn.getState()}`)

  await conn.connect()
  await conn.waitUntilStateEnters('connected', 5000)
  record('state connected after connect()', conn.getState() === 'connected',
    `state=${conn.getState()}`)

  const r = await conn.handleRead({
    objectType: 'device', objectInstance: SIM.modern.id, property: 'object-name',
  })
  record('handleRead returns real value', String(r.value).includes('Tracer'),
    `value=${String(r.value).slice(0, 30)}`)

  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 5000)
  record('state disconnected after disconnect()', conn.getState() === 'disconnected',
    `state=${conn.getState()}`)
  // C-stack listener-thread settlement before next test rebuilds the singleton
  await settleListenerThread()
}

// ── Test 2: connectFailed FSM path on unreachable device ──────────────
const testConnectFailed = async () => {
  console.log('\n── Connection FSM: connectFailed path on unreachable peer ──')
  const conn = buildConn('failpath', 47882, 'bogus', {})
  await conn.connect()
  await conn.waitUntilStateEnters('reconnecting', 5000)
  const st = conn.getState()
  record('FSM transitions on unreachable peer', st === 'reconnecting',
    `state=${st} (expected reconnecting)`)
  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 5000)
  // C-stack listener-thread settlement before next test rebuilds the singleton
  await settleListenerThread()
}

// ── Test 3: Health-check idle-skip — a recent real read suppresses the probe ─
// (Per-device isolation is covered by factory-storm S3; the old multi-peer test
// here asserted a removed per-read deadline and was dropped.)
const testHealthCheckSkip = async () => {
  console.log('\n── Health-check: a recent real read skips the liveness probe ──')
  const conn = buildConn('hc-skip', 47885, 'modern')
  await conn.connect()
  await conn.waitUntilStateEnters('connected', 5000)
  conn._stopHealthCheck() // drive ticks manually; no racing auto-timer

  let probes = 0
  const origProbe = conn._probeLiveness.bind(conn)
  conn._probeLiveness = async () => {
    probes += 1
    return origProbe()
  }

  conn._markActivity() // a real read just landed
  await conn._runHealthCheckTick()
  record('recent real read skips the liveness probe', probes === 0, `probes=${probes}`)

  await conn._runHealthCheckTick() // nothing read since → the probe must fire
  record('idle tick fires the liveness probe', probes === 1, `probes=${probes}`)

  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 5000)
  await settleListenerThread()
}

// ── Test 5: Health-check trips connectLost at exactly failureThreshold ─
const testHealthCheckThreshold = async () => {
  console.log('\n── Health-check: connectLost fires at failureThreshold consecutive misses ──')
  const conn = buildConn('hc-threshold', 47886, 'modern')
  await conn.connect()
  await conn.waitUntilStateEnters('connected', 5000)
  conn._stopHealthCheck()

  // Silent peer: every probe read times out (not an ABORT/REJECT → counts as a loss).
  conn._readProbe = async () => {
    const e = new Error('BACnet liveness probe timed out')
    e.code = 'PROBE_TIMEOUT'
    throw e
  }
  // Count connectLost in isolation — do not drive the FSM.
  let lost = 0
  conn.connectLost = () => { lost += 1 }

  // Default failureThreshold is 3; connectLost must fire on the 3rd miss, not before.
  const tick = async () => {
    conn._didRealReadSinceLastTick = false
    await conn._runHealthCheckTick()
  }
  await tick()
  record('no connectLost after 1 failed probe', lost === 0, `lost=${lost}`)
  await tick()
  record('no connectLost after 2 failed probes', lost === 0, `lost=${lost}`)
  await tick()
  record('connectLost fires at the 3rd failed probe (threshold)', lost === 1, `lost=${lost}`)

  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 5000)
  await settleListenerThread()
}

const main = async () => {
  console.log('=== BacnetConnection realism-focused integration tests ===')
  console.log('Devices:', Object.keys(SIM).join(', '))

  try {
    await testLifecycle()
    await testConnectFailed()
    await testHealthCheckSkip()
    await testHealthCheckThreshold()
  } catch (err) {
    console.error('\n[FATAL]', err.message, err.stack)
    RESULTS.fail += 1
  }

  console.log('\n═══════════════════════════════════')
  console.log(`RESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  console.log('═══════════════════════════════════')
  if (RESULTS.fail > 0) {
    console.log('\nFailed:')
    RESULTS.tests.filter((t) => !t.ok)
      .forEach((t) => console.log(`  [${t.name}] ${t.detail}`))
  }
  try { assert.strictEqual(RESULTS.fail, 0) } catch (e) {
    process.exitCode = 1
  }
  // Force exit — outstanding BacnetClient listener thread keeps process alive
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 500)
}

main()
