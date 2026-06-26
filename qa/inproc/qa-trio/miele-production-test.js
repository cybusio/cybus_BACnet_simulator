#!/usr/bin/env node
/**
 * Miele production SCF mirror — receive_bacnet_TotalElectricalEnergyConsumption
 * + connection_bacnet.yaml (protocols/bacnet/miele, the real factory config).
 *
 * Object model is FAITHFUL to the generated services: SumRealPower/SumReactivePower/
 * SumRealEnergy are analog-INPUT (DA_115_12 enables SumRealEnergy at instance 57),
 * the apparent/reactive sums are analog-VALUE. Connection uses deviceInstance +
 * deviceAddress + connectionStrategy. No writes/arrays/priority/COV (mappings use
 * transform/collect, engine-side).
 *
 * STRICT, non-lenient assertions on every read:
 *   - analog-VALUE sums are static stored readings -> EXACT value.
 *   - analog-INPUT values are live/driven -> a tight plausible band (catches a
 *     wrong/garbled/zeroed read, honest about live data).
 *   - units -> EXACT enum string (catches a raw integer / null / wrong unit that
 *     would corrupt the factory data model).
 *   - object-name -> EXACT bare string (the CharacterString quote-strip fix).
 *   - object-identifier -> the device instance (correlation fingerprint).
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

const DEVICE = 2098185
const EPS = 0.05
// nominal/static readings + exact unit strings, per the real factory object model.
const POINTS = [
  { ot: 'analog-input', oi: 43, name: 'SumRealPower', units: 'watts', lo: 9466, hi: 10463 },
  { ot: 'analog-input', oi: 53, name: 'SumReactivePower', units: 'volt-amperes-reactive', lo: 2373, hi: 2623 },
  { ot: 'analog-input', oi: 57, name: 'SumRealEnergy', units: 'kilowatt-hours', lo: 45841, hi: 50666 },
  { ot: 'analog-input', oi: 1, name: 'voltage_L1_N', units: 'volts', lo: 207, hi: 253 },
  { ot: 'analog-value', oi: 71, name: 'SumApparentPower', units: 'volt-amperes', want: 10272.1 },
  { ot: 'analog-value', oi: 89, name: 'SumReactiveEnergy', units: 'kilovolt-ampere-hours-reactive', want: 12096.0 },
  { ot: 'analog-value', oi: 95, name: 'SumApparentEnergy', units: 'kilovolt-ampere-hours', want: 12480.3 },
]

const read = (c, ot, oi, prop) => c.handleRead({ objectType: ot, objectInstance: oi, property: prop })
  .then((r) => ({ ok: true, value: r && r.value }), (e) => ({ ok: false, error: e.message || String(e) }))

const main = async () => {
  console.log('[miele-production] faithful TotalElectricalEnergyConsumption mirror — device 2098185')

  const conn = new BacnetConnection({
    id: 'miele-prod',
    connection: {
      localInterface: 'lo',
      localPort: 49620,
      deviceInstance: DEVICE,
      deviceAddress: '127.0.0.1:47868',
      connectionStrategy: { initialDelay: 1000, maxDelay: 30000, incrementFactor: 2 },
    },
    targetState: 'disconnected',
  })
  await conn.connect().catch(() => null)
  await conn.waitUntilStateEnters('connected', 12000).catch(() => null)
  record('connection_bacnet.yaml config accepted (connectionStrategy) + connected', conn.getState() === 'connected', conn.getState())

  const oid = await read(conn, 'device', DEVICE, 'object-identifier')
  record('device fingerprint: object-identifier == device_instance', !!(oid.ok && oid.value && oid.value.objectInstance === DEVICE), oid.ok ? JSON.stringify(oid.value) : oid.error)

  let pvOk = 0
  let unitsOk = 0
  let nameOk = 0
  for (const p of POINTS) {
    // eslint-disable-next-line no-await-in-loop -- one in-flight, mirrors the polled service
    const [pv, u, nm] = await Promise.all([
      read(conn, p.ot, p.oi, 'present-value'),
      read(conn, p.ot, p.oi, 'units'),
      read(conn, p.ot, p.oi, 'object-name'),
    ])
    const pvGood = pv.ok && typeof pv.value === 'number'
      && (p.want !== undefined ? Math.abs(pv.value - p.want) < EPS : pv.value >= p.lo && pv.value <= p.hi)
    const uGood = u.ok && u.value === p.units
    const nGood = nm.ok && nm.value === p.name
    if (pvGood) pvOk += 1
    if (uGood) unitsOk += 1
    if (nGood) nameOk += 1
    const pvExp = p.want !== undefined ? `==${p.want}` : `in[${p.lo},${p.hi}]`
    record(`${p.ot} ${p.oi} ${p.name}: pv ${pvExp} · units==${p.units} · name bare`,
      pvGood && uGood && nGood, `pv=${pv.value} units=${JSON.stringify(u.value)} name=${JSON.stringify(nm.value)}`)
  }
  record('all 7 present-values valid (static exact, live in-band — no faked/garbled)', pvOk === POINTS.length, `${pvOk}/${POINTS.length}`)
  record('all 7 units are exact enum strings (not raw integer / null / wrong unit)', unitsOk === POINTS.length, `${unitsOk}/${POINTS.length}`)
  record('all 7 object-names are bare strings (CharacterString fidelity)', nameOk === POINTS.length, `${nameOk}/${POINTS.length}`)

  await cleanup([conn])
  console.log(`\nRESULTS: ${RESULTS.pass} passed, ${RESULTS.fail} failed`)
  setTimeout(() => process.exit(RESULTS.fail === 0 ? 0 : 1), 300)
}

main().catch((e) => { console.error('fatal', e); process.exit(1) })
