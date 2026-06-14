---
description: "Dual QA review over a commit-range scope — the evaluator and reviewer run concurrently; returns both reports plus the combined summary. Use after completing a feature or before handoff, when both calibrated reviewers should run at once. Scope via arguments (e.g. \"last 3 commits\"); default is work since the last handoff."
---

# Evaluate (Parallel) — Workflow Launcher

Launch the harness's saved dual-review workflow. The orchestration lives in the
plugin-shipped script; this skill only starts it and handles the result.

## Step 1 — Launch

Invoke the **Workflow** tool with:

- `scriptPath`: `${CLAUDE_PLUGIN_ROOT}/workflows/eval-parallel.js`
- `args`: the scope, passed through verbatim from the user's arguments —
  `"$ARGUMENTS"` if non-empty, otherwise omit `args` entirely (the script
  defaults to everything since the last session handoff).

The run executes in the background: the Scope stage resolves the commit range,
then both calibrated reviewers — `guv:evaluator` and `guv:reviewer`,
spawned by name per the workflow-verification rule (plugin agents resolve only
under the namespaced form) — review concurrently.

## Step 2 — Report

When the result notification arrives, read the full result (the inline
notification truncates long reports — pull the result JSON from the task output
if needed) and present to the user:

1. The evaluator's full report, verdict, and weighted score
2. The product reviewer's full report, verdict, and weighted score
3. The combined summary the script computed

Do not soften either report.

## Step 3 — Fix loop (conversational, NOT in the workflow)

The fix loop deliberately stays in the main session: workflow subagents run in
`acceptEdits` mode, which conflicts with the sequential fix-and-re-evaluate
gate. If either reviewer found Critical or Major issues, apply fixes here in
conversation, then re-run this skill for the next pass.
