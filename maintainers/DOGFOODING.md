# Dogfooding the harness — the control-plane split

> **Maintainer-only.** This directory is about _developing_ Governor (guv), not using
> it. A consumer who forks the template can delete `maintainers/` — it never affects a
> rendered project. (The repo is `ijpatter1/guv`; the local clones in the examples
> below keep the original `claude-code-sandbox` directory names — directory names are
> yours, the repo identity is not.)

## The problem

This repo is **both the product and its own first consumer.** Using the harness's full
workflow on itself (`/handoff` artifacts, the feedback log, README/CLAUDE.md render,
phase docs) produces **project-shell (L3) artifacts** — exactly what the template must
_not_ ship. We want full functionality without those artifacts contaminating the
template.

## The mechanism

Eat our own control-plane split. The harness repo becomes the **code repo**
(`roots.code`); a **separate sibling control plane** holds every session artifact. The
split keeps the template clean _by construction_ — the shell physically lives in a
different repo — and it dogfoods the least-tested path in the harness.

Control planes are named **`<project>-guv`** by convention — a suffix, not a prefix
(`guv-` as a prefix already means harness-owned-and-sync-replaced, and the control
plane is precisely the artifact guv must never overwrite). The suffix reads as a
possessive — the project's guv — and sorts adjacent to its project. The convention
is human-facing only: the setup script offers it as the default directory name and
the docs teach it, but no script ever discovers a control plane by name — the
manifest (`roots`) is the sole machine pointer. The harness's own control plane is
therefore `guv-guv`, deliberately. Renaming a pre-convention control plane to match
is a manual human act, not a deliverable: by the convention's own terms, nothing
machine-readable knows or cares what the directory is called.

```
~/dev/
├── guv/                            # THE HARNESS = roots.code (repo: ijpatter1/guv).
│                                   #   We edit this; product commits (real template
│                                   #   improvements) land here. Stays clean: no rendered
│                                   #   CLAUDE.md, no feedback data, docs/ stay placeholders.
└── guv-guv/                        # CONTROL PLANE = cwd (<project>-guv). Claude launches
    ├── .claude/                    #   here. Its own git repo, its own commit stream.
    │   ├── (core copied from the harness — commands, skills, agents, hooks, guv-* rules,
    │   │   workflows, scripts, schema, settings)  ← refreshed by setup-control-plane.sh --sync
    │   ├── project.json             #   dogfooding manifest: roots.code → the harness
    │   ├── run-harness-tests.sh     #   commands.test → runs the harness's bash suites
    │   │                            #   (generated; harness-owned — --sync refreshes it too)
    │   └── feedback/feedback.ndjson #   harness friction lives HERE, not in the template
    ├── CLAUDE.md                    #   "you are improving the harness at roots.code"
    └── docs/                        #   sessions/ handoffs; when an initiative is active,
                                     #   the phase docs (REQUIREMENTS/ARCHITECTURE/PHASE_STATUS)
```

**Artifact routing — the whole point:**

| Artifact                                                            | Lands in                           |
| ------------------------------------------------------------------- | ---------------------------------- |
| Template improvements (commands, skills, hooks, tests, plugin, …)   | **harness repo** (product commits) |
| Rendered `CLAUDE.md`, session handoffs, feedback log, phase docs    | **control plane**                  |
| `agent-memory/`                                                     | control plane (gitignored there)   |

`git -C $(roots.code)` operations target the harness; doc/session/feedback commits stay
in the control plane. Two commit streams, by design — and the template repo never sees a
single shell artifact.

## Why copy-and-sync, not symlink

