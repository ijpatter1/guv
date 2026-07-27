# Dogfooding guv — the control-plane split

> **Maintainer-only.** This directory is about _developing_ Governor (guv), not using
> it. A consumer who forks the template can delete `maintainers/` — it never affects a
> rendered project. (The repo is `ijpatter1/guv`; the local clones in the examples
> below keep the original `claude-code-sandbox` directory names — directory names are
> yours, the repo identity is not.)

## The problem

This repo is **both the product and its own first consumer.** Using guv's full
workflow on itself (`/handoff` artifacts, the feedback log, README/CLAUDE.md render,
phase docs) produces **project-shell (L3) artifacts** — exactly what the template must
_not_ ship. We want full functionality without those artifacts contaminating the
template.

## The mechanism

Eat our own control-plane split. The guv repo becomes the **code repo**
(`roots.code`); a **separate sibling control plane** holds every session artifact. The
split keeps the template clean _by construction_ — the shell physically lives in a
different repo — and it dogfoods the least-tested path in guv.

Control planes are named **`<project>-guv`** by convention — a suffix, not a prefix
(`guv-` as a prefix already means core-owned-and-sync-replaced, and the control
plane is precisely the artifact guv must never overwrite). The suffix reads as a
possessive — the project's guv — and sorts adjacent to its project. The convention
is human-facing only: the setup script offers it as the default directory name and
the docs teach it, but no script ever discovers a control plane by name — the
manifest (`roots`) is the sole machine pointer. guv's own control plane is
therefore `guv-guv`, deliberately. Renaming a pre-convention control plane to match
is a manual human act, not a deliverable: by the convention's own terms, nothing
machine-readable knows or cares what the directory is called.

```
~/dev/
├── guv/                            # guv = roots.code (repo: ijpatter1/guv).
│                                   #   We edit this; product commits (real template
│                                   #   improvements) land here. Stays clean: no rendered
│                                   #   CLAUDE.md, no feedback data, docs/ stay placeholders.
└── guv-guv/                        # CONTROL PLANE = cwd (<project>-guv). Claude launches
    ├── .claude/                    #   here. Its own git repo, its own commit stream.
    │   ├── (core copied from guv — commands, skills, agents, hooks, tests,
    │   │   guv-* rules, workflows, scripts, schema, settings)  ← refreshed by --sync
    │   ├── project.json             #   dogfooding manifest: roots.code → guv
    │   ├── run-core-tests.sh     #   commands.test → runs the core's bash suites
    │   │                            #   (generated; core-owned — --sync refreshes it too)
    │   └── feedback/feedback.ndjson #   guv friction lives HERE, not in the template
    ├── CLAUDE.md                    #   "you are improving guv at roots.code"
    └── docs/                        #   sessions/ handoffs; when an initiative is active,
                                     #   the phase docs (REQUIREMENTS/ARCHITECTURE/PHASE_STATUS)
```

**Artifact routing — the whole point:**

| Artifact                                                            | Lands in                           |
| ------------------------------------------------------------------- | ---------------------------------- |
| Template improvements (commands, skills, hooks, tests, plugin, …)   | **guv repo** (product commits) |
| Rendered `CLAUDE.md`, session handoffs, feedback log, phase docs    | **control plane**                  |
| `agent-memory/`                                                     | control plane (gitignored there)   |

`git -C $(roots.code)` operations target guv; doc/session/feedback commits stay
in the control plane. Two commit streams, by design — and the template repo never sees a
single shell artifact.

### The fix loop: `--only`, and the recorded verdict

`commands.test` runs all 71 suites and costs ~13 minutes on a quiet machine. A fix loop
does not need that, and paying it per iteration is what
`docs/spikes/battery-loop-cost-attack.md` (control plane) was written to stop. Two
mechanisms, both in `run-core-tests.sh`:

```bash
bash .claude/run-core-tests.sh --only 'replan'    # one suite (or a glob), while you iterate
bash .claude/run-core-tests.sh                    # the whole battery, once, before you commit
bash .claude/battery-result.sh read               # what the last whole-tree run proved
```

Two rules make this safe rather than merely fast:

- **A `--only` run is not a verdict.** It covers the suites it names and nothing else, and
  it deliberately **records nothing** — a filtered result must never overwrite a whole-tree
  one. Report it as what it is.
- **`read` is provenance-checked, not a cache.** It hashes the *content* of every tracked
  and untracked non-ignored file — plus each one's executable bit — and refuses (exit 3)
  the moment a byte or a mode moves. A green it returns describes the tree in front of you;
  a stale green consumed as fresh is worse than no result, because it looks like
  verification. This is the reader QA uses, so the battery is paid for once per tree rather
  than once per reviewer.
