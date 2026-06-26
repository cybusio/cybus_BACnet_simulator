#!/usr/bin/env node
/**
 * Polling cadence, jitter, and timer-leak — the 24/7 factory polling concern.
 *
 * The production services poll many endpoints per connection at a fixed interval
 * (40 s in the field). The adapter spreads the FIRST poll of each endpoint across
 * [0, interval) (BacnetConnection.handleSubscribe jitter) so 36 connections don't
 * burst the shared TSM pool in lockstep, then the base class polls at cadence.
 *
 * Strict checks (interval compressed to exercise the mechanism quickly):
 *   - jitter genuinely spreads the first polls (not all at t=0 / lockstep).
 *   - every endpoint keeps polling at the configured cadence with real data.
 *   - after disconnect, polling STOPS completely — no orphan timer keeps firing
 *     (a leak here is what fills the heap over weeks of factory uptime).
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const { mkResults, record: _record, sleep } = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)

const INTERVAL = 1500
const N = 12 // analog-input instances 1..12 on a miele clone
const RUN_MS = 6500

const main = async () => {
  console.log(`[cadence] ${N} endpoints @ ${INTERVAL}ms — jitter spread, cadence, no timer leak`)

  const conn = new BacnetConnection({
    id: 'cadence',
    connection: {
      localInterface: 'lo',
      localPort: 49640,
      deviceAddress: '127.0.0.1:47823', // miele clone-001
      deviceInstance: 2000010,
      healthCheck: { intervalMs: 0 }, // isolate subscribe cadence from probe traffic
    },
    targetState: 'disconnected',
  })
  await conn.connect().catch(() => null)
  await conn.waitUntilStateEnters('connected', 10000).catch(() => null)
  record('connects for polling', conn.getState() === 'connected', conn.getState())

  const t0 = Date.now()
  const events = []
  const numericOf = (d) => (d && typeof d === 'object' && 'value' in d ? d.value : d)
  // Subscribe all concurrently so each endpoint's first-poll jitter runs in parallel.
  // subscribe() registers the callback in the subscription registry, then calls
  // handleSubscribe (jitter + base best-effort poll); handleSubscribe alone throws.
  await Promise.all(Array.from({ length: N }, (_, i) => conn.subscribe(
    { objectType: 'analog-input', objectInstance: i + 1, property: 'present-value', interval: INTERVAL },
    (data) => events.push({ key: i + 1, t: Date.now() - t0, v: numericOf(data) }),
  ).catch(() => null)))

  await sleep(RUN_MS)

  // First-poll time per endpoint → jitter spread.
  const firsts = {}
  events.forEach((e) => { if (firsts[e.key] === undefined) firsts[e.key] = e.t })
  const ft = Object.values(firsts)
  const spread = ft.length ? Math.max(...ft) - Math.min(...ft) : 0
  record('jitter spreads first polls across the interval (not lockstep)', spread > INTERVAL * 0.25, `spread=${spread}ms of ${INTERVAL}ms across ${ft.length} endpoints`)

  // Poll count + data per endpoint → cadence + real data.
  const counts = {}
  events.forEach((e) => { counts[e.key] = (counts[e.key] || 0) + 1 })
  const minCount = Object.keys(firsts).length === N ? Math.min(...Object.values(counts)) : 0
  record('every endpoint polls at the configured cadence', N === Object.keys(firsts).length && minCount >= 3, `${Object.keys(firsts).length}/${N} endpoints, min ${minCount} polls in ${RUN_MS}ms`)
  const allNumeric = events.length > 0 && events.every((e) => typeof e.v === 'number')
  record('every poll delivered a real numeric reading', allNumeric, `${events.length} polls`)

  // Disconnect, then confirm polling has fully stopped (no orphan timer).
  await conn.disconnect().catch(() => null)
  await conn.waitUntilStateEnters('disconnected', 5000).catch(() => null)
  const before = events.length
  await sleep(2500)
  const after = events.length
  record('polling STOPS after disconnect — no orphan timer leak', after === before, `${after - before} polls fired after disconnect`)

  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
