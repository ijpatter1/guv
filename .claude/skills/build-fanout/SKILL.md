---
name: build-fanout
description: "Drive a build fan-out — N deliverables built in parallel lanes, then gated and landed. The runbook for the three-stage recipe (execute → gate → join) plus the build-fanout workflow it launches. Use when you have several independent, ready deliverables to build at once."
user-invocable: true
---

# Build Fan-Out — the runbook

A build fan-out builds several independent deliverables **in parallel lanes**, gates
each with the calibrated dual review, and lands the ones that pass. This is the
build-half companion to `/eval-parallel` (which gates one commit range); here the
fan-out spans many lanes.

It completes the [7.4]/[7.5] surface: Phase 7 shipped the deterministic JOIN
(`lane-dispatch.sh`) and the gated queue (`merge-queue.sh`), but the EXECUTION and the
Rule-14 GATE were an unscripted manual job. This runbook + the `build-fanout` workflow
are the missing door, so a fan-out is *driven from a captured recipe*, not reconstructed
from four scripts by hand.

**The seam, in one line: the gate decides, dispatch lands.** Three stages, three
drivers — keep them distinct.

## Posture (do not drift from this)

- **Human-triggered.** A person decides to fan out and on what. The resolver says what
  *may* be worked; a person decides what *is*.
- **Conversational build half.** The build agents are spawned conversationally from the
  main session — not auto-driven — so each is user-confirmed and carries the behavioral
  core natively (see below).
- **Single-writer JOIN.** Only the orchestrator writes the shared surface at the join.
  Lanes never touch it.

## Prerequisite — provision each code repo ([10.10])

A lane is a git worktree of a code repo, and a lane builder runs `/task` *inside* it —
which needs the guv-core (a `ceremony=task` manifest + the `.worktrees/` gitignore) to
be **committed** in that repo, so the worktree inherits it. In the split control-plane
model a code repo is not guv by default, so provision it once:

```
bash .claude/provision-code-repo.sh <code-repo-path> --test "<the repo's test command>"
```

It is idempotent / no-clobber — an already-provisioned repo (e.g. guv itself) is left
untouched. `guv-lane.sh create` loud-stops if a repo is unprovisioned, so this never
fails silently.

## Stage 1 — EXECUTION (conversational; one lane builder per deliverable)

For each deliverable, create a lane and spawn a builder into it:

1. `bash .claude/guv-lane.sh create <id> <slug>` — a worktree at
   `.worktrees/lane-<id>/` on branch `lane/<id>-<slug>` in the code repo.
2. Spawn the calibrated **`@lane-builder`** agent (BY NAME, Rule 14 — not an ad-hoc
   worker) into that lane, told its deliverable id and worktree path. The lane builder:
   - acquires the behavioral core **natively** — an Agent-tool subagent inherits this
     project's `CLAUDE.md` + the `guv-*` rules, and preloads the `task` skill — so it is
     a real project-aware agent, not a prompt-injected imitation (this is the resolved
     mechanism: native inheritance + per-lane `/task`, not hand-carried conventions);
   - builds via `/task` — **red→green TDD**, confined to source, commit sources only;
   - **never touches what the JOIN owns** (trackers, the derived `plugin/` tree, shared
     prose) — it routes prose deltas back as docFragments in its `.lane-output.json`;
   - writes its `.lane-output.json` sidecar and reports.

The build half is conversational because workflow subagents run in acceptEdits mode and
because the spec's posture is user-confirmed building — and because that path is what
carries the behavioral core natively.

## Stage 2 — the GATE (`build-fanout` workflow; the gate decides)

Launch the **`build-fanout`** workflow over the built lane ids (single- or multi-lane):

```
/build-fanout <id> <id> …
```

Per lane it assembles the acceptance bundle (`merge-queue.sh gate-input <id>` — code
assembles the input, Rule 12) and runs the calibrated **`evaluator` + `reviewer`** BY
NAME (Rule 14), concurrently. It carries the **lane↔join responsibility split** to both
reviewers — the derived `plugin/` rebuild, the drift battery, and docFragment prose
assembly are the JOIN's, not the lane's — so neither grades a join-owned step as a lane
defect (the calibration bug this closes). It returns **structured per-lane verdicts**
with a convergence flag.

### The fix-and-re-review loop

A lane is **clear to land only when all Critical and Major findings are closed** (the
convergence criterion). Fixes are applied **conversationally in the main session** — the
workflow does not contain the fix loop (acceptEdits conflicts with the conversational
gate; the chosen model is conversational-fix, not bounded-automated-then-escalate). Fix
the held lane in its worktree, then re-run `/build-fanout` for the next pass. Iterate to
closure before the JOIN.

## Stage 3 — the JOIN (`lane-dispatch.sh`; dispatch lands)

Hand the cleared lanes to the deterministic JOIN:

```
bash .claude/lane-dispatch.sh dispatch <id> <id> …
```

It harvests each lane (the failure contract refuses a dirty/garbage/drifted lane and
captures a durable report), orders cheapest-first through the `merge-queue.sh` queue,
lands what passes, and assembles docFragments. **Dispatch does NOT run the gate and does
NOT build** — it lands what already passed.

The JOIN is the single writer of the shared surface:

- **the trackers** (`docs/PHASE_STATUS.md`, `docs/REQUIREMENTS.md`) — plan mutation is
  `/replan` only, never a lane edit;
- **docFragment-target prose** (CHANGELOG/README) — assembled serially at the join from
  lane outputs, never edited directly by a lane;
- **the derived `plugin/` rebuild** — `maintainers/build-plugin.sh` regenerates it at
  the join (a source-only lane cannot verify the derived tree).

## Summary

`provision-code-repo.sh` (once per repo) → `guv-lane.sh create` + `@lane-builder` via
`/task` (execute) → `/build-fanout` (gate, by name) → fix conversationally + re-gate to
convergence → `lane-dispatch.sh dispatch` (join). The gate decides; dispatch lands.
