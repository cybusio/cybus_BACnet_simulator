'use strict'

// COV hybrid + ongoing-notification e2e for the BACnet adapter.
//
// PART A — pxc100-cov (47841, dev 1014007, COV table cap 50, tsm pool 6, overload):
//   present-value endpoints subscribe via SubscribeCOV up to the device's table
//   cap; the excess fall back to polling (no endpoint goes dark); the 50 COV
//   subscriptions deliver their initial present-value correctly; teardown
//   (unsubscribe + disconnect) cancels cleanly.
//
// PART B — cov-emitter (47820, dev 900001, sine/sawtooth drivers):
//   a subscribed present-value delivers an ongoing stream of notifications whose
//   value actually moves over time (the real field behaviour: notify-on-change).
//
// Run via the qa-trio loader (host node, local .node).

const PM_ROOT = process.env.PM_ROOT || '/home/dj/CW/CW_2.x/cybus/protocol-mapper'
// eslint-disable-next-line import/no-dynamic-require
const BacnetConnection = require(`${PM_ROOT}/src/protocols/bacnet/BacnetConnection`)

const sleep = (ms) => new Promise((r) => { setTimeout(r, ms) })
const results = { pass: 0, fail: 0 }
const check = (name, ok, detail) => {
  results[ok ? 'pass' : 'fail'] += 1
  console.log(`  [${ok ? '+' : '!'}] ${name}: ${detail}`)
}
const avAddr = (objectInstance, interval) => ({
  objectType: 'analog-value', objectInstance, property: 'present-value', interval,
})

// ── PART A — table cap, hybrid split, poll fallback, teardown ────────────────
async function runPxc100 () {
  console.log('[A] pxc100-cov — hybrid split / fallback / teardown')
  const BASE = 101000
  const N = 80 // subscribe 80; device cap is 50
  const CAP = 50 // → 50 COV + 30 poll
  const dflt = (inst) => 1000.5 + (inst - BASE)

  const conn = new BacnetConnection({
    id: 'cov-pxc',
    connection: {
      localInterface: 'lo', localPort: 47808, deviceAddress: '127.0.0.1:47841', deviceInstance: 1014007,
      cov: { enabled: true, lifetimeSeconds: 60 },
    },
    targetState: 'disconnected',
  })
  await conn.connect()
  await conn.waitUntilStateEnters('connected', 15000)
  check('A connect', conn.getState() === 'connected', `state=${conn.getState()}`)

  const received = new Map()
  const callbacks = new Map()
  const cbFor = (inst) => {
    const cb = (data) => { received.set(inst, data && data.value) }
    callbacks.set(inst, cb)
    return cb
  }
  // Sequential: each SubscribeCOV completes before the next, so the split is the
  // device's table cap (cov-subscription-failed), not TSM-pool timeouts.
  for (let i = 0; i < N; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await conn.subscribe(avAddr(BASE + i, 500), cbFor(BASE + i))
  }

  check('A cov-split', conn._covByCallback.size === CAP,
    `${conn._covByCallback.size} COV subscriptions (expected ${CAP})`)
  const covInstances = [...conn._covByCallback.values()].map((s) => s.address.objectInstance)
  const polledInstances = [...Array(N).keys()].map((i) => BASE + i).filter((inst) => !covInstances.includes(inst))
  check('A poll-fallback-count', polledInstances.length === N - CAP,
    `${polledInstances.length} polled (expected ${N - CAP})`)
  check('A all-registered',
    [...Array(N).keys()].every((i) => conn._isSubscribed(avAddr(BASE + i, 500), callbacks.get(BASE + i))),
    `${N} endpoints in base registry`)

  await sleep(2500) // initial COV notifications land near-instantly
  let covData = 0; let covOk = 0
  for (const inst of covInstances) {
    if (received.has(inst)) covData += 1
    const got = received.get(inst)
    if (typeof got === 'number' && Math.abs(got - dflt(inst)) < 0.6) covOk += 1
  }
  check('A cov-initial-notifications', covData === CAP, `${covData}/${CAP} got initial value`)
  check('A cov-values-correct', covOk === CAP, `${covOk}/${CAP} matched device defaults`)

  // Poll fallback under a 50%-drop / 6-slot device: give the polls time to land.
  for (let waited = 0; waited < 12000 && polledInstances.some((inst) => !received.has(inst)); waited += 1000) {
    // eslint-disable-next-line no-await-in-loop
    await sleep(1000)
  }
  const polledData = polledInstances.filter((inst) => received.has(inst)).length
  check('A poll-fallback-data', polledData === polledInstances.length,
    `${polledData}/${polledInstances.length} polled endpoints received data`)

  const target = covInstances[0]
  await conn.unsubscribe(avAddr(target, 500), callbacks.get(target))
  check('A unsubscribe-removes-cov', !conn._covByCallback.has(callbacks.get(target)),
    `AV${target} removed (size now ${conn._covByCallback.size})`)

  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 8000).catch(() => null)
  check('A disconnect-clears-cov', conn._covByCallback.size === 0, 'COV registry empty')
  check('A disconnect-stops-renewal', conn._covRenewalTimer === null, 'renewal timer cleared')
}

// ── PART B — ongoing notifications (driven values) ──────────────────────────
async function runCovEmitter () {
  console.log('[B] cov-emitter — ongoing notifications (driven values)')
  const conn = new BacnetConnection({
    id: 'cov-emit',
    connection: {
      localInterface: 'lo', localPort: 47808, deviceAddress: '127.0.0.1:47820', deviceInstance: 900001,
      cov: { enabled: true, lifetimeSeconds: 60 },
    },
    targetState: 'disconnected',
  })
  await conn.connect()
  await conn.waitUntilStateEnters('connected', 15000)
  check('B connect', conn.getState() === 'connected', `state=${conn.getState()}`)

  // AV1/AV2/AV3 are sine/sawtooth driven at ~500ms — expect a moving stream.
  const streams = new Map([[1, []], [2, []], [3, []]])
  for (const inst of streams.keys()) {
    // eslint-disable-next-line no-await-in-loop
    await conn.subscribe(avAddr(inst, 60000), (data) => { streams.get(inst).push(data && data.value) })
  }
  check('B all-cov', conn._covByCallback.size === 3, `${conn._covByCallback.size}/3 driven AVs on COV`)

  await sleep(4000) // ~8 driver ticks at 500ms

  for (const [inst, vals] of streams) {
    const distinct = new Set(vals).size
    const moved = vals.length >= 2 && vals[vals.length - 1] !== vals[0]
    check(`B ongoing-AV${inst}`, vals.length >= 4 && distinct >= 3 && moved,
      `${vals.length} notifications, ${distinct} distinct, first=${vals[0]} last=${vals[vals.length - 1]}`)
  }

  await conn.disconnect()
  await conn.waitUntilStateEnters('disconnected', 8000).catch(() => null)
  check('B disconnect-clears-cov', conn._covByCallback.size === 0, 'COV registry empty')
}

async function main () {
  await runPxc100()
  await sleep(400) // let the process-wide listener socket settle between connections
  await runCovEmitter()
  await sleep(150)
  console.log(`\n[cov-hybrid] ${results.pass} passed, ${results.fail} failed`)
  process.exit(results.fail === 0 ? 0 : 1)
}

main().catch((err) => {
  console.error('[cov-hybrid] FATAL', err)
  process.exit(2)
})