The control plane's `.claude/` core is a **copy** of the harness, not a symlink. That is
deliberate: with a symlink you'd be _running on the harness you're editing_, so a
half-finished edit to a hook or command would brick the live session (the exact "don't
modify the harness you're standing on" hazard the auto-mode classifier keeps flagging).

With a copy, edits land in the harness repo (the source of truth, where commits go) and
**don't affect the running session until you deliberately sync them in**:

```bash
bash maintainers/setup-control-plane.sh --sync    # destination defaults to ../guv-guv
```

So the loop is: edit in the harness repo → run its tests there → `--sync` into the
control plane → exercise the changed harness from a control-plane session → commit the
harness change in the harness repo, and any session artifacts in the control plane.

What `--sync` refreshes is ownership-scoped, not tree-wide: harness-owned surfaces
(commands, skills, agents, hooks, `guv-*` rules, harness-shipped workflows, scripts,
schema, settings — and the generated `run-harness-tests.sh`, which carries no consumer
state) are replaced; consumer-owned state (the manifest, `CLAUDE.md`, unprefixed rules,
consumer-saved workflows, docs, feedback) is never touched. `setup-control-plane.test.sh`
enforces both halves.

## The plugin, and why `--sync` survives it

Since Phase 5 the durable core also ships as the **guv plugin**: `plugin/` is generated
by `maintainers/build-plugin.sh` from `.claude/` + `maintainers/plugin-src/` (authored
plugin-only sources), and the marketplace serves it from the default branch. That gives
the harness two delivery channels, and the `setup-control-plane.sh` disposition is
decided by audience:

- **Consumers, default path:** install the plugin. Updates arrive as versioned releases
  — see `RELEASING.md`: the version bump _is_ the release. On this path plugin updates
  replace `--sync` entirely; nothing in a plugin-installed project ever runs this
  script.
- **Consumers, template-clone fallback:** kept and supported — for forks that customize
  harness-owned files (the plugin's surfaces aren't editable; a clone's are) or
  environments that can't install plugins. `--sync` remains their update path, with
  the documented caveat that it replaces harness-owned surfaces **wholesale** (see
  the ownership-scoped list above — only unprefixed rules and consumer-saved
  workflows are protected): a fork that has edited those surfaces re-applies its
  edits after a sync or updates selectively, and the README says so. The README's
  Quick Start states the decided migrate-or-keep-syncing answer for existing clones.
- **Maintainers (this doc):** the script is **kept, scoped to maintainers**, because
  the dogfooding loop tests **unreleased** core changes. By RELEASING.md's own framing,
  a change that hasn't shipped in a version bump reaches no plugin consumer — so plugin
  updates structurally cannot serve the loop. `--sync` is the only mechanism that moves
  not-yet-released core into a live control plane.

### Standing plugin install (dual load)

A maintainer machine may also have `guv@guv` installed at user scope — dogfooding the
released plugin while developing the next one. A control-plane session then loads BOTH
surfaces: the project `.claude/` copy (possibly carrying unreleased changes) and the
plugin's `/guv:`-namespaced copies (the last release). Expect doubled command listings.
The plugin's `hooks.json` rides along too; its reviewer read-only guard is
agent-type-gated, so it stays inert outside `guv:`-spawned reviewers. When testing
unreleased changes, mind which copy you invoke: bare names are the synced project copy,
`/guv:` names are the release.

## Ceremony: seeded `task`, flipped per initiative

The setup script seeds the control plane's manifest with `ceremony: task` — the
harness's resting state is scoped maintenance, where every improvement is a `/task`.
When a phased initiative runs against the harness, `/plan-initiative` flips the control
plane to `ceremony: phased` and generates the phase docs in the control plane's `docs/`
(the native-alignment initiative did exactly this on 2026-06-10). There is no revert
machinery, by design: phased with a fully-✅ tracker is itself a clean resting state —
`/task` works inside phased projects, and the next `/plan-initiative` picks up from
there; reverting to `task` is a manual, optional act. Nothing about the split changes
either way.

**This repo's own `.claude/project.json`** stays `ceremony: task`: it matches how the
template's defaults are maintained and ships no phase docs. The full greenfield
`phased` flow remains available to consumers — `/init-project` sets `phased` when it
scaffolds from a spec.

## Setup

```bash
# from the harness repo:
bash maintainers/setup-control-plane.sh    # destination defaults to ../guv-guv (the <project>-guv convention)
cd ../guv-guv
claude
/status           # confirm roots.code points back at the harness (ceremony starts as task)
```

Re-run with `--sync` after editing the harness to pull your changes into the control
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
post-commit hook the harness doesn't own is never touched.

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

## What still lives in the harness repo

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
building the harness (quarantine to the control plane), or part of the shipped template
(commit here)?_
