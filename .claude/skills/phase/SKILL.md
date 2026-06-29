---
name: phase
description: "Phase-boundary entry for a given phase: branch into the phase, deep-read it, run the full context-loading and spec-alignment sequence, and present a plan — the ritual for *crossing into* a phase."
user-invocable: true
---


This is the **boundary** door. Reach for it when you're entering a phase (or
returning after a long gap away): it performs the full sequence below, including
the spec-alignment check. For everyday **mid-phase resume**, where you already
have the context, use the light `/next` door instead — it reads the resolver's
ready-frontier and hands you a plan without the boundary ritual (no spec
alignment, no deep architecture re-read, no UAT check). Which door applies is no
longer a judgment call: the deterministic router (`.claude/route.sh`, **[8.1]**)
selects the entry door from manifest + repo state, and Step 0 defers to it — a
wrong-door invocation is redirected, never errored.

## Step 0 — Routing Guard

Before anything else, ask the deterministic router whether this is the right
door (the routing collapse — manifest + repo state select the entry, no
disambiguation; **never** decide the door by reading the tracker yourself):

```bash
bash .claude/route.sh --for phase
```

Read its `name=value` output and its exit code (the contract is identical
across all entry doors):

- **`match=yes`** (exit 0) — this *is* the right door for the current state.
  Continue to Step 1.
- **`match=no`** (exit 0) — **wrong door: redirect, don't error.** The router
  names the correct door in `door=` (e.g. `door=next` mid-phase, `door=task`
  in a scoped project, `door=init-project` greenfield). Tell the user the
  routed door and the `reason=`, and defer to it — run that door instead of
  this sequence. This is the misroute-impossible guarantee: you land on the
  right door without the user disambiguating.
- **Exit 3 (loud stop)** — an **ambiguous existing** project (unrecognized
  ceremony, or a MALFORMED tracker). The router emits no `door=`; surface its
  `reason=` and **stop** (rule 15) — do not proceed off an undetermined state.
- **Exit 4 (pre-scaffold)** — no manifest here yet: there is no phase to enter.
  The router returns `match=no` (phase does not apply to a fresh repo);
  tell the user to scaffold first — `/init-project` for a spec, `/onboard` for an
  existing repo — and **stop** rather than enter a phase off no project.
- **Exit 2** — the router itself is unavailable/misinvoked (it is absent, a flag
  is wrong, or `jq` is missing). Fall back to the mode check below and proceed;
  the router is the fast path, not the only one.

If the router confirmed this door (`match=yes`) you may skip the redundant mode
check below; it is kept as the exit-2 fallback.

## Step 0b — Confirm Phased Mode (router-unavailable fallback)

This command is the **phased** entry point. Read `ceremony` from `.claude/project.json`:

- If `ceremony` is **`task`** or **`onboard`**, or there are no phase docs in `docs/`
  (no `PHASE_STATUS.md` / `REQUIREMENTS.md`), this project has no phase structure.
  That is a **mode signal, not an error** — don't scaffold phase docs. Tell the user
  to use `/task "<description>"` for scoped work (or `/onboard` to adopt the repo),
  and stop here.
- If `ceremony` is **`phased`**, continue.

If no phase number was provided (i.e., $ARGUMENTS is empty), read `docs/PHASE_STATUS.md` to determine the current phase and use that. If the phase number doesn't match a phase in PHASE_STATUS.md, ask for clarification before proceeding.

## Step 1 — Run the Tests

Read `.claude/project.json`. Check whether the project has been scaffolded by running its `scaffoldCheck`:

```
sh -c "$(jq -r '.scaffoldCheck' .claude/project.json)" && echo SCAFFOLDED || echo NOT_SCAFFOLDED
```

- **If `SCAFFOLDED`:** Before running tools, check readiness if the manifest declares it. `readyCheck` answers "are the tools installed/runnable" — distinct from `scaffoldCheck`'s "does a project exist." If `readyCheck` is present and **fails**, the state is **NOT_INSTALLED**: the project is scaffolded but its dependencies aren't (common on a fresh clone where tools live in `node_modules`/`.venv`). In that case run the declared install command — `bash .claude/guv-cmd.sh install` — rather than running tests into spurious failures; note it. (`guv-cmd.sh` skips loudly when `commands.install` is `null`; in that case surface that deps appear missing but no install command is declared.) Then run the project's test command — `bash .claude/guv-cmd.sh test` — and record the results: total tests, passing, failing, skipped. A `[guv-cmd] … skipping` line means the project has no test step; note it and move on. If any tests are failing, note them — you must not introduce additional failures during this session.

  ```
  READY=$(jq -r '.readyCheck // empty' .claude/project.json)
  [ -n "$READY" ] && { sh -c "$READY" >/dev/null 2>&1 && echo READY || echo NOT_INSTALLED; } || echo READY
  # NOT_INSTALLED → run:  bash .claude/guv-cmd.sh install
  ```

