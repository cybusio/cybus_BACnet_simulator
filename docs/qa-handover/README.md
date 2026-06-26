# BACnet COV — QA acceptance handover

> ⚠️ **Separate feature — not this release.** This document covers the **hybrid
> COV** capability on branch **`feature/bacnet-cov`** (commit `c8560f726`). The
> current release (`CC-4157-…`, polling-only) does **not** ship COV; the
> `scf/cov_hybrid.yml` and `pxc100-cov` sims referenced below are **not present on
> this branch**. Ignore this doc unless you are testing the COV feature.

Exact SCFs + procedure to acceptance-test the **hybrid COV + poll** capability of the
BACnet adapter (`feature/bacnet-cov`, commit `c8560f726`) on a running Connectware,
verified over MQTT. COV is **opt-in per Connection** (`cov.enabled`, default off), so
every existing polling deployment is unaffected.

## What COV does
For a `present-value` endpoint, the adapter subscribes via BACnet **SubscribeCOV** where
the device accepts it (push on change), and **falls back to polling** for the rest —
when the device's COV table is full, COV is unsupported, or the property isn't
present-value. Notifications arrive at the configured topic exactly like a poll value.

## Test bed (sims)
Two device simulators (host networking; reachable from the protocol-mapper container at
`172.18.0.1`):

| Sim | Address | Device | Role |
|---|---|---|---|
| `pxc100-cov` | `172.18.0.1:47841` | 1014007 | COV-capable, **finite COV table (cap 50)**, overloaded — exercises the split |
| `bacnet-cov-emitter` | `172.18.0.1:47820` | 900001 | driven values (sine/sawtooth) — exercises ongoing notifications |

Stand them up from this repo (profiles `profiles-cybus/pxc100_cov.yaml`,
`profiles-cybus/cov_emitter.yaml`). **Reset the capped sim before each COV run**
(`docker restart pxc100-cov`) — its COV table + active-count persist across deploys.

## SCFs in this handover (`scf/`)
| SCF | Tests | Device(s) |
|---|---|---|
| `cov_hybrid.yml` | COV+poll split **and** ongoing notifications **and** two-connection isolation (no cross-routing) | both |

Parameterised — override device IP / port / instance / `covLifetimeSeconds` / `pollIntervalMs`
at deploy. Defaults target the sims above. 60 capped endpoints (> the cap of 50) +
3 driven endpoints.

## Deploy + verify
```bash
# 1. reset the capped sim (fresh COV table)
docker restart pxc100-cov && sleep 6

# 2. deploy + enable (CW REST API; admin/admin by default)
TOKEN=$(curl -sk -X POST https://localhost/api/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' | jq -r .token)
curl -sk -X POST https://localhost/api/services -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"covqa\",\"commissioningFile\":\"$(base64 -w0 < scf/cov_hybrid.yml)\",\"parameters\":{},\"targetState\":\"enabled\"}"

# 3. watch the split in the protocol-mapper log (≈10 endpoints fall back; 50 go COV)
docker logs --since 60s platform-protocol-mapper-1 2>&1 | grep -c 'falling back to polling'

# 4. verify data on MQTT
mosquitto_sub -h localhost -p 1883 -u admin -P admin -t 'services/covqa/#' -v
```

## Pass criteria
1. **Service enables, both connections reach `connected`**, 0 level-50 errors in the PM log.
2. **Split:** exactly `endpoints − 50` endpoints log `COV unavailable; falling back to polling`
   (default 60 → **10 fallback / 50 COV**). All capped endpoints publish to `services/covqa/capped/AV*`.
3. **Ongoing COV:** `services/covqa/driven/AV1|AV2|AV3` publish **changing** values at the
   driver cadence (~500 ms), far faster than the 10 s poll interval — observe **right after
   deploy** (see caveat). AV1 sine 18–26, AV2 sawtooth 950–1050, AV3 sine 10–14.
4. **No cross-routing:** driven values stay in their own ranges (never the capped ~1000+ range).

## Caveats (test-bed, not adapter bugs)
- **Reset the capped sim between runs** — its `_cov_active` counter is a simple sim
  model that also counts COV *refreshes*, so a stale table reads "full" and the whole
  device falls back to poll. A real device refreshes a re-subscribe without re-counting.
- **Ongoing-COV is cleanest observed soon after deploy.** In this combined SCF the 60
  capped endpoints hammer the *overloaded* capped sim (tsm pool 6, 50 % drop); under that
  sustained load the shared transaction pool can starve the driven device's COV **renewal**
  (fires at 80 % of `covLifetimeSeconds`, default 300 s) and demote it to polling. For a
  pure long-running ongoing-COV demo, deploy the driven device on its own (drop the
  `capped*` resources) or raise `covLifetimeSeconds`. The split and isolation results are
  stable regardless.
