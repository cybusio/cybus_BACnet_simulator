#!/usr/bin/env node
/**
 * 32-peer fleet test — field realism at the documented ~32-peer ceiling.
 *
 * Drives BacnetConnection against 32 real simulator peers (13 mixed-spec named +
 * 19 miele clones) that share the one process-wide BacnetClient / TSM singleton.
 * Verifies: all peers connect; each peer's reads return that peer's own data with
 * no cross-peer bleed on the shared invoke-id pool; a concurrent read storm across
 * all 32 isolates slow/adversarial peers from the healthy cohort; the TSM degrades
 * gracefully at its 255-slot ceiling and recovers; teardown wedges no peer.
 *
 * No mocks over the SUT — real UDP, real C-stack, real devices. Needs the 13
 * named devices (compose.yaml) plus clones 001-019 (compose/scale-fleet.compose.yaml) up.
 *
 * Run:
 *   PM_ROOT=/path node --require <pm>/src/protocols/bacnet/test/qa-loader.js scale-fleet-test.js
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const {
  SIM, mkResults, record: _record, sleep, cleanup, percentile,
} = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)

// 32 peers = 13 mixed-spec named + 19 miele clones (ports 47823+, ids 2000010+).
const NAMED_KEYS = [
  'miele', 'energy', 'legacy', 'modern', 'newlift', 'mieleOver', 'noRpm',
  'abortSeg', 'ultraSlow', 'empty', 'covEmitter', 'abortStorm', 'replyTimeStorm',
]
// Peers that are slow or adversarial by design — excluded from the fast-cohort
// latency bound (their whole point is to be slow/abort without starving others).
const SLOW = new Set(['ultraSlow', 'abortStorm', 'replyTimeStorm', 'legacy', 'mieleOver'])
// abort-storm / reply-time-storm reject every read by design — they must not crash
// dispatch, but are excluded from "returned a value" integrity counts.
const ADVERSARIAL = new Set(['abortStorm', 'replyTimeStorm'])

let nextPort = 48000
const mkConn = (key, addr, id) => ({
  key,
  id,
  conn: new BacnetConnection({
    id: `fleet-${key}`,
    connection: {
      localInterface: 'lo',
      localPort: nextPort++, // ignored after the first — the singleton binds once
      deviceAddress: addr,
      deviceInstance: id,
    },
    targetState: 'disconnected',
  }),
})

const PEERS = [
  ...NAMED_KEYS.map((k) => mkConn(k, SIM[k].addr, SIM[k].id)),
  ...Array.from({ length: 19 }, (_, i) => mkConn(
    `clone${String(i + 1).padStart(3, '0')}`, `127.0.0.1:${47823 + i}`, 2000010 + i,
  )),
]
const CONNS = PEERS.map((p) => p.conn)
const readName = (p) => p.conn.handleRead({
  objectType: 'device', objectInstance: p.id, property: 'object-name',
})

// A: every peer reaches connected (ultra-slow answers in ~12-15s, so allow one lag).
const connectAll = async () => {
  console.log('\n── A: 32 peers connect concurrently ──')
  await Promise.all(CONNS.map((c) => c.connect().catch(() => null)))
  await Promise.all(CONNS.map((c) => c.waitUntilStateEnters('connected', 20000).catch(() => null)))
  const up = CONNS.filter((c) => c.getState() === 'connected').length
  record('all 32 peers reach connected', up === 32, `${up}/32 connected`)
}

// B: 32 concurrent reads, twice — every peer must return its own value, identical
// across both rounds. A shared-iid correlation bug would surface as a timeout or a
// value that changes between rounds (one peer's reply routed to another's callback).
const integrity = async () => {
  console.log('\n── B: per-peer read integrity (no cross-peer correlation bleed) ──')
  const round = () => Promise.all(PEERS.map((p) => readName(p).then(
    (r) => (r ? r.value : undefined), () => undefined,
  )))
  const v1 = await round()
  const v2 = await round()
  const healthyCount = PEERS.filter((p) => !ADVERSARIAL.has(p.key)).length
  const okHealthy = PEERS.filter((p, i) => !ADVERSARIAL.has(p.key) && v1[i] != null).length
  record(`all ${healthyCount} healthy peers return their object-name on the shared socket`,
    okHealthy === healthyCount, `${okHealthy}/${healthyCount} (abort/reply-storm abort by design)`)
  const both = v1.map((v, i) => ({ v1: v, v2: v2[i] })).filter((x) => x.v1 != null && x.v2 != null)
  const matched = both.filter((x) => x.v1 === x.v2).length
  record('each peer identical across both concurrent rounds (no cross-talk)',
    matched === both.length, `${matched}/${both.length} peers stable`)
}

// C: all 32 loop reads independently for a fixed window. Up to 32 in-flight at once
// (one per peer) — the realistic 32-server steady state. Slow/adversarial peers must
// not inflate the healthy cohort's latency.
const storm = async () => {
  console.log('\n── C: 15s read storm across all 32 (breadth + slow-peer isolation) ──')
  const stop = Date.now() + 15000
  const stat = {}
  PEERS.forEach((p) => { stat[p.key] = { ok: 0, fail: 0, lat: [] } })
  await Promise.all(PEERS.map((p) => (async () => {
    while (Date.now() < stop) {
      const t = Date.now()
      // eslint-disable-next-line no-await-in-loop -- one in-flight per peer by design
      await readName(p).then(
        () => { stat[p.key].ok += 1; stat[p.key].lat.push(Date.now() - t) },
        () => { stat[p.key].fail += 1 },
      )
    }
  })()))
  const fast = PEERS.filter((p) => !SLOW.has(p.key))
  const fastLat = []
  let fOk = 0; let fTot = 0
  fast.forEach((p) => { const s = stat[p.key]; fOk += s.ok; fTot += s.ok + s.fail; fastLat.push(...s.lat) })
  fastLat.sort((a, b) => a - b)
  const p99 = percentile(fastLat, 0.99)
  const totalOk = Object.values(stat).reduce((a, s) => a + s.ok, 0)
  console.log(`  [i] storm: ${totalOk} reads ok across 32 peers; fast cohort ${fOk}/${fTot}`)
  record(`fast cohort (${fast.length} peers) >=99% success under 32-peer storm`,
    fTot > 0 && fOk / fTot >= 0.99, `${(100 * fOk / Math.max(1, fTot)).toFixed(1)}%`)
  record('fast-cohort p99 < 1500ms while slow/adversarial peers run concurrently',
    p99 < 1500, `p99=${p99}ms`)
}

// C2: fire well over the 255-slot TSM pool at once on the fast cohort. Excess reads
// must fail fast ("max concurrency"), not crash or hang the process.
const ceilingBurst = async () => {
  console.log('\n── C2: near-ceiling burst (270 concurrent vs 255 TSM slots) ──')
  const fast = PEERS.filter((p) => !SLOW.has(p.key))
  const tasks = []
  fast.forEach((p) => { for (let k = 0; k < 10; k += 1) tasks.push(readName(p).then(() => true, () => false)) })
  const res = await Promise.all(tasks)
  const ok = res.filter(Boolean).length
  record('near-ceiling burst degrades gracefully (no crash; majority ok)',
    ok >= tasks.length * 0.7, `${ok}/${tasks.length} ok of a ${tasks.length}-read burst`)
}

// D: the TSM is not wedged after saturation — a fresh read still works.
const recovery = async () => {
  console.log('\n── D: TSM recovery after saturation ──')
  await sleep(500)
  const modern = PEERS.find((p) => p.key === 'modern')
  const r = await readName(modern).then((x) => x, () => null)
  record('post-storm read succeeds (TSM reclaimed, not wedged)', !!(r && r.value != null),
    r && r.value != null ? `modern object-name=${JSON.stringify(r.value)}` : 'no value')
}

const teardown = async () => {
  console.log('\n── E: teardown ──')
  await cleanup(CONNS)
  const down = CONNS.filter((c) => c.getState() === 'disconnected').length
  record('all 32 peers disconnect cleanly (no wedged peer)', down === 32, `${down}/32 disconnected`)
}

const main = async () => {
  console.log(`[scale-fleet] 32 peers: ${NAMED_KEYS.length} named + 19 clones`)
  await connectAll()
  await integrity()
  await storm()
  await ceilingBurst()
  await recovery()
  await teardown()
  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
