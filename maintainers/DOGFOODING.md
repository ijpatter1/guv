# Dogfooding the harness (mechanism 1: control-plane split)

> **Maintainer-only.** This directory is about _developing the harness_, not using it.
> A consumer who forks the template can delete `maintainers/` — it never affects a
> rendered project.

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

```
~/dev/
├── claude-code-sandbox/            # THE HARNESS = roots.code. We edit this; product
│                                   #   commits (real template improvements) land here.
│                                   #   Stays clean: no rendered CLAUDE.md, no feedback
│                                   #   data, docs/ stay placeholders.
└── claude-code-sandbox-control/    # CONTROL PLANE = cwd. Claude launches here. Its own
    ├── .claude/                    #   git repo, its own commit stream.
    │   ├── (core copied from the harness — commands, skills, agents, hooks, RULES,
    │   │   scripts, schema, settings)   ← refreshed by setup-control-plane.sh --sync
    │   ├── project.json             #   dogfooding manifest: roots.code → the harness,
    │   │                            #   ceremony: task
    │   ├── run-harness-tests.sh     #   commands.test → runs the harness's bash suites
    │   └── feedback/feedback.ndjson #   harness friction lives HERE, not in the template
    ├── CLAUDE.md                    #   "you are improving the harness at roots.code"
    └── docs/sessions/               #   handoff artifacts live HERE
```

**Artifact routing — the whole point:**

| Artifact                                                            | Lands in                           |
| ------------------------------------------------------------------- | ---------------------------------- |
| Template improvements (commands, skills, hooks, tests, …)           | **harness repo** (product commits) |
| Rendered `CLAUDE.md`, session handoffs, feedback log, dev-plan docs | **control plane**                  |
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
bash maintainers/setup-control-plane.sh ../claude-code-sandbox-control --sync
```

So the loop is: edit in the harness repo → run its tests there → `--sync` into the
control plane → exercise the changed harness from a control-plane session → commit the
harness change in the harness repo, and any session artifacts in the control plane.

## Why `ceremony: task`

The harness is maintained via **scoped changes** (every improvement this cycle was a
`/task`), not a phased greenfield build. So:

- The **control plane's** manifest is `ceremony: task` (set by the setup script). Phase
  machinery (`/start-phase`, handoff Steps 7–8) no-ops; no phase docs to fill, so no
  phase-doc shell to leak.
- **This repo's own `.claude/project.json`** is now `ceremony: task` too, which (a)
  matches how it's actually developed and (b) resolves the prior inconsistency of
  claiming `phased` while shipping placeholder phase docs. The full greenfield `phased`
  flow is still fully available to consumers — `/init-project` sets `phased` when it
  scaffolds from a spec.

## Setup

```bash
# from the harness repo:
bash maintainers/setup-control-plane.sh ../claude-code-sandbox-control
cd ../claude-code-sandbox-control
claude            # or: make sandbox, once you copy a Makefile / point at the harness
/status           # confirm roots.code points back at the harness, ceremony: task
```

Re-run with `--sync` after editing the harness to pull your changes into the control
plane before testing them.

## What still lives in the harness repo

Durable maintainer tooling (this file, the setup script, the CI clean-check —
`check-template-clean.sh` here plus the `maintainer-ci` workflow at
`.github/workflows/template-clean.yml`, which is pinned to the template repo so it
never runs in a consumer copy) is the
_bootstrap_ for the split, so it lives here — you need it before the control plane
exists. Ongoing **session** artifacts do not: they belong in the control plane. The
distinction is the same one the feedback log's `routing` field encodes: _is this about
building the harness (quarantine to the control plane), or part of the shipped template
(commit here)?_
