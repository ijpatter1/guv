---
name: handoff
description: "End the current work session by running QA evaluation, generating a structured handoff artifact, and updating the phase tracker."
user-invocable: true
---


## Steps 1–2 — Session-Close Review (run `/eval`)

The session-close review **is** `/eval` — the dual QA review (technical
`evaluator` + `reviewer`) defined once in the `/eval` skill
(`.claude/skills/eval/SKILL.md`). **Do not restate its procedure here.** Run
that one definition — its Steps 1–4 gather context, invoke both reviewers, and
emit the combined summary; the saved `/eval-parallel` workflow runs the same
Steps 1–4 with the two reviewers concurrent. Handoff owns only what is specific to
session-close: the **skip condition**, the **review target**, and the **verdict
gates** below — never a second copy of how the reviewers are invoked. (When the
restatement and its source were two copies, they drifted; the pointer is the fix.)

### Skip condition — review cost is paid once

Skip this session-close review **only when every commit in the session was already
dual-reviewed in-band** — i.e. each was carried through `/task` (or an equivalent
scoped flow) whose Step 3 ran `/eval` (both reviewers) on the change before it
was committed. In that case the duplicate session-close review buys nothing, so
skip it — and **disclose the skip**: record in the handoff artifact, under
**Evaluator Results** / **Product Review Results**, that the session-close review
was skipped because all session commits were dual-reviewed in-band, naming the
in-band pass(es). The skip is **never silent** — a skipped review is always
disclosed in the record.

The skip is **conditional**. If **any** session commit was *not* dual-reviewed
in-band (a hand commit, a commit landed outside `/task`/`/eval`, or any commit
you cannot account to an in-band pass), the skip does not apply — **run the review
below** over the session scope. When in doubt, do not skip: run it. No review is
ever dropped silently; either it runs, or its skip is disclosed with the reason.

### Review target

`/eval` scopes to the code repo (`roots.code`); handoff must first decide
**which repo's commits to review**, because a pre-scaffold session has no code
history yet (`git -C roots.code log` would error or be empty), and a docs-only
session in a control-plane split — at any point in the project's life — made no
code commits *this session* even though the code repo has history. Pick the target:

```
CODE=$(jq -r '.roots.code' .claude/project.json)
CONTROL=$(jq -r '.roots.control' .claude/project.json)
# Use the code repo only if it's scaffolded AND a git repo with commits; else the control plane.
if sh -c "$(jq -r '.scaffoldCheck' .claude/project.json)" 2>/dev/null \
   && git -C "$CODE" rev-parse --verify HEAD >/dev/null 2>&1; then
  TARGET="$CODE"   # review product commits
else
  TARGET="$CONTROL"   # pre-scaffold / docs-only: review control-plane session commits
fi
```

The snippet answers "does the code repo have *any* history", not "did *this session*
commit there" — so after it, check: if `TARGET` is the code repo but this session
produced no commits in it (docs-only session in a mature split), switch `TARGET` to
the control plane and review the session's actual commits. If `TARGET` is the
control plane, tell `/eval` it is reviewing control-plane / doc work — a
pre-scaffold session, or a docs-only session in a mature split — not product code,
so the reviewers judge accordingly rather than reporting "no tests" against
documentation. Pass `/eval` this session's scope (the commits in `$TARGET` and
the phase number from `docs/PHASE_STATUS.md`, skipped if absent — non-phased).
Present both reviewers' full reports to the user without modification or softening,
exactly as `/eval` does.

> For a pre-scaffold session — or, in a control-plane split, any session whose
> commits live only in the control plane — prefer the conversational `/eval`
> over `/eval-parallel`: the workflow's default scope targets the code repo and
> will (loudly) find no commits there. (Single-repo projects are unaffected:
> `roots.code` is `.`, so every commit is in scope.)

### Verdict gates (handoff-specific)

These gates are what `/handoff` adds on top of `/eval`'s reports — they decide
whether the handoff proceeds:

- **Evaluator FAIL:** Stop the handoff here. Fix the critical issues, then invoke `/handoff` again from the top (the evaluator re-runs on the fixed code).
- **Product reviewer NEEDS WORK with Critical issues:** Stop the handoff. Address the critical product issues, then invoke `/handoff` again.
- **PASS WITH ISSUES / NEEDS WORK with Major/Minor only:** Note the issues but continue. They are captured in the handoff artifact.
- **Both PASS:** Continue with Step 3.

## Step 3 — Final Test Run

