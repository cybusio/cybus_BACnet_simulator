'use strict'

// Shared scaffolding for connection-realism + factory-storm.
// Mirror of simulator device map; per-peer deadline for slow profiles.
const SIM = Object.freeze({
  miele:        { addr: '127.0.0.1:47808', id: 1014006 },
  energy:       { addr: '127.0.0.1:47809', id: 2000001 },
  legacy:       { addr: '127.0.0.1:47810', id: 300001 },
  modern:       { addr: '127.0.0.1:47811', id: 400001 },
  newlift:      { addr: '127.0.0.1:47812', id: 2000 },
  mieleOver:    { addr: '127.0.0.1:47813', id: 1014007 },
  noRpm:        { addr: '127.0.0.1:47816', id: 600001 },
  abortSeg:     { addr: '127.0.0.1:47817', id: 600002 },
  ultraSlow:    { addr: '127.0.0.1:47818', id: 600003 },
  empty:        { addr: '127.0.0.1:47819', id: 600004 },
  covEmitter:   { addr: '127.0.0.1:47820', id: 900001 },
  abortStorm:   { addr: '127.0.0.1:47821', id: 1014008 },
  replyTimeStorm: { addr: '127.0.0.1:47822', id: 1014009 },
  bogus:        { addr: '127.0.0.1:1',     id: 1 },
})

const mkResults = () => ({ pass: 0, fail: 0, tests: [] })

const record = (results, name, ok, detail) => {
  results.tests.push({ name, ok, detail })
  results[ok ? 'pass' : 'fail'] += 1
  console.log(`  [${ok ? '+' : '!'}] ${name}: ${detail}`)
}

const sleep = (ms) => new Promise((r) => { setTimeout(r, ms) })

// C-stack listener-thread teardown is process-wide (BacnetClient singleton);
// the 100 ms gap between scenarios lets libuv close the prior UDP socket
// before the next test rebuilds it. Without this, rapid disconnect/connect
// cycles can trip 'uv__finish_close: Assertion handle->flags & UV_HANDLE_CLOSING'.
const settleListenerThread = () => sleep(100)

const buildConn = (BacnetConnection, id, localPort, devKey, extra = {}) => {
  const d = SIM[devKey]
  const { connectionStrategy, ...rest } = extra
  return new BacnetConnection({
    id,
    connection: {
      localInterface: 'lo',
      localPort,
      deviceAddress: d.addr,
      deviceInstance: d.id,
      ...(connectionStrategy ? { connectionStrategy } : {}),
      ...rest,
    },
    targetState: 'disconnected',
  })
}

const cleanup = async (conns) => {
  await Promise.all(conns.map((c) => c.disconnect().catch(() => null)))
  await Promise.all(conns.map((c) =>
    c.waitUntilStateEnters('disconnected', 5000).catch(() => null)
  ))
  await settleListenerThread()
}

const percentile = (sortedArr, p) => {
  if (sortedArr.length === 0) return 0
  const idx = Math.min(sortedArr.length - 1, Math.floor(sortedArr.length * p))
  return sortedArr[idx]
}

module.exports = {
  SIM, mkResults, record, sleep, settleListenerThread, buildConn, cleanup, percentile,
}
