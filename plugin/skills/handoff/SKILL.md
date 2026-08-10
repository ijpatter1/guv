---
name: handoff
description: "End the current work session by accounting for the review gates, generating a structured handoff artifact, and updating the phase tracker."
user-invocable: true
---


## Step 1 — Review Accounting (the gate ledger)

Review cost is paid **in-band, once per change**, at the review gate defined once in
the `/guv:eval` skill (plugin-shipped) — the session-invoked
platform review plus the `reviewer` by name. **Do not restate its procedure
here.** Handoff runs no duplicate session-close review; it **accounts**: every
session commit either passed an in-band gate or gets one now.

- **All commits gated in-band** (each carried through `/guv:task` or an equivalent
  scoped flow whose gate ran before commit): skip the session-close review — and
  **disclose the skip** in the handoff artifact under **Review Results**, naming
  the in-band gate(s). The skip is **never silent**, and no review is ever
  silently dropped.
- **Any commit not gated in-band** (a hand commit, or any commit you cannot
  account to a gate): the skip does not apply — that scope still gets reviewed:
  run the `/guv:eval` gate over it now. When in doubt, do not skip: run it.
- **Docs-only sessions** (no code-repo commits this session): the gate, when it
  runs, is told it is reviewing control-plane/doc work — not product code — so
  findings are judged accordingly rather than reporting "no tests" against
  documentation.

### Verdict gates (provenance split)

- A **Critical in a change under review** (surfaced at its gate) blocks **that
  change** — fix it before the handoff proceeds.
- A **Critical in surrounding code** the review happened to walk is **recorded**
  in **Issues & Technical Debt** with its provenance — never a blocker on a
  change that did not cause it.
- Major/Minor findings were graded at the gate (fix what changes a decision,
  record the rest); the recorded residuals land in **Issues & Technical Debt**
  with severity, reviewer, and the reason they were carried.
- Ship-with-debt is the **person's** selection, made on a drafted disclosure;
  unanswered or headless takes the stop.

(Step 2 was absorbed into Step 1 when the dual session-close review retired at
[32.1]; later step numbers are unchanged so cross-references hold.)

## Step 3 — Final Test Run

**Skip when no code changed:** if this session made no commits to `roots.code` and
holds no uncommitted changes there, do not run the battery — record "battery
skipped: no code changes this session" under **Test State** and move on
(…318248606). A docs-only session pays no suite tax.

Otherwise run the full test suite to confirm the codebase is in a clean state, via
the manifest-command helper. Time the run and write the measured wall-clock to the
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
**Issues & Technical Debt**, **Review Results**, **Test State**, **Build State**,
**Next Steps**, **Session Notes**. (The skeleton
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

Then generate a user acceptance testing plan. The UAT plan verifies that the phase's deliverables work end-to-end as a user would experience them — not unit test coverage or spec alignment (the review gate covered those at each change's landing), but real-world workflows from start to finish.

### Generating the UAT Plan

Draft the scenarios yourself — you just built the phase, so you know what shipped: end-to-end user acceptance scenarios that test the phase's deliverables as a user would experience them, working from docs/REQUIREMENTS.md for the deliverables, docs/ARCHITECTURE.md for the technical design, and any content guides or specs referenced in CLAUDE.md. Focus on realistic workflows, not individual feature checks — each scenario should exercise multiple deliverables working together.

Produce the artifact from those scenarios. Then **vet it via the
`reviewer`** ([18.2]) — by name (Rule 14; since [32.3] the reviewer is the one
calibrated vet for every generated artifact), and **independent of the session** that
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