Run the full test suite to confirm the codebase is in a clean state, via the
manifest-command helper. Time the run and write the measured wall-clock to the
metering artifact mechanically — this single number is the **only** mechanical
source for `perf.suite_runtime_s` in Step 6b's metering entry (the writer reads
the artifact; no agent ever types the runtime):

```bash
mkdir -p .claude/metering
S=$(date +%s.%N 2>/dev/null); case "$S" in *N|"") S=$(date +%s);; esac
bash .claude/guv-cmd.sh test
E=$(date +%s.%N 2>/dev/null); case "$E" in *N|"") E=$(date +%s);; esac
awk -v a="$S" -v b="$E" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f\n", d }' \
  > .claude/metering/.last-suite-runtime
```

The `awk` writes the *measured* elapsed seconds — not a number you supply. If the
suite step is null-skipped, the artifact still records the (near-zero) elapsed
wrapper time; Step 6b reads whatever guv measured, or `null` if the
artifact is absent.

A `[guv-cmd] commands.test is null — skipping` line means the project has no test step — note that and skip this step cleanly. If any tests are failing, note them explicitly in the handoff. Do not leave the session with unexplained test failures.

## Step 4 — Commit Any Uncommitted Work

Check for uncommitted changes in both repos (the same path for single-repo, where `roots.code` is `"."`):

```
bash .claude/guv-git.sh status                                   # product changes
git -C "$(jq -r '.roots.control' .claude/project.json)" status   # doc/session changes
```

If there are uncommitted changes, commit them with an appropriate conventional commit message — **product code commits land in the code repo, doc/session artifacts in the control plane** (these are two commit streams when the roots differ, one when they coincide). If there are changes that are intentionally uncommitted (work in progress, experimental code), note this in the handoff artifact.

## Step 5 — Review Session Work

Review what was accomplished this session. Use a reasonable number of recent commits from the code repo:

```
bash .claude/guv-git.sh log --oneline -15
```

Scan the output and identify which commits belong to this session (based on timestamps and commit messages). If the session spans more than 15 commits, increase the count.

## Step 6 — Generate Handoff Artifact

Determine the next session number by checking existing files in `docs/sessions/`. Create the handoff artifact at:

```
docs/sessions/session-YYYY-MM-DD-NNN.md
```

Where YYYY-MM-DD is today's date and NNN is a zero-padded sequence number (001, 002, etc.) for the day.

The handoff artifact must contain:

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

## Step 6b — Append the Metering Entry

The session-close path appends one raw-evidence line to the append-only metering
log ([9.1]). Run this **after** Step 6 so the session id is derivable from the
artifact you just wrote, and after Step 3 so the suite runtime exists:

```bash
bash .claude/meter.sh capture --deliverables "<id>[,<id>...]"
```

Pass the deliverable ID(s) this session served — comma-separated for several.
For a session with no single applicable ID (docs sweep, planning, multi-area
work), omit `--deliverables` entirely and the writer records `session-scalar`.
**Report no numbers to the writer:** token counts, dollars, the operation
wall-clock, and the suite runtime are harvested, measured, or read from a guv
artifact by the writer itself, never agent-supplied (the "measure exhaust, never
steam — no agent I/O" contract). There is no `--suite-runtime` flag — the writer
READS the suite runtime from `.claude/metering/.last-suite-runtime`, the artifact
Step 3 wrote when it timed the suite (absent/unreadable → `suite_runtime_s: null`).
The writer derives the session id, harvests tokens from the runtime transcript
where Spike C's rung permits (degrading to `tokens: null` if the transcript is
unreachable — the log never blocks on harvestability), measures its own
deterministic-op wall-clock, reads the suite-runtime artifact, and appends the
line. The log is append-only; nothing here rewrites it. The emitted shape is
documented in `.claude/metering-log.md`.

**If the writer emits a `BALLOON:` line** (a [13.6] balloon: the deliverable's slice
spanned more compaction cycles than its [13.2] sizing — a fuzzy deliverable-budget
breach), record it in the handoff artifact under **Issues & Technical Debt** (or
**Session Notes**), verbatim. Like the budget-gate breach in Step 6c, a balloon is a
human signal — it must reach the *written* record a person reads later, not only the
live session output. A balloon never stops the handoff (exit 0); it is declared, not
gated.

## Step 6c — Run the Budget Gate at the Exit Boundary

