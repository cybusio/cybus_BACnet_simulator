# Contributing

Repo layout and what each part does: see **[README.md](README.md)**. The repo root
is the **simulator** (Python/Docker); the **QA harness** is under `qa/`; reference
docs under `docs/`.

## Conventions

| Thing | Where | Name |
|---|---|---|
| Sim device profile | `profiles-cybus/` | `<device>.yaml` (extends `profiles/_base.yaml`) |
| Sim fleet compose | `compose/` | `<fleet>.compose.yaml` (base fleet is `compose.yaml` at root) |
| e2e test (CW + MQTT) | `qa/e2e/` | `<topic>-e2e.sh` (the `spectrum-deploy`/`spectrum-verify` pair is the one exception) |
| in-process test (no CW) | `qa/inproc/qa-trio/` | `<topic>-test.js` |
| fleet generator | `qa/gen/` | `gen-<thing>.sh` |
| committed scenario SCF | `qa/scf/<area>/` | connection + receive YAML pair |

**Generated artifacts are never committed** — generators write fleet composes into
`compose/` and synthetic profiles into `profiles-cybus/`, both git-ignored (the
ignore rules live in `.git/info/exclude` / `.gitignore`). The one committed SCF is
`qa/scf/zz_objectlist.yml`; everything else under `qa/scf/*.yml` is generated.

## How to add…

**A device** — write `profiles-cybus/<device>.yaml`, add a service to `compose.yaml`
(or a fleet in `compose/`), and document its port/objects/codes in
[docs/PROFILES.md](docs/PROFILES.md) (the single source of truth — never restate
device facts elsewhere).

**An e2e test** — add `qa/e2e/<topic>-e2e.sh`. Follow `qa/e2e/lifecycle-e2e.sh`: it
resolves the repo root as `REPO="$(dirname "$(dirname "$DIR")")"`, cleans the slate
(`"$REPO/qa/tools/cw-clean-all.sh"`), deploys its SCF(s) from `"$REPO/qa/scf/…"`,
asserts on MQTT, and tears down (`trap cleanup EXIT`). End with
`==> RESULT: N passed, 0 failed`. Then add a row to TESTING.md **R2** (which SCFs +
sims it needs) and wire it into the run order.

**A qa-trio suite** — add `qa/inproc/qa-trio/<topic>-test.js` and a `run_ext` line in
`qa/inproc/qa-trio/test.sh` gated on the sim it needs (it must **self-skip** with
exit 0 when its fleet isn't up, like `mega-scale-test.js`). It finds the adapter via
`PM_ROOT` (exported by `test.sh`) or the fallback
`resolve(__dirname, '../../../../../CW/CW_2.x/cybus/protocol-mapper')`.

## Before you commit

`pre-commit` runs ruff + mypy on the simulator and a **doc-drift check**
(`qa/tools/check-docs.sh`) that fails if a tracked compose is missing from the README
fleet table, or a path the docs call "committed" isn't tracked. Run it directly:

```bash
bash qa/tools/check-docs.sh
```

Keep docs honest: if you add a compose or rename a path, update README/TESTING in the
same change — the check is there to catch the drift, not to be worked around.
