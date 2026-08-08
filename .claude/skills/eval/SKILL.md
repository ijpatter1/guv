---
name: eval
description: "Run the review gate on recent work: the session-invoked platform review plus the alignment reviewer. Findings are graded — fix what changes a decision, record the rest. Two rounds maximum."
user-invocable: true
---

# Review Gate

Review recent work through two instruments: the platform's `/code-review` for
technical findings, and the `reviewer` subagent for alignment with the spec and
vision. Findings, not scores. ([32.1]; S2/S3, spec-2026-07-31.)

## When to Use

- At a change's commit gate (the `/task` paths invoke this)
- When the user asks for a review, gut-check, or quality assessment

## Input

$ARGUMENTS

If arguments are provided, they scope the gate (e.g. "the last 3 commits", "the
working diff"). Default: the working diff plus any commits since the last gate.

## Step 1 — Scope

```bash
bash .claude/guv-git.sh log --oneline -10   # recent commits (roots.code)
bash .claude/guv-git.sh diff HEAD~N          # the diff under review
grep -m1 "Current Phase" docs/PHASE_STATUS.md 2>/dev/null || echo "Phase unknown"
```

Name the commits, files, and deliverable(s) in scope before invoking anything.

## Step 2 — Technical review: the platform gate

The session fires the platform review itself: invoke the `code-review` skill with
an **explicit target** and an **explicit effort level** — never bare. The target is
the `roots.code` path from the manifest (the skill derives the repo from the path
and scopes there; pass a file path to narrow further). The level is `low` or
`medium` for a routine gate — fewer, high-confidence findings; with no level the
skill reuses whatever was typed last, which is how a routine gate inherits an
audit-sized fleet. Verified findings return in-session. Operator-typed
`/code-review` at high or ultra is the **audit posture** — a person deliberately
spending a large fleet; it is not the routine gate. PR-shaped work passes the
PR number as the target; `security-review` and `simplify` are available for
targeted passes. If the platform skill is unavailable to the session, the
technical pass is **skipped and disclosed** in the record — never silently.

## Step 3 — Alignment review

Invoke the `reviewer` subagent **by name**, worktree-isolated, with a prompt like:

"Review the following work from Phase [N] for alignment. Commits: [list]. Changed
files: [list]. Grade alignment against docs/REQUIREMENTS.md, the governing spec,
and any content guides in CLAUDE.md. Report findings with severity and evidence —
no scores."

Present the report without modification or softening.

## Step 4 — Grade and disposition

A finding is evidence; severity is the session's judgment (Rule 3). For each
finding, one of two dispositions:

- **Fix now** — it changes a decision: a defect in the change that alters its
  behavior, acceptance, or a consumer's correctness.
- **Record** — real but not decision-changing, or outside the change under review:
  it lands in the handoff's **Issues & Technical Debt** with its severity,
  reviewer, and provenance. Recorded-as-debt is a first-class outcome, not a
  failure.

**Provenance split:** a **Critical in the change under review** stops the gate — fix
it before the change lands. A **Critical in surrounding code** the review happened
to walk is disclosed and recorded — never a blocker on a change that did not cause
it.

## Step 5 — The cap

**Two rounds maximum.** One fix pass over the graded fix-now findings, one re-check
of exactly those fixes (graded against the prior findings, not a fresh review). At
the cap with findings still open, put the three-way call to the person — **converge
/ cut scope / accept as debt** — instead of opening another round. Unanswered or
headless takes the **stop**, recorded in the handoff. Watch round sizes: a growing
round is divergence, not progress.

## Notes

- The `reviewer` is read-only by tool grant and worktree isolation; it reports, it
  never edits. Its project memory persists across sessions.
- Recurring mechanical patterns graduate to tests; judgment patterns persist in the
  reviewer's memory.
- Do not editorialize or soften findings. The user needs honest assessment.
