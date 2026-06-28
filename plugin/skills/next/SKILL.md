---
name: next
description: "Re-enter work on a phased project: read the resolver's ready-frontier and present the next pick with a light session plan — no phase-boundary ritual."
user-invocable: true
---


This is the **light** daily/mid-phase entry door — the counterpart to the
phase-boundary command `/guv:phase`. Use it to re-enter work you already have
context for: it computes what's ready and hands you a plan, and it deliberately
skips the boundary ritual (deep architecture read, UAT check, and the
spec-alignment pass). When you're *crossing into a new phase*, use `/guv:phase`
instead — that door does the full sequence. Which door applies is decided
deterministically by the router (`"${CLAUDE_PLUGIN_ROOT}"/scripts/route.sh`, [8.1]): Step 0 defers to
it, and a wrong-door invocation is redirected rather than errored.

## Step 0 — Routing Guard

Ask the deterministic router whether this is the right door (the routing
collapse — manifest + repo state select the entry, no disambiguation; **never**
hand-read the tracker to decide):

The router's exit code is the contract, identical across all five entry doors:

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/route.sh --for next
```

- **`match=yes`** (exit 0) — this is the right door; continue to Step 1.
- **`match=no`** (exit 0) — **wrong door: redirect, don't error.** The router
  names the correct door in `door=` (e.g. `door=phase` at a phase
  boundary, `door=task` in a scoped project, `door=init-project` greenfield).
  Tell the user the routed door and the `reason=`, and defer to it.
- **Exit 3 (loud stop)** — an **ambiguous existing** project (unrecognized
  ceremony, or a MALFORMED tracker; the resolver's exit-5 condition surfaces
  here too). The router emits no `door=`; surface its `reason=` and **stop**
  (rule 15) — do not present a plan off an undetermined state.
- **Exit 4 (pre-scaffold)** — no manifest here yet: there is no plan to resume.
  The router returns `match=no` (resume does not apply to a fresh repo); tell the
  user to scaffold first — `/guv:onboard` for an existing repo, `/guv:init-project` for a
  spec — and **stop** rather than resume off no project.
- **Exit 2** — the router is unavailable/misinvoked (absent, a wrong flag, or
  `jq` missing); fall back to the mode check below and proceed.

## Step 0b — Confirm Phased Mode (router-unavailable fallback)

Read `ceremony` from `.claude/project.json`:

- If `ceremony` is **`task`** or **`onboard`**, or `docs/PHASE_STATUS.md` doesn't
  exist, this project has no ready-frontier to resume — there is no plan DAG to
  resolve. That is a **mode signal, not an error**: tell the user to use
  `/guv:task "<description>"` for scoped work (or `/guv:onboard` to adopt the repo), and
  stop here.
- If `ceremony` is **`phased`**, continue.

This door takes **no phase argument** — the resolver reports which phase has open
work. (The name-neutral, argument-free shape is deliberate: 8.1 routes entry from
manifest + repo state, not from a typed phase number.)

## Step 1 — Resolve the Ready Frontier

Run the resolver — the single source of dispatch (never hand-read the tracker):

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh
```

It emits `mode=`, `phase=`, `in_progress=`, `ready=`, `blocked=` (each blocked item
as `ID:ROOT`, the transitive unsatisfied dep), and `serial=` (first 🔄 else first
ready — the single "what to work on next" pick). Dispatch is **deps-only**: a
later-phase item in `ready=` is legitimate work; `phase=` is reporting, not a gate.

**Honor the resolver's exit code — a stale or empty view is worse than none:**

- **Exit 5 (MALFORMED):** the tracker fails validation (unknown ID, cycle). The
  resolver names the offenders on stderr. **Stop and surface them** — do not
  present a frontier or a plan off a broken tracker. Repairing a malformed tracker
  is its own task (and plan edits go through `/guv:replan`), not a side effect of
  resuming.
- **Exit 4 (no tracker):** there is no `docs/PHASE_STATUS.md` to resolve (Step 0
  should have caught this). Stop and report.
- **Exit 0 with an empty frontier:** legitimate — every deliverable is terminal
  (✅ done or ❌ descoped), or all open work is `blocked=`. Report that plainly
  (what's blocked, on what); it is a state, not a failure.
- **`mode=LEGACY`:** a token-free tracker has no deps graph — only `serial=`
  carries a value (the first open line's text, not an ID). Present that as the
  next pick and note the tracker predates the DAG grammar.

## Step 2 — Light Reorientation

You already have context — this is a refresh, not the boundary deep-read:

1. Read the **Next Steps** of the most recent file in `docs/sessions/` (the last
   session's stated intent). If none exists, note "no prior sessions."
2. `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-git.sh log --oneline -8` for recent code activity.
3. Establish the test baseline so you don't build on red: run
   `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/guv-cmd.sh test` and record pass/fail (a `[guv-cmd] … skipping`
   line means no test step — note it and move on). Don't introduce new failures
   this session.

Deliberately **not** done here (it's the `/guv:phase` boundary ritual): the
spec-alignment review, the full ARCHITECTURE read, the UAT-results check.

## Step 3 — Present the Frontier and Plan

Present a short summary and a plan for the `serial=` pick:

- **Frontier:** the serial pick (headline), the rest of `ready=`, what's
  `blocked=` and on what, anything `in_progress=`.
- **Plan for the pick:** what you'll build, how you'll test it (red/green TDD),
  what it touches, and the definition of done — working from the deliverable's
  REQUIREMENTS line and acceptance criteria.

**In interactive mode:** wait for the user to approve or adjust the pick before
coding. **In headless/bypass mode:** present the plan and proceed; a prompt that
named a specific deliverable is pre-approved scope. If the user wants a *different*
ready item than the serial pick, that's their call — the resolver says what *may*
be worked, a person decides what *is*.

## Reminders

- This door is light by design. If you find yourself wanting the spec-alignment
  pass or a fresh architecture read, you're at a phase boundary — use
  `/guv:phase`.
- Don't implement anything outside the resolver's frontier. Fixes to prior-phase
  deliverables that the current work reveals are welcome; net-new scope goes
  through `/guv:replan`.
- Commit after each completed feature with a conventional message.
