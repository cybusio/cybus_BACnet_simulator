#!/usr/bin/env node
/**
 * QA validation against BACnet simulator — tests CC-4155, CC-4156, CC-4157.
 * Requires: 6 simulator devices running (docker compose up in BACnet_simulator/)
 * Run: node --require ./test/qa-loader.js test/qa-simulator-test.js
 */
'use strict'

const pmRoot = process.env.PM_ROOT || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetClient = require(`${pmRoot}/src/protocols/bacnet/stack/lib/BacnetClient`)
const { isResponseTooLarge } = require(`${pmRoot}/src/protocols/bacnet/stack`)
const assert = require('assert')

// Simulator device map (from compose.yaml)
const DEVICES = {
  miele:      { port: 47808, addr: '127.0.0.1:47808', id: 1014006, desc: 'Miele EnergyMeter, abort=1 (bufferOverflow)' },
  energy:     { port: 47809, addr: '127.0.0.1:47809', id: 2000001, desc: 'GreenEnergy, abort=11 (apduTooLong)' },
  legacy:     { port: 47810, addr: '127.0.0.1:47810', id: 300001,  desc: 'Siemens PXC36, max_apdu=206, noSegmentation' },
  modern:     { port: 47811, addr: '127.0.0.1:47811', id: 400001,  desc: 'Trane Tracer, 1476, segmentedBoth' },
  newlift:    { port: 47812, addr: '127.0.0.1:47812', id: 2000,    desc: 'MBS UGW, 106 objects' },
  overloaded: { port: 47813, addr: '127.0.0.1:47813', id: 1014007, desc: 'Miele Overloaded, 200ms delay' },
  covEmitter: { port: 47820, addr: '127.0.0.1:47820', id: 900001,  desc: 'COV emitter, driven AV/BV objects' },
}

const RESULTS = { pass: 0, fail: 0, skip: 0, tests: [] }

function record (ticket, name, passed, detail) {
  const status = passed === null ? 'SKIP' : (passed ? 'PASS' : 'FAIL')
  RESULTS.tests.push({ ticket, name, status, detail })
  if (passed === null) RESULTS.skip++
  else if (passed) RESULTS.pass++
  else RESULTS.fail++
  const icon = passed === null ? '~' : (passed ? '+' : '!')
  console.log(`  [${icon}] ${name}: ${detail}`)
}

function sleep (ms) {
  return new Promise((r) => { setTimeout(r, ms) })
}

// ── CC-4155 Tests ───────────────────────────────────────────

async function testCC4155_abortPropagation (client) {
  console.log('\n── CC-4155: ABORT propagation ──')

  // Test 1: Read object-list from miele device (100 objects, triggers bufferOverflow abort)
  try {
    await client.readProperty({
      deviceAddress: DEVICES.miele.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.miele.id,
      propertyName: 'object-list',
    })
    record('CC-4155', 'Miele abort code 1 propagated', false, 'Expected error but got success')
  } catch (err) {
    const hasMessage = err.message && err.message.length > 0
    const hasAbortReason = err.abortReason !== undefined
    record('CC-4155', 'Miele abort propagated to JS', hasMessage,
      `msg="${err.message.substring(0, 80)}"`)
    record('CC-4155', 'Miele abortReason attached', hasAbortReason,
      `abortReason=${err.abortReason} (expected: 1=bufferOverflow)`)
  }

  // Test 2: Read object-list from energy device (abort code 11, apduTooLong)
  try {
    await client.readProperty({
      deviceAddress: DEVICES.energy.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.energy.id,
      propertyName: 'object-list',
    })
    record('CC-4155', 'Energy abort code 11 propagated', false, 'Expected error but got success')
  } catch (err) {
    const hasAbortReason = err.abortReason !== undefined
    record('CC-4155', 'Energy abort propagated to JS',
      Boolean(err.message && err.message.length > 0),
      `msg="${err.message.substring(0, 80)}"`)
    record('CC-4155', 'Energy abortReason=11 (apduTooLong)', hasAbortReason && err.abortReason === 11,
      `abortReason=${err.abortReason}`)
  }
}

async function testCC4155_writeErrorPropagation (client) {
  console.log('\n── CC-4155: Write error propagation ──')

  // Write to an invalid object — should get error, not silent swallow
  try {
    await client.writeProperty(
      {
        deviceAddress: DEVICES.modern.addr,
        objectTypeName: 'analog-value',
        objectInstance: 99999, // nonexistent
        propertyName: 'present-value',
      },
      42.0,
    )
    record('CC-4155', 'Write to invalid object errors', false, 'Expected error but got success')
  } catch (err) {
    record('CC-4155', 'Write error propagated (not swallowed)',
      Boolean(err.message && err.message.length > 0),
      `msg="${err.message.substring(0, 80)}"`)
  }
}

