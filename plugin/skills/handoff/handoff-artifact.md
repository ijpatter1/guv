# Handoff Artifact Template

The fill-in skeleton for the session handoff artifact that `handoff` Step 6 writes
to `docs/sessions/session-YYYY-MM-DD-NNN.md`. Step 6 points here so the procedure
itself stays short enough to remain resident in context (the cold read found the
all-in-one skill truncated mid-procedure). Read this file when you reach Step 6,
then write the artifact with every section below — the section set is the contract;
drop none of them.

```markdown
# Session Handoff — YYYY-MM-DD-NNN

**Phase:** N — [Phase Name]
**Date:** YYYY-MM-DD

## Completed This Session

For each feature completed, include:

- What was built (brief description)
- Commit hash(es)
- Tests added (count and what they cover)
- Any notable implementation decisions and why they were made

## In Progress

Anything started but not finished:

- What it is
- Current state (what's done, what remains)
- Where to pick up (specific file and function/component)

## Blocked

Anything that can't proceed and why:

- The blocker
- What's needed to unblock it
- Whether it blocks other work

## Issues & Technical Debt

Any issues identified (by you or at a review gate) that weren't resolved this session:

- Issue description
- Severity (critical / important / minor)
- Provenance (in the change under review / in surrounding code)
- Source (technical `/code-review` / alignment `reviewer` / self-identified)
- Where it lives in the code

## Review Results

The session's gate ledger — one entry per gated change ([32.1]: findings, not
scores):

- The change (commit hash or working diff) and which instruments ran: the
  platform review pass, the alignment `reviewer`, or both
- Findings by severity and provenance, each with its disposition — fixed at the
  gate, or recorded under Issues & Technical Debt
- Rounds used (two maximum); at the cap, the three-way call that was made
  (converge / cut scope / accept as debt) and who made it
- Skips and stops, disclosed with reasons: the all-commits-gated-in-band skip,
  a headless skip of the technical pass, or a headless stop

## Test State

- Total tests: N
- Passing: N
- Failing: N (list which ones and why)
- Skipped: N
- Coverage: N% (if coverage reporting is configured)

## Build State

- Build: clean / errors / warnings
- Lint: clean / errors / warnings
- TypeScript: strict compliance / issues noted

## Next Steps

The logical next feature(s) to tackle in the next session, in priority order:

1. [Feature] — [why it's next] — [estimated complexity: small/medium/large]
2. [Feature] — [why it's next] — [estimated complexity: small/medium/large]

## Session Notes

Any context that would be useful for the next session that doesn't fit above:

- Architecture decisions made and rationale
- Patterns established that should be followed
- External dependencies or environment setup changes
- Gotchas discovered
```