- **A commit does not invalidate it, and that is deliberate.** `git add` and `git commit`
  move no working-tree byte, so a verdict earned before the commit still verifies after it
  — which is the normal QA order (run the battery, commit, review the commit). An earlier
  revision hashed `HEAD` and `git diff HEAD` alongside the content and refused every
  post-commit read; both QA reviewers hit it minutes apart on 2026-07-27, reviewing the
  commit that shipped the mechanism. The tradeoff: the record no longer sees the index, so
  a suite whose result depends on *trackedness* rather than content (`git grep` takes its
  file set from the index) is outside what it can promise — a written limit, pinned by
  T11g, not a surprise. The runner's hermeticity guard keeps its own HEAD and porcelain
  checks, so staging or committing *during* a battery is still caught.

The battery also fingerprints the source tree before and after itself and fails on a
mismatch. **Do not edit the tree while a battery runs** — you will red it, correctly, and
the message will be about hermeticity rather than about your change. What that guard does
and does not prove is `maintainers/BATTERY-HERMETICITY.md`; read its "three honest limits"
before writing a suite that plants a fixture.

## Why copy-and-sync, not symlink

The control plane's `.claude/` core is a **copy** of guv's core, not a symlink. That is
deliberate: with a symlink you'd be _running on the core you're editing_, so a
half-finished edit to a hook or command would brick the live session (the exact "don't
modify the core you're standing on" hazard the auto-mode classifier keeps flagging).

With a copy, edits land in the guv repo (the source of truth, where commits go) and
**don't affect the running session until you deliberately sync them in**:

```bash
bash maintainers/setup-control-plane.sh --sync    # destination defaults to ../guv-guv
```

So the loop is: edit in the guv repo → run its tests there → `--sync` into the
control plane → exercise the changed core from a control-plane session → commit the
guv change in the guv repo, and any session artifacts in the control plane.

What `--sync` refreshes is ownership-scoped, not tree-wide: core-owned surfaces
(commands, skills, agents, hooks, tests, `guv-*` rules, guv-shipped workflows,
scripts, schema, settings — and the generated `run-core-tests.sh`, which carries no
consumer state) are replaced; consumer-owned state (the manifest, `CLAUDE.md`,
unprefixed rules, consumer-saved workflows, docs, feedback) is never touched.
`setup-control-plane.test.sh` enforces both halves.

The synced `.claude/tests/` copy is the **installation's self-check** ([7.7]): the
suites resolve their targets relative to their own location, so a plane's copy
tests the plane's *installed* scripts — the one-sync-behind machinery actually
flying your sessions — not the source. Run it on demand from the plane root,
**aggregated and stderr-gated** (a bare loop exits with the last suite's status —
the green-summary-above-an-error class the runner's header documents):

```bash
fail=0
for t in .claude/tests/*.test.sh; do
  err=$(mktemp); bash "$t" 2>"$err" || fail=1
  [ -s "$err" ] && { echo "[stderr] $(basename "$t")"; cat "$err"; fail=1; }
  rm -f "$err"
done
[ "$fail" -eq 0 ] && echo "self-check: PASS" || { echo "self-check: FAIL"; false; }
```

Suites whose subjects a plane doesn't carry skip cleanly and say so — the
maintainers tooling, the plugin tree, the sandbox tier, and the template doc
surface all live source-side, so expect roughly a dozen suites asserting and
the rest visibly skipping. (Two boundary notes: the installed post-commit
render hook is outside this loop's reach — it is generator-tested source-side;
to `cmp` it, run the installer against a scratch directory and compare that
fixture plane's hook. And the shape detector keys on `maintainers/`: a clone
that keeps `maintainers/` reads as source-shaped to the suites, so prune
`maintainers/` before pruning doc surfaces — keeping one without the other is
an unsupported shape that fails loud by design.) This never replaces the dogfooding
battery — `commands.test` keeps running the source's suites via `roots.code` —
but for a generic `<project>-guv` it is the only guv verification that
exists, and on any plane it is what catches a bad or partial sync.

## The plugin, and why `--sync` survives it

Since Phase 5 the durable core also ships as the **guv plugin**: `plugin/` is generated
by `maintainers/build-plugin.sh` from `.claude/` + `maintainers/plugin-src/` (authored
plugin-only sources), and the marketplace serves it from the default branch. That gives
guv two delivery channels, and the `setup-control-plane.sh` disposition is
decided by audience:

- **Consumers, default path:** install the plugin. Updates arrive as versioned releases
  — see `RELEASING.md`: the version bump _is_ the release. On this path plugin updates
  replace `--sync` entirely; nothing in a plugin-installed project ever runs this
  script.
- **Consumers, template-clone fallback:** kept and supported — for forks that customize
  core-owned files (the plugin's surfaces aren't editable; a clone's are) or
  environments that can't install plugins. `--sync` remains their update path, with
  the documented caveat that it replaces core-owned surfaces **wholesale** (see
  the ownership-scoped list above — only unprefixed rules and consumer-saved
  workflows are protected): a fork that has edited those surfaces re-applies its
  edits after a sync or updates selectively, and the README says so. The README's
  Quick Start states the decided migrate-or-keep-syncing answer for existing clones.
- **Maintainers (this doc):** the script is **kept, scoped to maintainers**, because
  the dogfooding loop tests **unreleased** core changes. By RELEASING.md's own framing,
  a change that hasn't shipped in a version bump reaches no plugin consumer — so plugin
  updates structurally cannot serve the loop. `--sync` is the only mechanism that moves
  not-yet-released core into a live control plane.

**Authoring convention (the namespace pass, [24.1]):** the build rewrites every bare
`/name` skill reference in skill/agent prose to `/guv:name`. A mention qualified as
"built-in `/init`" / "native `/init`" / "bare `/init`" (any skill token) is preserved
**literally** — it names the token (Claude Code's built-in, the source-clone bare
surface) rather than invoking the skill. Prose that means the platform command must
use one of those qualified forms, qualifier directly before the backticked token
and **lowercase** (a sentence-initial "Bare `/init`" is not protected — rephrase so
the qualifier sits mid-sentence) — any other phrasing is silently namespaced. The
mechanism is `_namespace_pass` in `build-plugin.sh`; T12b/T12f in `plugin.test.sh`
hold the carve, with T12f's garble scan case-insensitive so a capitalized-qualifier
slip reds the test battery loudly instead of shipping unnoticed.

### Standing plugin install (dual load)

A maintainer machine may also have `guv@guv` installed at user scope — dogfooding the
released plugin while developing the next one. A control-plane session then loads BOTH
surfaces: the project `.claude/` copy and the plugin's `/guv:`-namespaced copies.
Expect doubled command listings.

The plugin's `hooks.json` is not a passenger — since [19.5] it is the **single
authoritative** hook registration whenever the plugin is present (the synced
`settings.json` ships hooks-free to stop the double-fire). Every hook therefore runs
the **cache's** copy of core, resolved from the hook script's own directory — not the
plane's `.claude/`. That is why `setup-control-plane.sh` refreshes the plugin cache
from the built `plugin/` on create and `--sync`: without it, a fix could sit in
`.claude/` while every hook kept executing the release-frozen copy (see the
`refresh_plugin_cache` comment for the incident that found this).

The refresh covers every guv-owned tree in the cache, **whole** — `agents/`, `hooks/`,
`rules/`, `scripts/`, `shell/`, `skills/`, `tests/`, `workflows/`. Only
`.claude-plugin/` is held back, because its manifest is what the refresh reads to
confirm the cache's identity and the cache path is version-keyed.

So after a sync, **both** surfaces carry source: `/guv:` names are no longer "the last
release" but this repo's built plugin. **That is deliberate, and partial refreshes are
not an option.** A first cut refreshed only the executed trees and froze skill text at
the release; the result was a vintage that was never built or shipped. [24.1] renamed
the greenfield door, so the frozen skill invoked `route.sh --for <its old name>` against
a refreshed router that knows only the new one; the router exited 2, which that skill
documents as "router unavailable — proceed with scaffolding," and the [8.1] routing guard
degraded to fail-open on a live machine. A skill's command line is an interface, and interfaces
do not survive being split across two vintages.

The cost is that this plane no longer gives you a release-vs-source comparison — get
that from a tagged checkout or a second install, which is where it always had to come
from. The reviewer read-only guard is agent-type-gated either way, so it stays inert
outside `guv:`-spawned reviewers.

## Ceremony: seeded `task`, flipped per initiative

The setup script seeds the control plane's manifest with `ceremony: task` — the
guv's resting state is scoped maintenance, where every improvement is a `/task`.
When a phased initiative runs against guv, `/plan` flips the control
plane to `ceremony: phased` and generates the phase docs in the control plane's `docs/`
(the native-alignment initiative did exactly this on 2026-06-10). There is no revert
machinery, by design: phased with a fully-✅ tracker is itself a clean resting state —
`/task` works inside phased projects, and the next `/plan` picks up from
there; reverting to `task` is a manual, optional act. Nothing about the split changes
either way.

**This repo's own `.claude/project.json`** stays `ceremony: task`: it matches how the
template's defaults are maintained and ships no phase docs. The full greenfield
`phased` flow remains available to consumers — `/init` sets `phased` when it
scaffolds from a spec.

## Setup

```bash
# from the guv repo:
bash maintainers/setup-control-plane.sh    # destination defaults to ../guv-guv (the <project>-guv convention)
cd ../guv-guv
claude
/status           # confirm roots.code points back at guv (ceremony starts as task)
```

Re-run with `--sync` after editing guv to pull your changes into the control
plane before testing them.

## Publishing the status view (GitHub Pages)

A phased control plane has a rendered view of its own tracker: `status.html`, a
single self-contained file produced by the sanctioned chain —

```bash
bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json > status.json
bash .claude/render-status.sh status.json > status.html
```

The setup script installs a `.git/hooks/post-commit` hook into the control plane
(create mode; refreshed on `--sync` while present) that runs this chain whenever a
`git commit` touches the tracker and commits the fresh `status.html` as a derived
artifact — rebuilt, never line-merged, never a source. (Hook firing follows
git's actual behavior, verified empirically on git 2.50.1: `git commit` fires
it, and since git 2.25 the sequencer does too — a `revert` or `cherry-pick`
that lands tracker changes regenerates like a direct commit, with cherry-pick's
nested render commit sometimes refused while the sequencer holds the index,
which the loud recording-FAILED rung covers. A merge does NOT fire post-commit
(a default `pull` is fetch+merge, so it follows; a rebase-pull follows the
rebase rule below), and during a rebase the hook's
detached-HEAD guard skips deliberately — in those cases the next direct tracker
commit or a manual render catches up. The revert-fires, cherry-pick-fires, and
merge-no-fire claims are each pinned behaviorally by `render-hook.test.sh`.)
The hook is a **convenience, never a dependency**: with it absent
(or jq missing, or the resolver refusing a malformed tracker) nothing breaks —
the previous render stays in place, the refusal is loud, and the manual
two-liner above always works (`status.json` is the intermediate file; the
generated `.gitignore` keeps it out of the repo — planes created before this
entry existed should add the `status.json` line once by hand). A pre-existing
post-commit hook guv doesn't own is never touched.

To publish: enable GitHub Pages on the control-plane repo (Settings → Pages →
deploy from branch, `main`, `/(root)`), and the committed `status.html` is served
at the Pages URL. **Push is the deploy** — no server, no build step, no pipeline.

**Pages visibility is NOT repo visibility — check your plan before enabling.**
On GitHub Free, private repos cannot enable Pages at all. On Pro/Team, a Pages
site built from a private repo is served **publicly** to anyone with the URL.
Only GitHub Enterprise Cloud offers access-controlled Pages (visible to
enterprise members). So "repo access is the access control" holds in exactly
three shapes: a public control plane (everything was public already), Enterprise
Cloud with Pages access control enabled, or skipping Pages and reading the
committed `status.html` from the repo itself — where repo access genuinely
gates it. If your control plane is private and you are not on Enterprise Cloud,
enabling Pages publishes your tracker to the open internet — decide that
deliberately.

The published surface is declared in the manifest: the optional `views` entry in
`.claude/project.json` (e.g. `"views": { "status": "status.html" }`,
schema-validated). It is **descriptive only** — no execution path reads it; the
declaration exists so the published surface is explicit manifest rather than
implicit convention.

## What still lives in the guv repo

Durable maintainer tooling is the _bootstrap_ for the split, so it lives here — you
need it before the control plane exists:

- this file and `setup-control-plane.sh` (the split itself);
- `RELEASING.md` (what a release is, the bump policy, the release half of the
  feedback drain);
- `build-plugin.sh` + `plugin-src/` (the plugin generator and its authored sources —
  `plugin/` is generated output, drift-guarded by `plugin.test.sh`);
- the CI clean-check: `check-template-clean.sh` plus the `maintainer-ci` workflow at
  `.github/workflows/template-clean.yml`, repo-pinned so it never runs in a consumer
  copy.

Ongoing **session** artifacts do not live here: they belong in the control plane. The
distinction is the same one the feedback log's `routing` field encodes: _is this about
building guv (quarantine to the control plane), or part of the shipped template
(commit here)?_
