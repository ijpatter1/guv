---
name: session-management
description: Supplementary conventions for session handoff artifacts, phase status tracking, and context continuity across work sessions. Core conventions are in CLAUDE.md; this skill provides additional detail on context continuity patterns and phase transitions.
user-invocable: false
---

# Session Management

This skill defines how session state is tracked and transferred between work sessions. Follow these conventions whenever reading or writing session artifacts or updating phase status.

## Session Artifacts

Session handoff artifacts live in `docs/sessions/` and follow the naming convention:

```
session-YYYY-MM-DD-NNN.md
```

Where NNN is a zero-padded sequence number for the day (001, 002, etc.). To determine the next number, list existing files for today's date and increment.

### Reading Session Artifacts

When loading context from a previous session:

1. Read the **most recent** file in `docs/sessions/` (sort by filename descending — the `session-YYYY-MM-DD-NNN` naming convention ensures lexicographic sort matches chronological order)
2. Focus on these sections first: **In Progress**, **Blocked**, **Next Steps**, **Evaluator Results**
3. Cross-reference **Completed This Session** with `docs/PHASE_STATUS.md` to confirm the tracker is up to date
4. Check **Issues & Technical Debt** for any unresolved items that need attention
5. Read **Session Notes** for implicit context — architecture decisions, gotchas, environment changes

If the most recent session artifact references unresolved critical issues from the evaluator, address those before starting new feature work.

### Writing Session Artifacts

When generating a handoff artifact:

- **Be concrete, not vague.** "Built the ContactForm component" is useless. "Built ContactForm with email, name, and message fields. Fires `form_start` on first field focus and `form_submit` on submission. Integrated with data layer schema. 4 tests added covering render, validation, submission success, and submission error" is useful
- **Include commit hashes.** The next session can use these for `git show` / `git diff` against the **code** repo (`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh show <hash>`, a no-op for single-repo) to quickly inspect specific changes. Note that doc/session commits live in the control plane and product commits in the code repo, so cite hashes with their repo when the roots differ.
- **Don't omit uncomfortable information.** If you cut a corner, stubbed something, or made a tradeoff you're not confident about, say so. The next session needs to know
- **Keep "Next Steps" actionable.** Each item should be specific enough that the next session can start implementing immediately without additional research. Bad: "Continue working on the event pipeline." Good: "Implement the Pub/Sub publishing tag in sGTM — the topic is configured but the custom tag template hasn't been created yet. Start with `infrastructure/sgtm/tags/pubsub-publisher.tpl`"

## Phase Status Tracker

`docs/PHASE_STATUS.md` is the living document that tracks completion across all phases. It is the single source of truth for what's done and what remains.

### Update Rules

- Update after completing a deliverable, not after every commit
- Mark deliverables with clear status indicators: ✅ complete, 🔄 in progress, ⬜ not started, ❌ blocked
- When marking something complete, add the date and the session reference (e.g., "✅ 2026-03-25, session-2026-03-25-001"). These completion annotations are tracker-local: in a grammar tracker (see the `phase-docs` skill, "Tracker grammar") they go **after** the `` `[deps: …]` `` token, and they never sync back to REQUIREMENTS
- When marking something blocked, note what it's blocked on
- When a phase is fully complete (all deliverables ✅), add a completion date to the phase header
- Never remove or reorder deliverables — the list should match `docs/REQUIREMENTS.md` exactly. IDs and deps tokens are part of the deliverable wording and sync verbatim with it; structural changes follow the grammar's append-only rules (insert appends the next ordinal at phase end, descope marks ❌ with a dated note, deletion does not exist)

### Reading Phase Status

When determining what to work on:

1. Find the current phase (the one with deliverables that aren't all ✅)
2. Look for 🔄 items first — these are in progress and should be finished before starting new work
3. Look for ❌ items — check if blockers have been resolved
4. Then look for ⬜ items. In a grammar tracker (deliverables carry `**[N.M]**` IDs and `` `[deps: …]` `` tokens — see the `phase-docs` skill, "Tracker grammar"), the deps tokens are the dependency source: a ⬜ item is ready when all its deps are ✅, and document order is presentation only. In a LEGACY (token-free) tracker, the ordering in REQUIREMENTS.md reflects dependency order, as before

## Context Continuity Patterns

### Short Break (same day, resuming soon)

Just run `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh log --oneline -10` and the project's test command (`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-cmd.sh test`) to reorient. The session artifact from earlier today has the full context.

### Overnight / Next Day

Use `/guv:next` — the light daily-driver door: it resolves the ready-frontier and presents the next pick with a plan, no boundary ritual. Read the latest session artifact carefully, especially Session Notes and Issues. (Reach for `/guv:phase N` only when you're *crossing into a new phase*, not for a same-context resume.)

### After Multiple Days Away

Use `/guv:phase N` (the boundary door — a long gap warrants its full deep-read) and also read the 2-3 most recent session artifacts, not just the latest. Check `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh log --oneline -30` for a broader view of recent progress. Run the project's test and build commands (`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-cmd.sh test` / `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-cmd.sh build` — each skips loudly when null) to confirm the codebase is healthy.

### After a Phase Transition

When starting a new phase:

1. Read the completed phase's final session artifact for any carryover issues
2. Ensure the completed phase branch has been merged to `main` and the merge is clean. Phase branches live in the **code** repo, so run branch ops there (a no-op for single-repo): `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh checkout main && bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh merge phase/N-previous-name`
3. Read the new phase's section in `docs/REQUIREMENTS.md` thoroughly
4. Read relevant sections of `docs/ARCHITECTURE.md`
5. Create the new phase branch from `main` in the code repo: `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh checkout -b phase/N-description`
6. The first session artifact for the new phase should note any dependencies on prior phases and confirm they're satisfied

## Initiative Boundaries

A project can run multiple phased initiatives over its life (`/guv:plan`). Session
continuity crosses those boundaries; these conventions keep it intact:

- **Archive layout:** a finished initiative's REQUIREMENTS + PHASE_STATUS pair freezes in
  `docs/initiatives/NNN-<name>/` — read-only history, never edited again. The top-level
  pair always describes the *current* initiative. ARCHITECTURE.md persists at top level
  and is revised in place. Full conventions live in the `phase-docs` skill;
  `"${CLAUDE_PLUGIN_ROOT}"/scripts/archive-initiative.sh` does the mechanical part.
- **Continuous phase numbering:** phase numbers never reset — the next initiative starts
  at (highest phase ever used) + 1. So a handoff's `Phase:` field, a `phase/N-*` branch,
  or a `docs/uat/phase-N-*` artifact is globally unique across the project's whole
  history; cite them without qualifying which initiative.
- **The lineage header** at the top of `docs/REQUIREMENTS.md` is the map: one line per
  archived initiative (phase range + archive dir) plus the current initiative's range and
  governing spec. When reading an old handoff that references a phase outside the current
  range, the lineage header tells you which archive directory holds its tracker.
- **`docs/sessions/` is continuous** — never archived, never split per initiative. The
  read-recent-handoffs pattern and the citation checker rely on it being one unbroken
  journal.
