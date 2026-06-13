---
name: task
description: "Scoped-change entry point. Understand → red/green TDD → evaluate → done, with no phase ceremony. In a phased project it also classifies in-phase feedback (bug fix, quality improvement, or new capability) and routes the doc updates. Use when the user reports something broken, requests a change to how a feature works, or asks for something new."
user-invocable: true
---

# Task — Scoped Change Entry Point

Process a single scoped change and carry it through to a verified, committed result.

This is a **first-class entry point**: it runs whether or not the project has phase
docs. How much ceremony it applies is read from `ceremony` in `.claude/project.json`:

- **`task`** (or any project with no phase docs) — scoped mode. No requirements
  ceremony, no phase docs. Run the change → verify → done loop in Step 3 (Bug Fix
  path) for every change, regardless of how you'd classify it. Skip Steps 1–2's
  doc bookkeeping entirely. This is the common case for adopting/maintaining a repo.
- **`phased`** — in-phase router. Classify the feedback and update the project docs
  so the spec doesn't drift, then implement. Steps 1–2 apply in full.

A missing project-shape artifact (no `docs/REQUIREMENTS.md`, no phase docs) is a
**mode signal, not an error** — it means task mode, so skip the doc steps cleanly.

**Routing note ([8.1]).** `/guv:task` is **content-driven**: it processes the specific
change in `$ARGUMENTS` and is legitimate in any ceremony — so it does *not*
redirect away from an explicit request. It is, however, the door the deterministic
router (`"${CLAUDE_PLUGIN_ROOT}"/scripts/route.sh`) selects for **session entry** in a `ceremony=task`
project, and the door the phased entry commands (`/guv:start-phase`, `/guv:resume`) and
`/guv:init-project`/`/guv:onboard` redirect *to* when invoked in a scoped project. If you
landed here at session start with no specific change in mind, that redirect was
the router doing its job — describe the change and proceed.

## Input

$ARGUMENTS

This should describe what needs to change — a bug you found, a quality improvement
you want, or a new capability to add. If no arguments are provided, ask what the
change is.

## Step 1 — Classify (phased projects only)

If `ceremony` is `task`/`onboard`, or there is no `docs/REQUIREMENTS.md`, **skip to
Step 3 and use the Bug Fix path** — there is no spec to keep in sync, so just make
the change with TDD. Otherwise classify the feedback into one of three categories:

### Bug Fix

The deliverable doesn't work as specified. The spec already defines the correct behavior; the implementation is wrong.

**Signals:** "X is broken", "this should do Y but it does Z", "there's an error when...", "the output is wrong", a traceback, a test failure, a regression.

**The test:** Does the existing spec/deliverable already describe the correct behavior? If yes → bug fix.

### Quality Improvement

The definition of "done" for an existing deliverable needs to change. This shifts what the deliverable means, not just whether it works.

**Signals:** "X should also do Y", "the approach to X needs to change", "X would be better if...", "I want X to work differently", a fundamental shift in how a feature operates.

**The test:** Does this change what the deliverable means? Would a future session, reading the current spec, implement something different from what you now want? If yes → quality improvement.

### New Capability

An entirely new deliverable that wasn't in the original plan.

**Signals:** "We need a new command for...", "add support for X", "I want a feature that...", something with no corresponding deliverable in REQUIREMENTS.md.

**The test:** Is there an existing deliverable this maps to? If no → new capability.

## Step 2 — Confirm Classification (phased projects only)

Present the classification to the user:

```
Classification: [Bug Fix | Quality Improvement | New Capability]
Rationale: [one sentence explaining why this category]
Affected deliverable: [which deliverable in REQUIREMENTS.md, or "new" for new capabilities]
```

Wait for the user to confirm before proceeding. They may reclassify — if someone says "this is actually a quality improvement, not a bug fix," follow their classification.

## Step 3 — Execute

Run git/commits against the **code** repo via the helper (`bash
"${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh <git args>` — it targets `roots.code`; a no-op for single-repo).

### Bug Fix Path (and the default for `task`/`onboard` mode)

1. Read the code you're about to change — the exports, immediate callers, and shared utilities involved
2. Write a failing test that reproduces the bug / encodes the desired behavior
3. Make the change
4. Verify the test passes (run `commands.test` from the manifest)
5. Run the full test suite to check for regressions
6. Run `/guv:evaluate` (both reviewers) on the change and fix what they surface
7. Commit to the code repo with a conventional message: `git -C "$CODE" commit …` — `fix(scope): …` for a bug, `feat(scope): …` / `refactor(scope): …` otherwise
8. If a session handoff is in play, note it under **Completed**

No doc updates needed — either the spec already describes the correct behavior, or (in task mode) there is no spec to update.

### Quality Improvement Path (phased projects)

1. **Update docs first:**
   - Update the affected deliverable's wording in `docs/REQUIREMENTS.md` to reflect the new definition
   - Update `docs/ARCHITECTURE.md` if the change affects technical design
   - Update `docs/PHASE_STATUS.md` if the deliverable wording changed (keep the same status marker)
   - Present the doc changes to the user for approval before implementing
2. **Then implement:**
   - Write tests for the new behavior
   - Implement the change
   - Run the full test suite
   - Commit the doc updates (control plane) and implementation (code repo) together: `refactor(scope): description` or `feat(scope): description` depending on scope
3. Run `/guv:evaluate` and address findings. Note in the session handoff under **Completed** with a reference to the doc changes

### New Capability Path (phased projects)

1. **Update docs first:**
   - Add the new deliverable to the appropriate phase in `docs/REQUIREMENTS.md`
   - Add to `docs/PHASE_STATUS.md` with ⬜ status
   - Update `docs/ARCHITECTURE.md` if it introduces new components or data flows
   - Present the doc changes to the user for approval before implementing
2. **Then implement** using the standard red/green TDD workflow
3. Run `/guv:evaluate` and address findings. Commit with `feat(scope): description`
4. Update `docs/PHASE_STATUS.md` to ✅ when complete

## Reminders

- Multiple pieces of feedback can be processed in one session. Handle each one independently.
- A single piece of feedback might contain both a bug fix and a quality improvement. Split them — fix the bug first (no doc ceremony), then process the improvement (doc-first, phased only).
- If you're unsure whether something is a bug fix or a quality improvement in a phased project, default to quality improvement. It's better to update docs unnecessarily than to let the spec drift silently.
- If the feedback is about something in a future phase, note it in `docs/sessions/` under **Session Notes** for the relevant phase. Don't implement across phase boundaries.