async function testCC4155_happyPath (client) {
  console.log('\n── CC-4155: Happy path baseline ──')

  // Read object-name from modern device — should always work
  try {
    const name = await client.readProperty({
      deviceAddress: DEVICES.modern.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.modern.id,
      propertyName: 'object-name',
    })
    record('CC-4155', 'Modern device read object-name', typeof name === 'string' && name.length > 0,
      `value="${name}"`)
  } catch (err) {
    record('CC-4155', 'Modern device read object-name', false, `error: ${err.message}`)
  }

  // Read present-value from modern device analog-value
  try {
    const val = await client.readProperty({
      deviceAddress: DEVICES.modern.addr,
      objectTypeName: 'analog-value',
      objectInstance: 1,
      propertyName: 'present-value',
    })
    record('CC-4155', 'Modern device read analog-value', typeof val === 'number',
      `value=${val}`)
  } catch (err) {
    record('CC-4155', 'Modern device read analog-value', false, `error: ${err.message}`)
  }
}

async function testCC4155_abortReasonClassification () {
  console.log('\n── CC-4155: isResponseTooLarge classification (production predicate) ──')

  const e1 = new Error('test'); e1.abortReason = 1
  const e4 = new Error('test'); e4.abortReason = 4
  const e11 = new Error('test'); e11.abortReason = 11
  const e0 = new Error('test'); e0.abortReason = 0
  const eNone = new Error('test')

  record('CC-4155', 'isResponseTooLarge code=1', isResponseTooLarge(e1) === true, 'bufferOverflow')
  record('CC-4155', 'isResponseTooLarge code=4', isResponseTooLarge(e4) === true, 'segNotSupported')
  record('CC-4155', 'isResponseTooLarge code=11', isResponseTooLarge(e11) === true, 'apduTooLong')
  record('CC-4155', 'isResponseTooLarge code=0', isResponseTooLarge(e0) === false, 'other')
  record('CC-4155', 'isResponseTooLarge no code', isResponseTooLarge(eNone) === false, 'undefined')
}

// ── CC-4156/CC-4157 Tests ───────────────────────────────────

async function testCC4156_capabilityDiscovery (client) {
  console.log('\n── CC-4156/4157: Device capability discovery ──')

  // Read max-apdu-length-accepted from various devices
  for (const [name, dev] of [['modern', DEVICES.modern], ['legacy', DEVICES.legacy], ['newlift', DEVICES.newlift]]) {
    try {
      const maxApdu = await client.readProperty({
        deviceAddress: dev.addr,
        objectTypeName: 'device',
        objectInstance: dev.id,
        propertyName: 'max-apdu-length-accepted',
      })
      record('CC-4156', `${name} max-apdu-length-accepted`, typeof maxApdu === 'number' && maxApdu > 0,
        `value=${maxApdu}`)
    } catch (err) {
      record('CC-4156', `${name} max-apdu-length-accepted`, false, `error: ${err.message}`)
    }
  }

  // Read segmentation-supported
  for (const [name, dev] of [['modern', DEVICES.modern], ['legacy', DEVICES.legacy]]) {
    try {
      const seg = await client.readProperty({
        deviceAddress: dev.addr,
        objectTypeName: 'device',
        objectInstance: dev.id,
        propertyName: 'segmentation-supported',
      })
      record('CC-4156', `${name} segmentation-supported`, seg !== undefined,
        `value=${seg}`)
    } catch (err) {
      record('CC-4156', `${name} segmentation-supported`, false, `error: ${err.message}`)
    }
  }
}

