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

Any issues identified (by you or either reviewer) that weren't resolved this session:

- Issue description
- Severity (critical / important / minor)
- Source (evaluator / product reviewer / self-identified)
- Where it lives in the code

## Evaluator Results

Summary of the evaluator's technical assessment:

- Weighted score: X.X/5.0
- Verdict: PASS / PASS WITH ISSUES / FAIL
- Critical issues (if any): [list]
- Unresolved important issues: [list]

## Product Review Results

Summary of the product reviewer's assessment:

- Weighted score: X.X/5.0
- Verdict: PASS / NEEDS WORK
- Vision alignment: [score]/5
- User experience: [score]/5
- Content quality: [score]/5
- Feature depth: [score]/5
- Issues (if any): [list]

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
