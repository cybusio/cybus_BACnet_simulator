#!/usr/bin/env node
/**
 * Cert WeatherStation verification — mirrors receive_bacnet_WeatherStation.yaml.
 *
 * The cert SCF reads 17 analog-input weather points, each for object-name /
 * present-value / units (51 polled endpoints; the `cov` in the SCF is a mapping
 * dedup RULE, not BACnet COV — so this polling-only adapter is the right SUT).
 *
 * Device A (full): all 51 reads succeed; object-name matches the point name,
 * present-value is numeric. Device B (rainCurrent absent — the
 * _bacnet_miele_missing_rainCurrent regression): rainCurrent's 3 reads must
 * surface an error gracefully (no faked data, no crash, no unhandled rejection)
 * while the other 16 points keep flowing and the connection stays connected,
 * across repeated poll cycles.
 */
'use strict'

process.env.NODE_CONFIG_DIR = process.env.NODE_CONFIG_DIR
  || '/home/dj/CW/CW_2.x/cybus/protocol-mapper/config'
process.env.NODE_ENV = process.env.NODE_ENV || 'test'

const pmRoot = process.env.PM_ROOT
  || require('path').resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')
const BacnetConnection = require(`${pmRoot}/src/protocols/bacnet/BacnetConnection`)
const { mkResults, record: _record, cleanup } = require('./_harness')

const RESULTS = mkResults()
const record = (name, ok, detail) => _record(RESULTS, name, ok, detail)

const POINTS = [
  'outdoorTemperature', 'windSpeed', 'relativeHumidity', 'rainCurrent', 'rainLast24h',
  'brightnessEast', 'brightnessNorth', 'brightnessSouth', 'brightnessWest',
  'forecastDay1Max', 'forecastDay1Min', 'forecastDay2Max', 'forecastDay2Min',
  'forecastDay3Max', 'forecastDay3Min', 'sunAzimuthAngle', 'sunElevationAngle',
].map((name, inst) => ({ name, inst }))
const PROPS = ['object-name', 'present-value', 'units']
const RAIN_INST = 3 // rainCurrent — absent on Device B

let nextPort = 48400
const mkConn = (id, devId) => new BacnetConnection({
  id,
  connection: {
    localInterface: 'lo',
    localPort: nextPort++,
    deviceAddress: id.includes('norain') ? '127.0.0.1:47867' : '127.0.0.1:47866',
    deviceInstance: devId,
    healthCheck: { intervalMs: 0 },
  },
  targetState: 'disconnected',
})

// One read; resolves { ok, value } or { ok:false, error } — never throws.
const readOne = (conn, inst, property) => conn
  .handleRead({ objectType: 'analog-input', objectInstance: inst, property })
  .then((r) => ({ ok: true, value: r && r.value }), (e) => ({ ok: false, error: e.message || String(e) }))

const main = async () => {
  console.log('[weatherstation] cert SCF mirror — 17 points x {object-name, present-value, units}')

  // ---- Device A: full station, happy path ----------------------------------
  const a = mkConn('ws-full', 2000300)
  await a.connect().catch(() => null)
  await a.waitUntilStateEnters('connected', 12000).catch(() => null)
  record('Device A (full) connects', a.getState() === 'connected', a.getState())

  let okA = 0
  let nameMatch = 0
  let pvNumeric = 0
  let unitsMatch = 0
  // outdoorTemperature + the forecast points are degreesCelsius; the rest noUnits.
  const expectedUnit = (name) => ((name === 'outdoorTemperature' || name.startsWith('forecast')) ? 'degrees-celsius' : 'no-units')
  for (const p of POINTS) {
    for (const prop of PROPS) {
      // eslint-disable-next-line no-await-in-loop -- one in-flight, mirrors the polled SCF
      const r = await readOne(a, p.inst, prop)
      if (r.ok) okA += 1
      if (prop === 'object-name' && r.ok && r.value === p.name) nameMatch += 1
      if (prop === 'present-value' && r.ok && typeof r.value === 'number') pvNumeric += 1
      if (prop === 'units' && r.ok && r.value === expectedUnit(p.name)) unitsMatch += 1
    }
  }
  record('Device A: all 51 reads succeed', okA === 51, `${okA}/51`)
  record('Device A: object-name matches point name (integrity)', nameMatch === 17, `${nameMatch}/17`)
  record('Device A: present-value numeric', pvNumeric === 17, `${pvNumeric}/17`)
  record('Device A: units matches the device unit (exact, not integer/null/wrong)', unitsMatch === 17, `${unitsMatch}/17`)
  await cleanup([a])

  // ---- Device B: rainCurrent absent — graceful missing-object handling -----
  const b = mkConn('ws-norain', 2000301)
  await b.connect().catch(() => null)
  await b.waitUntilStateEnters('connected', 12000).catch(() => null)
  record('Device B (missing rainCurrent) connects', b.getState() === 'connected', b.getState())

  const CYCLES = 3
  let rainErr = 0
  let rainActionable = 0
  let otherOk = 0
  let otherErr = 0
  for (let c = 0; c < CYCLES; c += 1) {
    for (const p of POINTS) {
      for (const prop of PROPS) {
        // eslint-disable-next-line no-await-in-loop -- sequential poll cycle
        const r = await readOne(b, p.inst, prop)
        if (p.inst === RAIN_INST) {
          if (!r.ok) {
            rainErr += 1
            // the error must name the object + the SCF fix, not an opaque correlation
            if (r.error.includes(`analog-input:${RAIN_INST}`)
              && r.error.includes('not present on device')
              && r.error.includes('objectInstance/objectType')) rainActionable += 1
          } else otherErr += 1 // rainCurrent returning data would be FAKED — a failure
        } else if (r.ok) otherOk += 1
        else otherErr += 1
      }
    }
  }
  const expectedRain = PROPS.length * CYCLES // 9
  const expectedOther = (POINTS.length - 1) * PROPS.length * CYCLES // 144
  record('Device B: rainCurrent reads error gracefully every cycle (no faked data)',
    rainErr === expectedRain, `${rainErr}/${expectedRain} errored`)
  record('Device B: rainCurrent error is actionable — names the object + the SCF fix',
    rainActionable === expectedRain, `${rainActionable}/${expectedRain} actionable`)
  record('Device B: the other 16 points keep flowing under the missing point',
    otherOk === expectedOther && otherErr === 0, `${otherOk}/${expectedOther} ok, ${otherErr} unexpected`)
  record('Device B: connection stays connected (no storm/crash on missing object)',
    b.getState() === 'connected', b.getState())
  await cleanup([b])

  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