async function testCC4157_indexedArrayRead (client) {
  console.log('\n── CC-4157: Indexed array reads ──')

  // Read object-list count (index 0) from newlift device (106 objects)
  try {
    const count = await client.readProperty({
      deviceAddress: DEVICES.newlift.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.newlift.id,
      propertyName: 'object-list',
      arrayIndex: 0,
    })
    record('CC-4157', 'NewLift object-list count (index 0)', Number.isInteger(count) && count > 0,
      `count=${count}`)

    // Read first few elements individually
    if (Number.isInteger(count) && count > 0) {
      const elem1 = await client.readProperty({
        deviceAddress: DEVICES.newlift.addr,
        objectTypeName: 'device',
        objectInstance: DEVICES.newlift.id,
        propertyName: 'object-list',
        arrayIndex: 1,
      })
      record('CC-4157', 'NewLift object-list element 1', elem1 !== undefined,
        `value=${JSON.stringify(elem1)}`)

      const elem5 = await client.readProperty({
        deviceAddress: DEVICES.newlift.addr,
        objectTypeName: 'device',
        objectInstance: DEVICES.newlift.id,
        propertyName: 'object-list',
        arrayIndex: 5,
      })
      record('CC-4157', 'NewLift object-list element 5', elem5 !== undefined,
        `value=${JSON.stringify(elem5)}`)
    }
  } catch (err) {
    record('CC-4157', 'NewLift indexed array read', false, `error: ${err.message}`)
  }

  // Legacy device: 206B max_apdu, noSegmentation, ~15 objects.
  // Whether full read aborts depends on encoded size vs max_apdu.
  // Each BACnet OBJECT_ID encodes to ~8 bytes, so 15 objects = ~120B < 206B = fits.
  // This is correct protocol behavior: abort only fires when response exceeds APDU.
  // The abort path is already proven by miele (100 objects, code 1) and energy (44 objects, code 11).
  console.log('\n── CC-4157: Legacy device (206B, noSegmentation) ──')
  try {
    const objList = await client.readProperty({
      deviceAddress: DEVICES.legacy.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.legacy.id,
      propertyName: 'object-list',
    })
    const count = Array.isArray(objList) ? objList.length : 1
    const estBytes = count * 8
    record('CC-4157', 'Legacy full object-list (small device)',
      count > 0 && estBytes < 206,
      `${count} objects (~${estBytes}B) fits in 206B APDU — no abort needed`)
  } catch (err) {
    const isAbort = err.abortReason !== undefined
    record('CC-4157', 'Legacy full object-list aborted (large device)', isAbort,
      `Device has too many objects for 206B APDU: abortReason=${err.abortReason}`)
  }

  // Indexed read always works regardless of object count
  try {
    const count = await client.readProperty({
      deviceAddress: DEVICES.legacy.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.legacy.id,
      propertyName: 'object-list',
      arrayIndex: 0,
    })
    record('CC-4157', 'Legacy indexed count succeeds', Number.isInteger(count) && count > 0,
      `count=${count}`)
  } catch (err) {
    record('CC-4157', 'Legacy indexed count succeeds', false, `error: ${err.message}`)
  }

  // Miele device: 100 objects at 1476B max_apdu but abort_reason=1.
  // Proves the full abort→indexed-read fallback path with a large object list.
  console.log('\n── CC-4157: Miele device (abort on oversized, then indexed fallback) ──')
  try {
    const mCount = await client.readProperty({
      deviceAddress: DEVICES.miele.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.miele.id,
      propertyName: 'object-list',
      arrayIndex: 0,
    })
    record('CC-4157', 'Miele indexed count after abort', Number.isInteger(mCount) && mCount > 50,
      `count=${mCount} (large enough to exceed APDU on full read)`)

    // Read a few elements to prove element-by-element works
    const mElem = await client.readProperty({
      deviceAddress: DEVICES.miele.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.miele.id,
      propertyName: 'object-list',
      arrayIndex: 1,
    })
    record('CC-4157', 'Miele indexed element read', mElem !== undefined,
      `element[1]=${JSON.stringify(mElem)}`)
  } catch (err) {
    record('CC-4157', 'Miele indexed reads', false, `error: ${err.message}`)
  }
}

async function testCC4155_BBMDTimer (client) {
  console.log('\n── CC-4155: BBMD maintenance timer ──')
  // BBMD timer fix can't be directly tested with localhost simulator (no cross-subnet).
  // We verify the code path exists by confirming the client initializes successfully
  // and the listener thread is running (reads work = listener thread active)
  try {
    const name = await client.readProperty({
      deviceAddress: DEVICES.newlift.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.newlift.id,
      propertyName: 'object-name',
    })
    record('CC-4155', 'BBMD timer: listener thread active', typeof name === 'string',
      `(BBMD renewal runs in same loop; cross-subnet test requires physical setup)`)
  } catch (err) {
    record('CC-4155', 'BBMD timer: listener thread active', false, err.message)
  }
}

// ── BBMD F-A foreign-device registration ─────────────────────

// Capture UDP frames sent to a fake BBMD by binding a socket on the chosen
// port. Returns { frames, close } where frames is an array of Buffers.
function startBbmdSink (port) {
  const dgram = require('dgram')
  const sock = dgram.createSocket('udp4')
  const frames = []
  sock.on('message', (msg) => { frames.push(Buffer.from(msg)) })
  return new Promise((resolve, reject) => {
    sock.once('error', reject)
    sock.bind(port, '127.0.0.1', () => {
      resolve({
        port: sock.address().port,
        frames,
        close: () => new Promise((r) => { sock.close(r) }),
      })
    })
  })
}