- **If `NOT_SCAFFOLDED`:** The project hasn't been scaffolded yet. This is expected for the very first session of a `phased` project. Skip to Step 2 and note that scaffolding is the first deliverable. See the "Bootstrapping" section in CLAUDE.md for scaffolding requirements.

## Step 2 — Load Phase Context

Read these files in order:

1. `docs/PHASE_STATUS.md` — current completion state across all phases
2. `docs/REQUIREMENTS.md` — find the section for Phase $ARGUMENTS and read the full deliverables list
3. `docs/ARCHITECTURE.md` — read the sections relevant to Phase $ARGUMENTS
4. The most recent file in `docs/sessions/` — the last session's handoff artifact

## Step 3 — Check Manual Tasks

Check if `docs/manual/` exists and contains any task cards or scripts:

```
ls docs/manual/task-*.md docs/manual/task-*.sh 2>/dev/null
```

If manual tasks exist, read each one and check the **Status** field (in the header comment for scripts, in the frontmatter for cards):

- **`pending`** — the human hasn't done this yet. Note it in the status summary. If it blocks a deliverable, do not plan work on that deliverable.
- **`done`** — the human completed it. Read the **Notes** field for any information the agent needs (configuration values, URLs, unexpected outcomes). If the task was blocking a deliverable, that deliverable is now unblocked.
- **`blocked`** — the human tried but hit a problem. Read the Notes for details. Flag this in the status summary.

## Step 4 — Review Recent Git History

Inspect the **code** repo's history via the git helper — it targets `roots.code` from the manifest (a no-op for single-repo, where `roots.code` is `"."`):

```
bash .claude/guv-git.sh log --oneline -15
```

Use this to understand what was worked on recently and what state the codebase is in.

## Step 5 — Spec Alignment Check

Identify the **governing spec** — specs accumulate over a project's life, so resolve in
this order:

1. **Lineage header first.** Read the top of `docs/REQUIREMENTS.md`: if a
   `> **This initiative:** … governed by \`docs/spec/<name>.md\`` line exists, that
   file is the governing spec. Do not align against an older spec just because it is
   also present in `docs/spec/`.
2. Otherwise look for common locations:

   ```
   ls docs/spec/*.md docs/SPEC.md docs/spec.md docs/PRD.md docs/prd.md 2>/dev/null
   ```

   If exactly one exists, use it. If several exist and no lineage header names one,
   ask the user which governs before proceeding.
3. Also check CLAUDE.md's References section for any referenced spec files.

**If a spec exists:** Invoke the `reviewer` subagent with a targeted prompt:

"Compare the Phase [N] deliverables in docs/REQUIREMENTS.md against the original spec at [path]. For each incomplete deliverable (⬜ or 🔄 in PHASE_STATUS.md) that the agent is about to work on this session, flag anything that was thinned out, oversimplified, or lost in translation from the spec. Don't review the whole project or completed deliverables — just what's in scope for this session. Be specific: quote the spec and quote the requirement side by side where there's a gap."

Review the product reviewer's findings. **This step detects and routes; it does not
mutate.** If it identifies gaps, close them by routing each finding through
the `/replan` command's procedure — classify, confirm, apply REQUIREMENTS first
through the engine, verify:

- **Thin deliverables** (the requirement is a pale summary of a richer spec
  description) and **drifted deliverables** (the requirement says something
  different from the spec) route as rewords — restore the spec's intent in the
  wording, deps token included if the gap is sequencing.
- **Missing deliverables** (spec functionality with no corresponding requirement)
  route as inserts into the appropriate open phase.
- Architectural detail the spec describes that `docs/ARCHITECTURE.md` lacks is
  covered by `/replan`'s apply step where it rides a deliverable mutation; a pure
  ARCHITECTURE gap with no deliverable change is a direct doc edit, not a plan
  mutation — fix it in place.

