---
name: handoff
description: "End the current work session by running QA evaluation, generating a structured handoff artifact, and updating the phase tracker."
user-invocable: true
---


## Steps 1–2 — Session-Close Review (run `/guv:eval`)

The session-close review **is** `/guv:eval` — the dual QA review (technical
`evaluator` + `reviewer`) defined once in the `/guv:eval` skill
(plugin-shipped). **Do not restate its procedure here.** Run
that one definition — its Steps 1–4 gather context, invoke both reviewers, and
emit the combined summary; the `/guv:eval-parallel` skill runs the same
Steps 1–4 with the two reviewers concurrent. Handoff owns only what is specific to
session-close: the **skip condition**, the **review target**, and the **verdict
gates** below — never a second copy of how the reviewers are invoked (two copies
drift; the pointer is the fix).

### Skip condition — review cost is paid once

Skip this session-close review **only when every commit in the session was already
dual-reviewed in-band** — i.e. each was carried through `/guv:task` (or an equivalent
scoped flow) whose Step 3 ran `/guv:eval` (both reviewers) on the change before it
was committed. In that case the duplicate session-close review buys nothing, so
skip it — and **disclose the skip**: record in the handoff artifact, under
**Evaluator Results** / **Product Review Results**, that the session-close review
was skipped because all session commits were dual-reviewed in-band, naming the
in-band pass(es). The skip is **never silent** — a skipped review is always
disclosed in the record.

The skip is **conditional**. If **any** session commit was *not* dual-reviewed
in-band (a hand commit, a commit landed outside `/guv:task`/`/guv:eval`, or any commit
you cannot account to an in-band pass), the skip does not apply — **run the review
below** over the session scope. When in doubt, do not skip: run it. No review is
ever dropped silently; either it runs, or its skip is disclosed with the reason.

### Review target

`/guv:eval` scopes to the code repo (`roots.code`); handoff must first decide
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

The snippet answers "does the code repo have *any* history", not "did *this
session* commit there" — so after it: if `TARGET` is the code repo but this session
made no commits in it (a docs-only session in a mature split), switch `TARGET` to
the control plane. When `TARGET` is the control plane, tell `/guv:eval` it is reviewing
control-plane / doc work — pre-scaffold or docs-only — not product code, so the
reviewers judge accordingly rather than reporting "no tests" against documentation.
Pass `/guv:eval` this session's scope: the commits in `$TARGET` and the phase number
from `docs/PHASE_STATUS.md` (skipped if absent — non-phased). Present both
reviewers' full reports to the user without modification or softening, exactly as
`/guv:eval` does.

> For a pre-scaffold session — or, in a control-plane split, any session whose
> commits live only in the control plane — prefer the conversational `/guv:eval`
> over `/guv:eval-parallel`: the workflow's default scope targets the code repo and
> will (loudly) find no commits there. (Single-repo projects are unaffected:
> `roots.code` is `.`, so every commit is in scope.)

### Verdict gates (handoff-specific)

These gates are what `/guv:handoff` adds on top of `/guv:eval`'s reports — they decide
whether the handoff proceeds:

- **Evaluator FAIL:** Stop the handoff here. Fix the critical issues, then invoke `/guv:handoff` again from the top (the evaluator re-runs on the fixed code).
- **Product reviewer NEEDS WORK with Critical issues:** Stop the handoff. Address the critical product issues, then invoke `/guv:handoff` again.
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
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-cmd.sh test
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
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh status                                   # product changes
git -C "$(jq -r '.roots.control' .claude/project.json)" status   # doc/session changes
```

If there are uncommitted changes, commit them with an appropriate conventional commit message — **product code commits land in the code repo, doc/session artifacts in the control plane** (these are two commit streams when the roots differ, one when they coincide). If there are changes that are intentionally uncommitted (work in progress, experimental code), note this in the handoff artifact.

## Step 5 — Review Session Work

Review what was accomplished this session. Use a reasonable number of recent commits from the code repo:

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh log --oneline -15
```

Scan the output and identify which commits belong to this session (based on timestamps and commit messages). If the session spans more than 15 commits, increase the count.

## Step 6 — Generate Handoff Artifact

Determine the next session number by checking existing files in `docs/sessions/`. Create the handoff artifact at:

```
docs/sessions/session-YYYY-MM-DD-NNN.md
```

