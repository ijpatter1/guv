# Core-test battery — hermeticity audit ([15.1])

The core-test battery runs its suites under a **bounded parallel pool** (see the
generated `run-core-tests.sh`, the `run-plugin-tests.sh` builder heredoc in
`maintainers/build-plugin.sh`, and the serial CI loop in
`.github/workflows/template-clean.yml`). Parallelism is only safe for suites that
isolate every write under their own `mktemp` directory. This document is the
audit of record: it enumerates which suites were checked, which write to or build
from the **shared live source tree** (`.claude/` in the repo, and
`maintainers/plugin-src/`) at fixed, non-`mktemp` paths, and each one's
disposition (carved into the serial pass vs left parallel-safe).

A suite that writes to the shared live tree **cannot** run concurrently with any
other suite that reads or writes it — concurrent builds pick up a sibling's
planted throwaway fixtures, or trip the build's authored/derived skill-name
collision (`exit 2`), producing an intermittently flaky battery. Such suites are
carved out of the pool and run **one at a time** (the `SERIAL_SET` in each
runner). Everything else stays parallel.

## Method

Every `.claude/tests/*.test.sh` suite (54 at audit time, 2026-06-19) was checked
for file-creating operations (`>`, `>>`, `mkdir`, `touch`, `cp`/`mv` destination,
`rm`, `ln`) whose target resolves to a path **inside the live source tree** and
is **not** under a per-run `mktemp -d`. Two categories of offender exist:

1. **Planters** — a suite that deliberately drops a throwaway fixture into the
   live `.claude/` (or `maintainers/plugin-src/`) to exercise a glob-derived
   behavior end-to-end through a real build.
2. **Live-source builders** — a suite that invokes `build-plugin.sh` reading the
   live `.claude/` as the build *source* (even when its `--out` is a `mktemp`
   tree), so a concurrent planter's fixture leaks into the build it observes.

## Findings — the SERIAL_SET (not parallel-safe)

| Suite | Category | Shared-live-tree writes / reads | Disposition |
|---|---|---|---|
| `plugin.test.sh` | planter + live-source builder | Plants throwaway fixtures into the live tree at fixed paths: `$SRC/zz-t12e-fixture.sh` (T12e), `$ROOT/maintainers/plugin-src/skills/status/` (T15, skill-name-collision fixture), `$SRC/skills/zzadjacency-fixture/` (T15b), `$SRC/zzregistry-fixture.sh` + `$SRC/skills/zzregistry-fixture-cmd/` (T15c) — where `SRC="$ROOT/.claude"`. Then runs `build-plugin.sh --out <mktemp>` which **reads** that same live `$SRC` as its build source. | **SERIAL** |
| `ship-suite.test.sh` | live-source builder | Runs `build-plugin.sh --out <mktemp>` (lines ~65) reading the live `$SRC = "$ROOT/.claude"` as the build source. Does not plant fixtures itself, but a concurrent `plugin.test.sh` planting a `zz*` fixture or the collision skill is picked up by this build, or trips its `exit 2` collision path. | **SERIAL** |

Both happen to be **maintainer-only** suites (they reference `maintainers/` and
`SKILL.md` surfaces, so `build-plugin.sh`'s `MAINTAINER_ONLY` filter keeps them
out of the shipped `plugin/tests/` partition). The serial carve is nonetheless
applied identically in all three runner copies — the `run-plugin-tests.sh`
builder never *assumes* the partition excludes them, so the three copies stay in
lockstep and a future shared-tree suite that does ship is already covered.

## Findings — parallel-safe (the remainder)

Every other suite isolates its writes under its own `mktemp -d` (typically
`WORK=$(mktemp -d)` / `TMP=$(mktemp -d)`), or only **reads** the live tree
(grep/`cmp`/`cat` against source files — reads never collide). Spot-confirmed
representative builders that are hermetic because they build from a **scratch
copy**, not the live tree:

- `setup-control-plane.test.sh` — builds a scratch guv repo under `$WORK`
  (`make_guv` → `"$WORK/guv"`) and runs `setup-control-plane.sh` against scratch
  control planes; never touches the live `.claude/`.
- `render-hook.test.sh` — assembles a fixture guv repo at `H="$WORK/guv"` and
  runs `setup-control-plane.sh` against scratch planes under `$WORK`.
- `release.test.sh` — references `build-plugin.sh` only for absence checks; never
  invokes it against the live source.

These remain in the bounded parallel pool.

## Enrolling a new suite

If a new suite writes to or builds from the shared live source tree at a fixed
path, add its basename to `SERIAL_SET` in **all three** runner copies:

- the `write_runner` heredoc in `maintainers/setup-control-plane.sh`
  (generates `.claude/run-core-tests.sh`),
- the `run-plugin-tests.sh` heredoc in `maintainers/build-plugin.sh`,
- and note the coupling in the `.github/workflows/template-clean.yml` CI loop
  comment (the CI loop is serial-by-design, which subsumes the carve).

The lockstep is guarded by `setup-control-plane.test.sh` (the runner-behavior
home): T11j proves the named suites run serially under the real generated runner,
T11k proves the runner declares the set, and the T7 drift guard keeps the CI loop
in step. Prefer making a new suite hermetic (write under `mktemp`) over enrolling
it — the serial pass is the documented fallback for suites that genuinely must
touch the live tree, not the default.