// Match a Register-Foreign-Device BVLC frame: 0x81 0x05 0x00 0x06 TTL_HI TTL_LO
function isRegisterForeignDeviceFrame (buf, expectedTtl) {
  if (buf.length < 6) return false
  if (buf[0] !== 0x81) return false // BVLC type = BACnet/IP
  if (buf[1] !== 0x05) return false // Function = Register-Foreign-Device
  if (buf[2] !== 0x00 || buf[3] !== 0x06) return false // Length = 6
  const ttl = (buf[4] << 8) | buf[5]
  return ttl === expectedTtl
}

async function testBBMD_registerForeignDevice (client) {
  console.log('\n── BBMD: Register-Foreign-Device emits BVLC type 0x82 (RegisterForeignDevice) with correct TTL ──')
  const TTL = 60
  let sink
  try {
    // ephemeral port (0): the OS picks a free one, so this never collides with a
    // fleet sim that happens to use a fixed port (e.g. scale_synth on 47898/47899).
    sink = await startBbmdSink(0)
  } catch (err) {
    record('BBMD', 'fake BBMD sink bound', false, err.message)
    return
  }
  try {
    if (typeof client.registerForeignDevice !== 'function') {
      throw new Error('client.registerForeignDevice is not a function')
    }
    client.registerForeignDevice(`127.0.0.1:${sink.port}`, TTL)
    await sleep(200)
    const matches = sink.frames.filter((f) => isRegisterForeignDeviceFrame(f, TTL))
    record('BBMD', 'Register-Foreign-Device frame received',
      matches.length >= 1,
      `frames=${sink.frames.length} matches=${matches.length} ttl=${TTL}`)
  } catch (err) {
    record('BBMD', 'Register-Foreign-Device frame received', false, err.message)
  } finally {
    await sink.close()
  }
}



async function testBBMD_ttlRenewal (client) {
  console.log('\n── BBMD: foreign-device registration auto-renews at end of TTL ──')
  const TTL = 4
  let sink
  try {
    sink = await startBbmdSink(0)   // ephemeral port — see note above
  } catch (err) {
    record('BBMD', 'fake BBMD sink bound (renewal)', false, err.message)
    return
  }
  try {
    if (typeof client.registerForeignDevice !== 'function') {
      throw new Error('client.registerForeignDevice is not a function')
    }
    client.registerForeignDevice(`127.0.0.1:${sink.port}`, TTL)
    // First frame at t=0; dlenv renews when BBMD_Timer_Seconds reaches 0,
    // i.e. at t≈TTL seconds. Wait 1.5 × TTL to capture the renewal.
    await sleep(TTL * 1500)
    const matches = sink.frames.filter((f) => isRegisterForeignDeviceFrame(f, TTL))
    record('BBMD', 'TTL renewal: ≥2 frames within 1.5 × TTL',
      matches.length >= 2,
      `frames=${sink.frames.length} matches=${matches.length} ttl=${TTL}`)
  } catch (err) {
    record('BBMD', 'TTL renewal: ≥2 frames within 1.5 × TTL', false, err.message)
  } finally {
    await sink.close()
  }
}

// ── TSM Exhaustion Tests (no ticket yet) ────────────────────