Where YYYY-MM-DD is today's date and NNN is a zero-padded sequence number (001, 002, etc.) for the day.

**Read the fill-in skeleton from `handoff-artifact.md` in this skill's directory**,
then write the artifact with every section it specifies — the section set is the
contract, drop none: **Completed This Session**, **In Progress**, **Blocked**,
**Issues & Technical Debt**, **Evaluator Results**, **Product Review Results**,
**Test State**, **Build State**, **Next Steps**, **Session Notes**. (The skeleton
lives in a sibling file so this procedure stays short enough to remain resident —
the cold read found the all-in-one skill truncated mid-procedure.)

## Step 6b — Append the Metering Entry

The session-close path appends one raw-evidence line to the append-only metering
log ([9.1]). Run this **after** Step 6 so the session id is derivable from the
artifact you just wrote, and after Step 3 so the suite runtime exists:

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/meter.sh capture --deliverables "<id>[,<id>...]"
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
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/budget-gate.sh exit
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

**Every other `[budget-gate]` headline is captured the same way.** The gate's exit
comment names this reader by name — "a person at the extend/harvest/kill decision,
**writing the handoff that carries it forward**" — so a declaration that reaches only
the live session output has not reached the record it was written for. Capture each of
these verbatim under **Issues & Technical Debt** (or **Blocked**), exactly as above:

- `HARVEST UNIT HAZARD` — the burn and the ceiling are not in the same harvest unit, so
  the comparison is invalid. Carry the `hazard:` kind (`mixed` — the window spans both
  units; `mismatch` — the window is uniformly one and the setpoint declares the other;
  `malformed` — `budgets.initiative.harvest_basis` is not a harvest unit, so the
  setpoint-unit check is silently OFF), and carry the **direction** it names (phantom
  breach / phantom headroom / undetermined): the remedy differs by direction, and under
  phantom breach the designed rung is to WAIT rather than move anything.
- `SETPOINT DENOMINATION HAZARD` — the ceiling was declared `cost_weighted` while burn is
  summed as a raw four-class token count. The ceiling is the **smaller** side, so the burn
  **overstates** against it and the gate stops **early**: a phantom breach, the
  conservative direction — do not record the gap as work that was spent. Carry that
  direction, and carry the note that **WAIT is not a rung here** (unlike a vintage phantom
  breach, this one never decays — burn is raw by construction). A separate axis from the
  harvest unit above, and both can fire at once; when they do the banner names both
  headlines and the two directions **oppose** each other, so record both and claim no net
  direction. The `hazard:` field carries both axes' states. The remedy is a person's commit
  (re-denominate `budgets.initiative.tokens`, or correct `budgets.initiative.denomination`);
  the gate discloses the gap and never converts, because the ratio moves with session shape.
- `TORN METERING LINES` — one or more log lines did not parse and were skipped, so every
  burn figure in this handoff is a **floor**, not a measurement. Record the count.

None of these stops the handoff (all exit 0). All of them qualify the burn and forecast
figures recorded elsewhere in the artifact, so a handoff that copies the numbers without
the banner that qualifies them records a measurement the gate explicitly refused to call
one. **Do not paraphrase or summarize a banner** — the wording carries the direction and
the remedy, and both are what the next reader acts on.

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

**Defer to the engine's completion notion for a lone-deliverable phase ([15.7]).**
This phase-completion check is a sibling of the engine's `phase_completed`
(`"${CLAUDE_PLUGIN_ROOT}"/scripts/replan.sh`) and `archive-initiative.sh` — all three must agree.
Where the current phase holds a **single** deliverable, "all ✅" is **not**
enough: a lone-deliverable phase whose one deliverable is ✅/❌ is the
**spike-gated** shape mid-grooming (a lone gating spike flipped ✅ before its
gated build set is groomed in), and the engine treats it as **open until
SEALED** — sealed by an explicit `phase-close` record. So a lone-✅ phase counts
as phase-complete here **only once it carries that seal**
(`> - DATE — phase-close [N] (session)` in the tracker header). If the current
phase is lone-deliverable, all-done, but **not** sealed, do **not** bank the
forecast or generate UAT — instead **prompt to seal it first**
(`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/replan.sh phase-close <session> <phase>`), then proceed once
sealed. The **multi-deliverable** path is unchanged: ≥2 deliverables, all ✅/❌,
is phase-complete exactly as before (those auto-tally — there is no manual seal).