One `/replan` operation per finding, each with its own confirmation and its own
commit under `/replan`'s convention (`docs(replan): <verb> [IDs] — <one-line why>`).
Only a pure-ARCHITECTURE fix with no plan mutation gets the umbrella message
`docs: fortify Phase N requirements from spec alignment review`.

**Headless / autonomous sessions (user offline) — the draft-and-defer path.**
`/replan`'s confirm gate (its Step 3) forbids writing any doc before the user
ratifies, and a headless confirmation can only clear if the prompt already named
the exact mutation. When neither holds — a finding surfaces here but no one is
present to confirm it — **do not** block on an unanswerable confirm and **do not**
auto-apply a gated mutation. Take the Rule-15 designed degradation: draft the
mutation in full, surface it in the handoff for later ratification, and honor the
spec's intent directly in this session's deliverable where you can without touching
plan state. The mutation lands through `/replan` once a person is back.

These updates ensure the identified gaps are captured in the project's permanent
record — with amendment records naming what changed — not just in the agent's
session plan. The session plan in Step 7 then works from the fortified docs.

**If no spec exists:** Skip this step. The requirements and architecture docs are the source of truth.

## Step 6 — Assess Current State

Based on what you've read, produce a brief status summary:

- **Phase $ARGUMENTS progress:** what deliverables are complete, what remains
- **Test baseline:** X passing, Y failing, Z skipped
- **Last session:** what was done, what was left in progress or blocked
- **Manual tasks:** any pending or blocked manual tasks, and what they affect
- **Spec alignment:** gaps found and docs updated (list what changed), or "no spec found" / "aligned"
- **Codebase state:** clean build? any outstanding issues?

## Step 7 — Plan This Session

Identify the next feature or deliverable to work on within Phase $ARGUMENTS. State:

1. **What you'll build** — the specific feature or deliverable
2. **Spec depth** — if the docs were fortified in Step 5, state how the updated requirements change the scope or approach compared to what was there before
3. **How you'll test it** — the tests you'll write first (red/green TDD)
4. **Integration points** — what existing code this touches
5. **Definition of done** — how we'll know this feature is complete
6. **Fan-out offer (non-blocking)** — when the frontier holds two or more ready
   items, run the scaffold (`bash .claude/resolve-ready.sh | bash
   .claude/fanout-offer.sh -`) and surface whether they could be built in parallel.
   It reports the **mechanical** half — the floor `count(ready=) ≥ 2`, the
   candidates, their sizes, and `default=serial`; `offer=yes` means *mechanically
   eligible*, pending your judgments. **Surface-disjointness** (do they touch
   *independent* code? judge it from the candidates' wording and acceptance, not
   their IDs) and the composite **fit-verdict** (which also weighs whether the lanes
   are *worth* the orchestration) are yours to add — the scaffold marks
   `disjointness=agent-judgment` because it is a judgment over the wording, never a
   resolver fact. Present the explicit three-way call: **fan out** (hand the
   disjoint, sized set to `/build-fanout <ids>`), **serial** (the `serial=` pick),
   or **size first** (`offer=size-first` — **size** an unsized `needs_sizing=`
   candidate via a bare `bash .claude/estimate.sh set-sized <id> <light|medium|heavy>`
   with no `/replan`, **split** a `balloons=` candidate via `/replan`, first). The
   offer **never blocks**: `offer=not-assessed` degrades to "fan-out not assessed
   (reason); serial pick is …". The **designed default is SERIAL** (Rule 15) — a
   headless or unanswered run takes the `serial=` pick, records the offer
   declined-by-absence in the session handoff, and never spawns worktrees
   unattended.

**In interactive mode:** Wait for the user to approve the plan before starting implementation. Do not begin coding until the plan is confirmed or adjusted.

**In headless/bypass mode:** Present the plan, then proceed to implementation. The plan is logged in the session transcript for post-hoc review. If the task was provided via a prompt (e.g., `make prompt P="..."`), treat the prompt as pre-approved scope and plan accordingly.

## Reminders

- Use red/green TDD for every feature. Write the test first, watch it fail, then implement.
- Work on one feature at a time. Complete it (including tests) before moving to the next.
- Commit after each completed feature with a descriptive conventional commit message.
- Do not implement deliverables outside the resolver's frontier. Dispatch is deps-only ([7.6]): a later-phase item in `ready=` is legitimate work; an item not in the frontier — whatever its phase — is not. Fixes and improvements to prior phase deliverables are encouraged when the current phase's work reveals gaps.
- If you encounter a decision point with multiple valid approaches, pause and explain the tradeoffs.