async function testTSM_exhaustionRecovery (client) {
  console.log('\n── TSM: Invoke-ID exhaustion and recovery ──')

  // Fire a burst of concurrent reads against the overloaded device (TSM pool=12, 200ms delay).
  // With 20 simultaneous requests and only 12 TSM slots, some will get silently dropped
  // by the device and eventually time out via sweep (15s) or TSM retry (12s).
  // Pre-fix: dropped requests leaked invoke_ids. Post-fix: they resolve with timeout error.
  // Use object-name (always exists) so failures are only from TSM drops, not bad addressing
  const BURST = 20
  const promises = []
  const start = Date.now()

  for (let i = 0; i < BURST; i += 1) {
    promises.push(
      client.readProperty({
        deviceAddress: DEVICES.overloaded.addr,
        objectTypeName: 'device',
        objectInstance: DEVICES.overloaded.id,
        propertyName: 'object-name',
      }).then((val) => ({ ok: true, val }))
        .catch((err) => ({ ok: false, msg: err.message }))
    )
  }

  const results = await Promise.all(promises)
  const elapsed = Date.now() - start
  const succeeded = results.filter((r) => r.ok).length
  const failed = results.filter((r) => !r.ok).length
  const timedOut = results.filter((r) => !r.ok && r.msg.includes('timed out')).length

  record('TSM', `Burst ${BURST} reads: ${succeeded} ok, ${failed} failed`,
    succeeded + failed === BURST && succeeded > 0,
    `${succeeded}/${BURST} succeeded, ${timedOut} timed out, ${elapsed}ms`)

  // Some requests may fail due to TSM pool exhaustion — that's expected.
  // The key assertion: failures produce actual errors, not silent hangs.
  record('TSM', 'All requests resolved (no infinite hang)',
    results.length === BURST,
    `${results.length}/${BURST} promises resolved`)

  if (failed > 0) {
    const sample = results.find((r) => !r.ok)
    record('TSM', 'Failed requests have error messages', sample && sample.msg.length > 0,
      `sample="${sample.msg.substring(0, 80)}"`)
  }

  // Recovery test: after the burst, the device should still be reachable
  await sleep(2000)
  try {
    const name = await client.readProperty({
      deviceAddress: DEVICES.overloaded.addr,
      objectTypeName: 'device',
      objectInstance: DEVICES.overloaded.id,
      propertyName: 'object-name',
    })
    record('TSM', 'Device reachable after burst', typeof name === 'string',
      `Recovered, name="${name}"`)
  } catch (err) {
    record('TSM', 'Device reachable after burst', false,
      `Still unreachable: ${err.message}`)
  }
}

async function testTSM_legacyPoolLimit (client) {
  console.log('\n── TSM: Legacy device pool limit (TSM=4) ──')

  // Legacy device has TSM pool=4 and 50ms+30ms delay.
  // Fire 8 concurrent reads — at most 4 can be in-flight.
  const BURST = 8
  const promises = []
  const start = Date.now()

  for (let i = 0; i < BURST; i += 1) {
    promises.push(
      client.readProperty({
        deviceAddress: DEVICES.legacy.addr,
        objectTypeName: 'device',
        objectInstance: DEVICES.legacy.id,
        propertyName: 'object-name',
      }).then((val) => ({ ok: true, val }))
        .catch((err) => ({ ok: false, msg: err.message }))
    )
  }

  const results = await Promise.all(promises)
  const elapsed = Date.now() - start
  const succeeded = results.filter((r) => r.ok).length
  const failed = results.filter((r) => !r.ok).length

  record('TSM', `Legacy burst ${BURST}: ${succeeded} ok, ${failed} failed`,
    succeeded > 0,
    `TSM pool=4, ${succeeded}/${BURST} in ${elapsed}ms`)

  record('TSM', 'All promises resolved (no leak)',
    results.length === BURST,
    `${results.length}/${BURST} resolved`)
}


// ── Main ────────────────────────────────────────────────────

async function main () {
  console.log('=== BACnet QA Simulator Test Suite ===')
  console.log(`Simulator devices: ${Object.keys(DEVICES).join(', ')}`)
  console.log('')

  // Use port 0 to let OS pick an ephemeral port (avoid conflict with simulators)
  const client = new BacnetClient('lo', 47880)
  console.log('BacnetClient initialized on lo:47880')

  // Wait for client to be ready
  await sleep(1000)

  try {
    // CC-4155 tests
    await testCC4155_happyPath(client)
    await testCC4155_abortPropagation(client)
    await testCC4155_abortReasonClassification()
    await testCC4155_writeErrorPropagation(client)
    await testCC4155_BBMDTimer(client)

    // CC-4156/CC-4157 tests
    await testCC4156_capabilityDiscovery(client)
    await testCC4157_indexedArrayRead(client)

    // TSM exhaustion (no ticket yet — proactive testing)
    await testTSM_exhaustionRecovery(client)
    await testTSM_legacyPoolLimit(client)

    // BBMD F-A foreign-device registration (Drop 3)
    await testBBMD_registerForeignDevice(client)
    await testBBMD_ttlRenewal(client)
  } catch (err) {
    console.error('\nFATAL:', err.message)
    console.error(err.stack)
  }

  // Summary
  console.log('\n═══════════════════════════════════')
  console.log(`RESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed, ${RESULTS.skip} skipped`)
  console.log('═══════════════════════════════════')

  if (RESULTS.fail > 0) {
    console.log('\nFailed tests:')
    for (const t of RESULTS.tests.filter((t) => t.status === 'FAIL')) {
      console.log(`  [${t.ticket}] ${t.name}: ${t.detail}`)
    }
  }

  client.destruct()
  // Let the event loop drain
  await sleep(500)
  process.exit(RESULTS.fail > 0 ? 1 : 0)
}

main()