The [9.3] tension gate runs at the session **exit** boundary — the second of the
two boundaries the gate rides (the SessionStart hook fires it at entry). Run it
**after** Step 6b so it compares the just-appended burn against the chosen budget:

```bash
bash .claude/budget-gate.sh exit
```

The gate is the **tension gate**: it sums burn from the metering log and, *on
tension only*, raises a loud decision gate (exit 3) naming the breach, the burn
profile, and the person's choices — **extend / harvest / kill**. Within budget,
or with no budget set (absent means unlimited), it is **silent** — no banner, no
recap — and exits 0. If it raises, **do not paper over it**: surface the breach
verbatim in the handoff (under **Blocked**, naming the budget crossed) and stop
for the person's decision. The machinery never raises a setpoint; raising the
ceiling is a human commit to `budgets.{initiative,session}.tokens` in
`project.json` (the commit is the provenance — no approval flow, no side channel).

**If the gate emits a `[budget-gate] FORESEEN OVERRUN` line** (a [13.5] foreseen
overrun: burn-to-date plus the projection's cost-to-complete is forecast to exceed the
initiative budget — exit **0**, not a stop), record it in the handoff artifact under
**Issues & Technical Debt** (or **Blocked**), verbatim. Like the [13.6] balloon in
Step 6b, a foreseen overrun is a **declaration, not a hard stop** — a deliverable
budget is fuzzy (the projection is a range), so the gate does **not** pause for it;
it is a human signal for the **extend / harvest / re-plan** call at this boundary. It
must reach the *written* record a person reads later, not only the live output. Do
not stop the handoff for it (it exited 0); do surface it. (The header leads with
`FORESEEN OVERRUN`, distinct from the actual-burn `[budget-gate] BREACH` stop in this
step above — a skim tells the signal from the exit-3 pause; [15.6].)

## Step 7 — Update Phase Status

**Phased projects only.** Read `ceremony` from `.claude/project.json`. If it is not
`phased` (or there is no `docs/PHASE_STATUS.md`), there is no phase tracker — skip
this step cleanly and skip Step 8 as well. A missing phase tracker is a mode signal,
not an error. In that case the handoff artifact's **Phase** field is just "N/A
(`<ceremony>` mode)".

Otherwise update `docs/PHASE_STATUS.md` to reflect the current state of the phase:

- Mark completed deliverables
- Update any progress notes
- Adjust estimates if the work revealed unexpected complexity

## Step 8 — Phase Completion: Generate UAT Plan

**Phased projects only — and conditional within them.** If `ceremony` is not
`phased`, skip this step entirely. Otherwise check if all deliverables for the current phase are now ✅ in `docs/PHASE_STATUS.md`. If any deliverables are still ⬜, 🔄, ❌, or 🔒, skip to Step 9.

The 🔒 marker is **human-gated / awaiting-manual** — a deliverable blocked on
out-of-sandbox human or manual work (the kind `/manual` writes to
`docs/manual/`), not on a dependency. When you tally markers (phase-completion
here, and the progress count in Step 11), count 🔒 as its **own** category:
it is open work, so a 🔒 item keeps the phase incomplete, but it is **not** ❌
blocked (no dep gates it — a person does) and **not** ✅ complete. Report it
distinctly — "N human-gated (awaiting `docs/manual/`)" — under **Blocked** in
the handoff artifact with the manual artifact named, never silently folded into
the dependency-blocked count.

If the phase is complete, **first bank the phase-boundary forecast** ([13.4]) — a
gradeable mid-initiative projection of the cost to complete the rest of the
initiative, made at this phase boundary with the landings so far folded into the
blend:

```bash
bash .claude/projection.sh bank --at phase-<N>
```

Substitute the completed phase number for `<N>` (e.g. `--at phase-9`). Idempotent —
re-running the handoff for this same completed phase does not double-bank. The entry
joins the forecast lineage the initiative-close grade reads; no manual `bank` call is
needed, here or anywhere in the lifecycle.

Then generate a user acceptance testing plan. The UAT plan verifies that the phase's deliverables work end-to-end as a user would experience them — not unit test coverage (the evaluator handles that) or spec alignment (the product reviewer handles that), but real-world workflows from start to finish.

### Generating the UAT Plan

Invoke the `reviewer` subagent with a prompt like: "Phase [N] is dev complete. All deliverables have passed technical evaluation and product review. Generate end-to-end user acceptance scenarios that test the phase's deliverables as a user would experience them. Reference docs/REQUIREMENTS.md for the deliverables, docs/ARCHITECTURE.md for the technical design, and any content guides or specs referenced in CLAUDE.md. Focus on realistic workflows, not individual feature checks — each scenario should exercise multiple deliverables working together."

