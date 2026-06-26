#!/usr/bin/env node
/**
 * Reconnect + health-check on peer loss — the factory power-cycle scenario.
 *
 * BACnet is connectionless UDP: a powered-off device sends no TCP FIN, it just
 * goes silent. The adapter must detect that via its health-check probe (not hang
 * "connected" forever), transition to reconnecting, and — once the device powers
 * back on — reconnect per connectionStrategy and resume reading. This is the gap
 * a config-only "connectionStrategy accepted" test cannot cover.
 *
 * Realistic, strict: a dedicated device is actually STOPPED (silent peer) and
 * RESTARTED via docker, and the full FSM cycle connected -> reconnecting ->
 * connected is asserted, plus a live read after recovery and a clean teardown.
 */
'use strict'

const { execSync } = require('child_process')

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const { mkResults, record: _record, sleep } = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)
const CTR = 'bacnet_simulator-bacnet-reconnect-target-1'

const pollFor = async (predicate, timeoutMs) => {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return true
    // eslint-disable-next-line no-await-in-loop -- polling the FSM
    await sleep(250)
  }
  return false
}

const main = async () => {
  console.log('[reconnect] factory power-cycle: stop the device, detect, restart, recover')

  const conn = new BacnetConnection({
    id: 'recon',
    connection: {
      localInterface: 'lo',
      localPort: 49630,
      deviceAddress: '127.0.0.1:47869',
      deviceInstance: 700001,
      healthCheck: { intervalMs: 1000, timeoutMs: 1500, failureThreshold: 2 },
      connectionStrategy: { initialDelay: 500, maxDelay: 4000, incrementFactor: 2 },
    },
    targetState: 'disconnected',
  })

  await conn.connect().catch(() => null)
  await pollFor(() => conn.getState() === 'connected', 12000)
  record('connects to the device', conn.getState() === 'connected', conn.getState())

  // Power-cycle OFF: stop the container — a silent peer (no FIN).
  execSync(`docker stop -t 2 ${CTR}`, { stdio: 'ignore' })
  const left = await pollFor(() => conn.getState() !== 'connected', 25000)
  record('health-check detects the silent peer (does NOT hang in connected)', left, `state=${conn.getState()}`)
  record('FSM transitions to reconnecting on connectLost', conn.getState() === 'reconnecting', conn.getState())

  // Power-cycle ON: device returns.
  execSync(`docker start ${CTR}`, { stdio: 'ignore' })
  const recovered = await pollFor(() => conn.getState() === 'connected', 40000)
  record('connectionStrategy reconnects once the peer returns', recovered, conn.getState())

  const r = await conn.handleRead({ objectType: 'analog-input', objectInstance: 1, property: 'present-value' })
    .then((x) => x && x.value, () => null)
  record('live read succeeds after reconnect (truly recovered, not just FSM state)', typeof r === 'number', `value=${r}`)

  await conn.disconnect().catch(() => null)
  const down = await pollFor(() => conn.getState() === 'disconnected', 6000)
  record('disconnects cleanly (health-check stopped, no wedged/orphan state)', down, conn.getState())

  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
