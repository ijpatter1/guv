# Core-test battery — hermeticity audit ([15.1])

The core-test battery runs its suites under a **bounded parallel pool** (see the
generated `run-core-tests.sh`, the `run-plugin-tests.sh` builder heredoc in
`maintainers/build-plugin.sh`, and the serial CI loop in
`.github/workflows/template-clean.yml`). Parallelism is only safe for suites that
isolate every write under their own `mktemp` directory. This document is the
audit of record for that property: which suites were checked, which ever wrote to
or built from the **shared live source tree** (`.claude/` in the repo, and
`maintainers/plugin-src/`) at fixed, non-`mktemp` paths, and how each was
resolved.

A suite that writes to the shared live tree cannot safely run beside any suite
that reads or writes it — concurrent builds pick up a sibling's planted throwaway
fixtures, or trip the build's authored/derived skill-name collision (`exit 2`),
producing an intermittently flaky battery.

## How this is enforced — the guard, and the carve it replaced

**Today: a whole-battery hermeticity guard.** The generated runner fingerprints
the code repo before the first suite and again after the last, and **fails the
run** if the tree moved. `battery-result.sh fingerprint` owns the hash — the same
one the `[A2]` recorded verdict compares — so runner, `record` and `read` cannot
drift apart. On a breach the runner prints the `git status --porcelain` diff so
the reader can tell a leaking suite from a person editing mid-run; both are real
failures (a tree that changed underneath the suites means no single state was
tested), so both fail loud. Where the fingerprint cannot be taken at all — the
code repo is not a git repo — the guard **announces** that hermeticity went
unchecked and the battery proceeds (Rule 15: degrade toward doing the work, never
toward claiming a proof nobody produced).

**Until 2026-07-26: a serial carve.** The two suites below were quarantined and
run one at a time ahead of the pool (`SERIAL_SET` in each runner). That worked,
but it cost **319s of strictly serial time inside an 826s battery**, and it only
ever protected the suites someone had already thought to name — a new live-tree
writer would have joined the pool silently. Spike Prong B made both suites
hermetic, which retired the carve's reason, and the guard replaced it.

Two honest limits on the guard, both deliberate:

- **It is whole-battery, not per-suite.** Under a parallel pool the suites
  overlap, so a tree change cannot be attributed to one of them. Per-suite
  attribution would require running them serially — reintroducing the exact cost
  this removed. The porcelain diff names the *paths*, which in practice
  identifies the culprit.
- **It detects, it does not prevent.** A leaking suite can still perturb a
  concurrent build within the run that catches it. The trade is a reproducible
  failing battery that names the leak, in place of an intermittent flake nobody
  could reproduce.

## Method

Every `.claude/tests/*.test.sh` suite was checked for file-creating operations
(`>`, `>>`, `mkdir`, `touch`, `cp`/`mv` destination, `rm`, `ln`) whose target
resolves to a path **inside the live source tree** and is **not** under a per-run
`mktemp -d`. Audited at 54 suites (2026-06-19) and re-checked at 71 (2026-07-26).
Two categories of offender exist:

1. **Planters** — a suite that deliberately drops a throwaway fixture into the
   live `.claude/` (or `maintainers/plugin-src/`) to exercise a glob-derived
   behavior end-to-end through a real build.
2. **Live-source builders** — a suite that invokes `build-plugin.sh` reading the
   live `.claude/` as the build *source* (even when its `--out` is a `mktemp`
   tree), so a concurrent planter's fixture leaks into the build it observes.

## Findings — the two offenders, and how each was resolved

| Suite | Category | What it did | Resolution |
|---|---|---|---|
| `plugin.test.sh` | planter + live-source builder | Planted throwaway fixtures into the live tree at fixed paths: `$SRC/zz-t12e-fixture.sh` (T12e), `$ROOT/maintainers/plugin-src/skills/status/` (T15), `$SRC/skills/zzadjacency-fixture/` (T15b), `$SRC/zzregistry-fixture.sh` + `$SRC/skills/zzregistry-fixture-cmd/` (T15c) — `SRC="$ROOT/.claude"`. Then built from that same live `$SRC`. | **HERMETIC** (Prong B). A `mk_source_copy()` helper tars the repo into a scratch root; all five source-touching sub-tests plant into and build from that copy. Verified: no write rooted at `$ROOT`/`$SRC` remains, and each planting sub-test asserts the fixture is *absent* from the live tree. |
| `ship-suite.test.sh` | live-source builder | Ran `build-plugin.sh --out <mktemp>` reading live `$SRC` as the build source. Never planted anything itself — its hazard was entirely that a *concurrent* planter's fixture would leak into the build it observed. | **HERMETIC** by removal of the hazard. It still reads live `$SRC` (a read, which cannot collide with other reads) and still builds into `mktemp`. With no suite planting into the live tree, nothing can leak in. |

Both are **maintainer-only** suites — they reference `maintainers/` and `SKILL.md`
surfaces, so `build-plugin.sh`'s `MAINTAINER_ONLY` filter keeps them out of the
shipped `plugin/tests/` partition.

