#!/usr/bin/env node
/**
 * High-scale data-integrity test — 30 healthy peers under sustained heavy load.
 *
 * Every BACnet device exposes a unique fingerprint: its device object-identifier
 * carries that peer's own instance number (400001, 2000010, ...), and object-name
 * is a per-peer string. EVERY successful read is checked against the expected
 * (peer, property) value; one mismatch = a reply correlated to the wrong caller or
 * the wrong property — silent data corruption.
 *
 * Load shape: 27 fast peers drive a high-churn storm (max concurrent invoke-id
 * turnover on the shared 255-slot pool); 3 slow-but-correct peers (ultra-slow,
 * legacy TSM=4, overloaded) are verified concurrently on their own loops so their
 * latency never gates throughput; 2 abort-storm peers add iid contention.
 *
 * Bar: zero mismatches (fast and slow) across tens of thousands of concurrent
 * reads. No mocks over the SUT — real UDP, real C-stack, real devices.
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const {
  SIM, mkResults, record: _record, cleanup, percentile,
} = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)

const NAMED_KEYS = [
  'miele', 'energy', 'legacy', 'modern', 'newlift', 'mieleOver', 'noRpm',
  'abortSeg', 'ultraSlow', 'empty', 'covEmitter', 'abortStorm', 'replyTimeStorm',
]
const ADVERSARIAL = new Set(['abortStorm', 'replyTimeStorm']) // abort every read — no fingerprint
const SLOWCORRECT = new Set(['ultraSlow', 'legacy', 'mieleOver']) // correct data, too slow for the churn pool
const CONCURRENCY = 160
const DURATION_MS = 15000

let nextPort = 48200
const mkConn = (key, addr, id) => ({
  key,
  id,
  conn: new BacnetConnection({
    id: `intg-${key}`,
    connection: {
      localInterface: 'lo',
      localPort: nextPort++,
      deviceAddress: addr,
      deviceInstance: id,
    },
    targetState: 'disconnected',
  }),
})

const PEERS = [
  ...NAMED_KEYS.map((k) => mkConn(k, SIM[k].addr, SIM[k].id)),
  ...Array.from({ length: 19 }, (_, i) => mkConn(`clone${String(i + 1).padStart(3, '0')}`, `127.0.0.1:${47823 + i}`, 2000010 + i)),
]
const CONNS = PEERS.map((p) => p.conn)
const FAST = PEERS.filter((p) => !ADVERSARIAL.has(p.key) && !SLOWCORRECT.has(p.key)) // 27
const SLOW = PEERS.filter((p) => SLOWCORRECT.has(p.key)) // 3
const ADV = PEERS.filter((p) => ADVERSARIAL.has(p.key)) // 2
const HEALTHY = [...FAST, ...SLOW] // 30
const readProp = (p, property) => p.conn.handleRead({ objectType: 'device', objectInstance: p.id, property })

const main = async () => {
  console.log(`[scale-integrity] 32 peers | ${FAST.length} fast churn + ${SLOW.length} slow + ${ADV.length} abort | ${CONCURRENCY}-way`)

  await Promise.all(CONNS.map((c) => c.connect().catch(() => null)))
  await Promise.all(CONNS.map((c) => c.waitUntilStateEnters('connected', 20000).catch(() => null)))
  const up = CONNS.filter((c) => c.getState() === 'connected').length
  record('all 32 peers connected', up === 32, `${up}/32`)

  // Fingerprint all 30 healthy peers: object-identifier must equal the known device
  // instance (integrity at rest, fast and slow alike); record object-name too.
  const names = {}
  let fpOk = 0
  await Promise.all(HEALTHY.map(async (p) => {
    const [oid, name] = await Promise.all([
      readProp(p, 'object-identifier').then((r) => r && r.value, () => null),
      readProp(p, 'object-name').then((r) => r && r.value, () => null),
    ])
    names[p.key] = name
    if (oid && oid.objectInstance === p.id) fpOk += 1
  }))
  record('30 peers fingerprinted: object-identifier == known device instance', fpOk === HEALTHY.length, `${fpOk}/${HEALTHY.length}`)

  // Fast tasks: each fast peer contributes oid + (name if known).
  const TASKS = []
  FAST.forEach((p) => {
    TASKS.push({ p, prop: 'object-identifier', kind: 'oid' })
    if (names[p.key] != null) TASKS.push({ p, prop: 'object-name', kind: 'name', want: names[p.key] })
  })
  const verify = (task, value) => (task.kind === 'oid'
    ? !!(value && value.objectInstance === task.p.id)
    : value === task.want)

  const stop = Date.now() + DURATION_MS
  const lat = []
  let total = 0; let correct = 0; let mismatch = 0; let fail = 0
  const samples = []
  const worker = async (w) => {
    let i = w
    while (Date.now() < stop) {
      const task = TASKS[i % TASKS.length]
      i += 1
      const t = Date.now()
      try {
        // eslint-disable-next-line no-await-in-loop -- one in-flight per worker
        const r = await readProp(task.p, task.prop)
        total += 1; lat.push(Date.now() - t)
        if (verify(task, r && r.value)) correct += 1
        else {
          mismatch += 1
          if (samples.length < 8) samples.push({ peer: task.p.key, prop: task.prop, got: r && r.value, want: task.kind === 'oid' ? task.p.id : task.want })
        }
      } catch (_) { total += 1; fail += 1 }
    }
  }
  // Slow peers verified concurrently on their own loops (latency never gates churn).
  let slowReads = 0; let slowMismatch = 0
  const slowLoops = SLOW.map((p) => (async () => {
    while (Date.now() < stop) {
      // eslint-disable-next-line no-await-in-loop -- one in-flight per slow peer
      const v = await readProp(p, 'object-identifier').then((r) => r && r.value, () => null)
      if (v) { slowReads += 1; if (v.objectInstance !== p.id) slowMismatch += 1 }
    }
  })())
  // Abort-storm peers contend for the shared iid pool throughout.
  const noise = ADV.map((p) => (async () => {
    while (Date.now() < stop) {
      // eslint-disable-next-line no-await-in-loop -- contention generator
      await readProp(p, 'present-value').catch(() => {})
    }
  })())
  await Promise.all([
    ...Array.from({ length: CONCURRENCY }, (_, w) => worker(w)),
    ...slowLoops, ...noise,
  ])

  lat.sort((a, b) => a - b)
  console.log(`  [i] fast: ${total} issued | ${correct} correct | ${fail} failed | ${mismatch} MISMATCH`)
  console.log(`  [i] slow: ${slowReads} reads | ${slowMismatch} MISMATCH`)
  if (samples.length) console.log('  [i] mismatch samples:', JSON.stringify(samples))
  record('ZERO data-integrity violations across the fast churn pool', mismatch === 0, `${mismatch} mismatches in ${correct} verified reads`)
  record('ZERO data-integrity violations on slow peers under concurrent load', slowMismatch === 0, `${slowMismatch} mismatches in ${slowReads} slow reads`)
  record('high read volume integrity-checked (>=20000)', correct >= 20000, `${correct} fast reads verified`)
  record('fast-pool p99 bounded (< 1500ms)', percentile(lat, 0.99) < 1500, `p99=${percentile(lat, 0.99)}ms, p50=${percentile(lat, 0.50)}ms`)

  await cleanup(CONNS)
  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
