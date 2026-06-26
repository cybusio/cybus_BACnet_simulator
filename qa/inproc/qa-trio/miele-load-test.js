#!/usr/bin/env node
/**
 * Miele load-concentration e2e — reproduces the Mar-4 root cause, not just the
 * symptom. devices_by_entries.md shows 17 logical meters mapped to ONE physical
 * device (2098185); each meter polls 6 analog-value present-values at 1s, so ~102
 * reads/s land on one embedded device — which overflowed its buffer and (on the old
 * code) drove ~1252 reconnects from ~1585 ABORTs.
 *
 * Here all 17 "meters" are connections to one abort-prone device. Over ~15s that is
 * ~1530 present-value reads (≈ the real 1585). Asserts the adapter does NOT amplify:
 * no reconnect storm, aborts surfaced gracefully, and the array re-gate holds so each
 * abort costs ONE read (no index-0 probe doubling load). No mocks over the SUT.
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

const METERS = 17 // logical meters -> ONE physical device (Miele DA_115 -> 2098185)
const REGISTERS = 6 // analog-value present-values per meter (the real SCF)
const DURATION_MS = 15000
const POLL_MS = 1000

const mk = (i) => {
  const d = SIM.abortStorm
  return new BacnetConnection({
    id: `meter-${i}`,
    connection: {
      localInterface: 'lo',
      localPort: 49200,
      deviceAddress: d.addr,
      deviceInstance: d.id,
      healthCheck: { intervalMs: 0 },
    },
    targetState: 'disconnected',
  })
}

const main = async () => {
  console.log(`=== Miele load-concentration e2e: ${METERS} meters x ${REGISTERS} regs -> 1 device, ${DURATION_MS / 1000}s ===`)
  const conns = Array.from({ length: METERS }, (_, i) => mk(i))
  await Promise.all(conns.map((c) => c.connect().catch(() => {})))
  await Promise.all(conns.map((c) => c.waitUntilStateEnters('connected', 10000).catch(() => {})))
  const connected = conns.filter((c) => c.getState() === 'connected').length

  let reconnects = 0
  const last = conns.map((c) => c.getState())
  const poll = setInterval(() => {
    conns.forEach((c, i) => {
      const s = c.getState()
      if (s !== last[i]) { if (s === 'reconnecting') reconnects += 1; last[i] = s }
    })
  }, 200)

  // spy total native reads on the shared singleton to detect amplification
  const client = conns[0]._bacnetClient
  const orig = client.readProperty.bind(client)
  let nativeReads = 0
  client.readProperty = (...a) => { nativeReads += 1; return orig(...a) }

  let logical = 0; let reason1 = 0
  const stop = Date.now() + DURATION_MS
  while (Date.now() < stop) {
    const t0 = Date.now()
    const batch = []
    conns.forEach((c) => {
      for (let r = 0; r < REGISTERS; r += 1) {
        logical += 1
        batch.push(c.handleRead({ objectType: 'analog-value', objectInstance: 101009 + r, property: 'present-value' })
          .then(() => {}, (e) => { if (e && e.abortReason === 1) reason1 += 1 }))
      }
    })
    // eslint-disable-next-line no-await-in-loop
    await Promise.all(batch)
    const elapsed = Date.now() - t0
    // eslint-disable-next-line no-await-in-loop
    if (elapsed < POLL_MS) await new Promise((res) => { setTimeout(res, POLL_MS - elapsed) })
  }
  clearInterval(poll)
  client.readProperty = orig
  const allConnected = conns.every((c) => c.getState() === 'connected')
  const ratio = nativeReads / logical

  record(`${METERS} meters connect to one device`, connected === METERS, `${connected}/${METERS}`)
  record('NO reconnect storm under concentrated load', reconnects === 0, `${reconnects} reconnects over ${logical} reads (old code: ~1252)`)
  record('aborts surfaced gracefully (reason 1), every connection survives', allConnected && reason1 > 0, `${reason1} reason-1 aborts, all connected=${allConnected}`)
  record('NO read amplification — re-gate holds (native ~= logical, not 2x)', ratio < 1.15, `native=${nativeReads} logical=${logical} ratio=${ratio.toFixed(2)}`)
  await cleanup(conns)
  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