The 🔒 marker is **human-gated / awaiting-manual** — a deliverable blocked on
out-of-sandbox human or manual work (the kind `/guv:manual` writes to
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
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/projection.sh bank --at phase-<N>
```

Substitute the completed phase number for `<N>` (e.g. `--at phase-9`). Idempotent —
re-running the handoff for this same completed phase does not double-bank. The entry
joins the forecast lineage the initiative-close grade reads; no manual `bank` call is
needed, here or anywhere in the lifecycle.

Then generate a user acceptance testing plan. The UAT plan verifies that the phase's deliverables work end-to-end as a user would experience them — not unit test coverage (the evaluator handles that) or spec alignment (the product reviewer handles that), but real-world workflows from start to finish.

### Generating the UAT Plan

Invoke the `guv:reviewer` subagent with a prompt like: "Phase [N] is dev complete. All deliverables have passed technical evaluation and product review. Generate end-to-end user acceptance scenarios that test the phase's deliverables as a user would experience them. Reference docs/REQUIREMENTS.md for the deliverables, docs/ARCHITECTURE.md for the technical design, and any content guides or specs referenced in CLAUDE.md. Focus on realistic workflows, not individual feature checks — each scenario should exercise multiple deliverables working together."

Use the reviewer's scenarios to produce the artifact. Then **vet it via the
`evaluator`** ([18.2]) — by name (Rule 14), and **independent of the `reviewer`** that
generated it: the agent that wrote the scenarios never grades its own work. The vet is
**declared-not-gated** (the exit-0 rung — a NEEDS WORK verdict never blocks the handoff),
and its verdict is both recorded in this handoff and stamped on the artifact; a review
that can't run degrades to UNVETTED, never a silent pass. **The full UAT plan structure
— the automation-first script/card hierarchy, the required artifact sections, the vet
mechanics, and the after-generating steps — is in `uat-plan.md` in this skill's directory;
read it when you generate the plan.** One rule is inlined here because every generated UAT
(and `/guv:manual`) script inherits it — the human-judgment gate:

### The human-judgment gate (`confirm()`)

A generated UAT/manual script uses `confirm()` for any "did this look right?" check a
human must answer, and the `verify()` pattern (from `/guv:manual`) for mechanical ones.
`confirm()` **skips** — never auto-passes — when there is no TTY or a non-interactive
flag is set, so an unattended run reports the gate SKIPPED rather than vacuously ✓:

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
    echo "  ⊘ SKIPPED (non-interactive — no human to judge): $2"; SKIP=$((SKIP+1))
    return
  fi
  read -p "  Pass? [Y/n] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  ✗ $2"; FAIL=$((FAIL+1))
  else
    echo "  ✓ $2"; PASS=$((PASS+1))
  fi
}

# Example usage:
confirm "Does the dashboard show campaign data for all 3 channels?" \
  "Dashboard displays multi-channel data"
```

Track skips in a `SKIP=0` counter alongside `PASS`/`FAIL` and fold them into the
results summary (e.g. `Results: $PASS passed, $FAIL failed, $SKIP skipped`); a run
with any SKIPPED human gate is **not** a clean pass — the judgment is owed, not
waived. The mechanical `verify()` checks read no human input and are unaffected.

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
- **Stale bootstrapping section — deterministic, not a proposal.** The rendered
  `CLAUDE.md` carries a first-session-only "Bootstrapping" section that goes stale
  once the project is scaffolded. Don't hand-edit it or add it to the proposal list
  below — run `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/strip-bootstrap.sh`. The helper removes the section only
  once `scaffoldCheck` passes (a no-op before scaffold, and idempotent once it's
  gone), so it self-removes at the first handoff past scaffold and never disturbs a
  first-session doc.

If any updates are needed, **propose them to the user** as a list, routing each to the
right file:

```
Freshness updates needed:
1. .claude/project.json: commands.test → "vitest run" (was "npm test")
2. .claude/project.json: packageManager → "pnpm"
3. CLAUDE.md (Project facts): add "RESEND_API_KEY required or email send no-ops in dev"
```

(The stale-Bootstrapping cleanup is **not** in this list — it is run
deterministically by `strip-bootstrap.sh` above, not proposed.)

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