## Findings — parallel-safe (the remainder)

Every other suite isolates its writes under its own `mktemp -d` (typically
`WORK=$(mktemp -d)` / `TMP=$(mktemp -d)`), or only **reads** the live tree
(grep/`cmp`/`cat` against source files — reads never collide). Spot-confirmed
representative builders that are hermetic because they build from a **scratch
copy**, not the live tree:

- `setup-control-plane.test.sh` — builds a scratch guv repo under `$WORK`
  (`make_guv` → `"$WORK/guv"`) and runs `setup-control-plane.sh` against scratch
  control planes; never touches the live `.claude/`. Also seam-isolated on the
  second axis below.
- `render-hook.test.sh` — assembles a fixture guv repo at `H="$WORK/guv"` and
  runs `setup-control-plane.sh` against scratch planes under `$WORK`. Also
  seam-isolated on the second axis below.
- `release.test.sh` — references `build-plugin.sh` only for absence checks; never
  invokes it against the live source.

These remain in the bounded parallel pool.

## The second axis — writes OUTSIDE the repo (user-scope state)

The audit above is about the shared **live source tree** inside the repo, and the
fingerprint guard covers exactly that. There is a second, independent axis it
does **not** cover: a suite that reaches **user-scope state outside the repo
entirely**. The guard fingerprints the code repo, so a write to
`~/.claude/plugins/cache/` is invisible to it — and serializing never helped here
either. One suite touching the maintainer's real machine state is wrong however
few suites run beside it.

One such surface exists today. Since `[19.5]`'s cache half,
`maintainers/setup-control-plane.sh` refreshes the **installed plugin cache** as
well as the control plane it is given — deliberately, because a plugin-registered
hook executes `${CLAUDE_PLUGIN_ROOT}/scripts/*`, never the plane's synced copy, so
a `--sync` that skipped the cache would leave the machine running stale core. The
cache is **user-scope**: `~/.claude/plugins/cache/…`, the core every guv project
on that machine runs. Any suite invoking `setup-control-plane.sh` therefore
reaches it unless the seam is set.

**The seam is `GUV_PLUGINS_DB`** — it overrides the installed-plugin DB path the
refresh reads. Point it at a path under the suite's own `mktemp` (existing fixture
DB, or a name that does not exist) and the refresh returns at its absent-DB rung
before resolving any real `installPath`:

```bash
export GUV_PLUGINS_DB="$WORK/no-such-plugins-db.json"
```

Both current callers set it: `setup-control-plane.test.sh` (fixture DBs, which is
also how its T13 cases exercise the refresh) and `render-hook.test.sh` (absent
path, plus a positive control asserting no plugin-cache line reaches its setup
log). **Any new suite that runs `setup-control-plane.sh` owes the same line.**
Do not rely on the fixture repo shipping no `plugin/` — that rung disclosed and
returned by accident, and an accident is not isolation.

## Enrolling a new suite

Both axes get asked about, in this order. Answering only the first is how the
second one was missed for as long as it was.

**Axis 1 — does it write to the shared live source tree at a fixed path?**
There is no longer a list to enrol it in. **Make it hermetic**: plant into and
build from a scratch copy under your own `mktemp -d`. `plugin.test.sh`'s
`mk_source_copy()` / `copy_build()` pair is the worked example — it tars the repo
(minus `.git` and `plugin/`) into a scratch root and rewrites the build path to
match, so a sub-test that needs a *real* build over a *mutated* source gets one
without touching the repo.

You do not have to remember to do this. The runner's before/after fingerprint
fails the battery on any live-tree write, so a suite that skips it reds loudly
with the path named, rather than flaking someone else's suite three runs later.
That is the point of the inversion: the property is checked, not catalogued.

The guard is behaviorally covered in `setup-control-plane.test.sh` (the
runner-behavior home) — T11j (a live-tree writer fails the battery, and the report
names the path), T11k (a clean battery stays green and the guard stays silent),
T11l (an unfingerprintable repo degrades to an *announced* unchecked run) — and
the T7 drift guard keeps the CI loop's comment in step, including the distinction
that serial execution does **not** subsume hermeticity.

**Axis 2 — does it execute anything that can reach state OUTSIDE the repo?**
In practice that means `setup-control-plane.sh`, whose `--sync` refreshes the
user-scope plugin cache. Neither the old carve nor the new fingerprint guard
helps here: serializing suites against each other does not stop one of them
writing to `~/.claude/plugins/cache/`, and the fingerprint covers the code repo,
which that path is not inside. Export the seam suite-wide instead, before the
first run:

```bash
export GUV_PLUGINS_DB="$WORK/no-such-plugins-db.json"
```

and add a positive control asserting the real cache was never reached, so the
isolation stays proven rather than assumed:

```bash
grep -q 'plugin cache' "$WORK/setup.log" && no "hermeticity: …" || ok "hermeticity: …"
```

The control fires only on a machine where the hazard is real — the maintainer
machine this guards — and that is the machine it needs to fire on. A suite that
happens not to reach the cache today because no plugin is installed is isolated
by accident, and an accident is not isolation.