Use the product reviewer's scenarios to produce the UAT artifact. **Follow the same automation-first hierarchy as `/manual`:**

1. **If the project is a CLI tool or backend service:** Produce a UAT script at `docs/uat/phase-N-uat.sh`. The script should set up prerequisites, run each scenario, pause for human observation where visual verification is needed, collect pass/fail results, and print a summary. Use the same `verify()` pattern from the `/manual` script template for automated checks. For steps requiring human judgment, use a `confirm()` helper:

```bash
PASS=0; FAIL=0; SKIP=0   # the skip path below increments SKIP — declare it with PASS/FAIL or `set -u` aborts the gate

confirm() {
  echo ""
  echo "  → $1"
  # Human-judgment gate: never auto-pass without a human. With no interactive
  # terminal (no TTY) — or when an explicit non-interactive flag is set — there
  # is no one to answer, so a `read` at EOF would fall through to the pass branch
  # (guv's own vacuous-guard lesson). Guard it: SKIP, never ✓ pass.
  if [ ! -t 0 ] || [ -n "${GUV_NON_INTERACTIVE:-}" ] || [ -n "${CI:-}" ]; then
    echo "  ⊘ SKIPPED (non-interactive — no human to judge): $2"; ((SKIP++))
    return
  fi
  read -p "  Pass? [Y/n] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  ✗ $2"; ((FAIL++))
  else
    echo "  ✓ $2"; ((PASS++))
  fi
}

# Example usage:
confirm "Does the dashboard show campaign data for all 3 channels?" \
  "Dashboard displays multi-channel data"
```

The human-judgment gate **skips** under no TTY (or `GUV_NON_INTERACTIVE` / `CI`)
rather than auto-passing — a non-interactive run reports each human gate SKIPPED,
never ✓ passed. Track skips in a `SKIP=0` counter alongside `PASS`/`FAIL` and fold
them into the results summary (e.g. `Results: $PASS passed, $FAIL failed, $SKIP
skipped`); a run with any SKIPPED human gate is **not** a clean pass — the human
judgment is owed, not waived. The mechanical `verify()` checks read no human input
and are unaffected by this guard.

2. **If the project is a web UI:** Produce a UAT script that automates setup and verification where possible, and uses `confirm()` prompts for visual/interactive checks. Include `open` commands to launch the relevant pages. Structure the script as a guided walkthrough — the human follows along while the script manages state and collects results.

3. **If the project is purely manual to test:** Produce a UAT task card at `docs/uat/phase-N-uat.md` with numbered scenarios, each containing steps, expected outcomes, and pass/fail checkboxes. This is the last resort.

### UAT Artifact Structure

Whether script or card, each UAT plan should cover:

- **Prerequisites** — what must be running, configured, or seeded before testing
- **Scenarios** — numbered end-to-end workflows, each testing multiple deliverables together. Each scenario has:
  - A name and description of what it validates
  - Steps (automated where possible, guided where not)
  - Expected outcomes with concrete checks
  - Which deliverables it exercises
- **Edge cases** — at least 2-3 scenarios that test boundaries, error states, or non-obvious flows
- **Results summary** — pass/fail counts with a clear overall verdict

### After Generating UAT

Make the script executable if applicable:

```bash
chmod +x docs/uat/phase-N-uat.sh
```

Note in the handoff artifact under **Next Steps** that UAT is ready to run:

```
1. Run Phase N UAT: `bash docs/uat/phase-N-uat.sh`
2. [Next phase planning — if UAT passes]
```

The phase is not considered accepted until UAT passes. The next session's `/phase` should check for UAT results before starting new phase work.

## Step 9 — CLAUDE.md / Manifest Freshness Check

The live `CLAUDE.md` is the lean file rendered from `CLAUDE.template.md`: it holds only
the "Project facts Claude can't infer" and points at `.claude/project.json` for commands
and `.claude/rules/` for behavior (loaded natively). Keep it lean — facts that belong in
the manifest or the rules go there, **not** into `CLAUDE.md`. Check for drift in the right place:

- **Command drift → the manifest, not CLAUDE.md.** Did the test/build/lint/format/dev
  command change, or a new step get added? Update `.claude/project.json`. `CLAUDE.md`
  never restates commands, so there is nothing to update there.
- **Stack / package-manager change → the manifest.** Update `language` /
  `packageManager` (and the sandbox base image / firewall registries follow from it).
- **New can't-infer facts → CLAUDE.md's "Project facts" section.** A required env var,
  a non-obvious gotcha, a project-specific architectural decision, repo etiquette — only
  if it passes the pruning test (_would removing it cause a mistake?_).
- **Phase progression (phased only):** if a phase was completed, does the identity/intro
  need to reflect it? (Phase state itself lives in `docs/PHASE_STATUS.md`, not CLAUDE.md.)
- **Stale bootstrapping section:** once the project is scaffolded, remove the
  "Bootstrapping" section from `CLAUDE.md` — it only applies to the first session.

If any updates are needed, **propose them to the user** as a list, routing each to the
right file:

```
Freshness updates needed:
1. .claude/project.json: commands.test → "vitest run" (was "npm test")
2. .claude/project.json: packageManager → "pnpm"
3. CLAUDE.md (Project facts): add "RESEND_API_KEY required or email send no-ops in dev"
4. CLAUDE.md: remove the now-stale Bootstrapping section
```

**In interactive mode:** Wait for approval before making the changes.
**In headless/bypass mode:** Apply the changes and note them in the handoff artifact under Session Notes.

If no updates are needed, skip this step silently — do not announce "CLAUDE.md is up to date."

### README status block — maintained by the render hooks (no hand-invoke)

No hand-invoke at session close: in `phased` projects the README status block is
refreshed **automatically** by the §3.3 render hooks. The control plane's git
post-commit hook regenerates it on every tracker commit — including the tracker
commit Step 7 just made — deriving the line from the resolver (`status-line.sh`),
and the native PostToolUse hook covers a direct tracker edit. **Never edit between
the `<!-- STATUS:START/END -->` markers by hand** — the block is a view of
`docs/PHASE_STATUS.md`, not a second source of truth. (In `task`/`onboard` mode
there is no tracker to derive from, and a consumer README normally carries no
markers, so there is nothing to refresh.)

## Step 10 — guv Feedback

This is about **guv**, not the product. Reflect on the session: did any
command, hook, skill, setting, manifest field, or doc not fit the work — error out,
not apply, mislead, or force a workaround? If so, capture each via the `feedback`
skill (it appends to `.claude/feedback/feedback.ndjson`; data only, never blocking).
Logging friction _as it is hit_ mid-session is better, but handoff is the backstop so
nothing is lost.

Then surface what's outstanding so the log doesn't rot — count open entries, and
list them so you can drain:

```
f=.claude/feedback/feedback.ndjson
[ -f "$f" ] && jq -s '[.[] | select(.status=="open")] | length' "$f" || echo 0
[ -f "$f" ] && jq -r 'select(.status=="open") | "\(.id)\t\(.routing)\t\(.summary)"' "$f"
```

**Drain, don't just count — close the loop for what this session resolved.** The log
only stays useful if entries close when their friction is gone; the surface step alone
lets fixes pile up `open` forever (acute in a dogfooding control plane, which consumes
guv via `--sync` and so never hits the release-keyed drain). Review the open
entries against this session's work, and for each whose fix **landed in the guv
source this session** — or is already live in-plane via `--sync`, or whose friction is
otherwise resolved — **propose graduating** it, naming the resolving deliverable or
commit:

- **Interactive:** present the proposed graduations and wait for the user's confirm.
- **Headless/bypass:** apply them and note each under **Completed** in the handoff.

Apply via the `feedback` skill's triage command — flip `status` to `graduated`
(or `resolved`/`wontfix`) and append a provenance note to `detail` naming what
resolved it. This is the agent-executable close trigger the sync/dogfooding model
needs (see the skill's *Closing the loop*). Don't force it: an entry whose fix has
**not** landed stays `open` — graduate only what's genuinely resolved.

Whatever stays open after the drain: note the count in the handoff artifact under
**Issues & Technical Debt** (e.g. "3 open guv-feedback entries — triage with the
`feedback` skill"), so the next session sees it. If 0, say nothing.

## Step 11 — Summary

After writing the handoff artifact and updating the phase status, present a brief summary:

- What was accomplished this session (1-3 sentences)
- Current overall phase progress (e.g., "Phase 1: 6 of 9 deliverables complete")
- If UAT was generated: "Phase N UAT plan ready at `docs/uat/phase-N-uat.sh` — run before starting Phase N+1"
- Any open guv-feedback count (from Step 10), if > 0
- The recommended starting point for the next session
