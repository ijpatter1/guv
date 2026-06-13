Resume work on a phased project: read the resolver's ready-frontier and present the next pick with a light session plan — no phase-boundary ritual.

> **Provisional name.** This door ships **name-neutral**: `resume` is a placeholder,
> not a ratified verb. The verb grammar is priced from real usage evidence and
> chosen — once, by a person — at **[8.2]**; this command is renamed there. Don't
> build anything on the literal name `resume` before then.

This is the **light** daily/mid-phase entry door — the counterpart to the
phase-boundary command `/start-phase`. Use it to re-enter work you already have
context for: it computes what's ready and hands you a plan, and it deliberately
skips the boundary ritual (deep architecture read, UAT check, and the
spec-alignment pass). When you're *crossing into a new phase*, use `/start-phase`
instead — that door does the full sequence. (Both doors collapse into one
deterministically-routed entry at [8.1]; until then they coexist.)

## Step 0 — Confirm Phased Mode

Read `ceremony` from `.claude/project.json`:

- If `ceremony` is **`task`** or **`onboard`**, or `docs/PHASE_STATUS.md` doesn't
  exist, this project has no ready-frontier to resume — there is no plan DAG to
  resolve. That is a **mode signal, not an error**: tell the user to use
  `/task "<description>"` for scoped work (or `/onboard` to adopt the repo), and
  stop here.
- If `ceremony` is **`phased`**, continue.

This door takes **no phase argument** — the resolver reports which phase has open
work. (The name-neutral, argument-free shape is deliberate: 8.1 routes entry from
manifest + repo state, not from a typed phase number.)

## Step 1 — Resolve the Ready Frontier

Run the resolver — the single source of dispatch (never hand-read the tracker):

```
bash .claude/resolve-ready.sh
```

It emits `mode=`, `phase=`, `in_progress=`, `ready=`, `blocked=` (each blocked item
as `ID:ROOT`, the transitive unsatisfied dep), and `serial=` (first 🔄 else first
ready — the single "what to work on next" pick). Dispatch is **deps-only**: a
later-phase item in `ready=` is legitimate work; `phase=` is reporting, not a gate.

**Honor the resolver's exit code — a stale or empty view is worse than none:**

- **Exit 5 (MALFORMED):** the tracker fails validation (unknown ID, cycle). The
  resolver names the offenders on stderr. **Stop and surface them** — do not
  present a frontier or a plan off a broken tracker. Repairing a malformed tracker
  is its own task (and plan edits go through `/replan`), not a side effect of
  resuming.
- **Exit 4 (no tracker):** there is no `docs/PHASE_STATUS.md` to resolve (Step 0
  should have caught this). Stop and report.
- **Exit 0 with an empty frontier:** legitimate — every deliverable is ✅, or all
  open work is `blocked=`. Report that plainly (what's blocked, on what); it is a
  state, not a failure.
- **`mode=LEGACY`:** a token-free tracker has no deps graph — only `serial=`
  carries a value (the first open line's text, not an ID). Present that as the
  resume pick and note the tracker predates the DAG grammar.

## Step 2 — Light Reorientation

You already have context — this is a refresh, not the boundary deep-read:

1. Read the **Next Steps** of the most recent file in `docs/sessions/` (the last
   session's stated intent). If none exists, note "no prior sessions."
2. `bash .claude/guv-git.sh log --oneline -8` for recent code activity.
3. Establish the test baseline so you don't build on red: run
   `bash .claude/guv-cmd.sh test` and record pass/fail (a `[guv-cmd] … skipping`
   line means no test step — note it and move on). Don't introduce new failures
   this session.

Deliberately **not** done here (it's the `/start-phase` boundary ritual): the
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
  `/start-phase`.
- Don't implement anything outside the resolver's frontier. Fixes to prior-phase
  deliverables that the current work reveals are welcome; net-new scope goes
  through `/replan`.
- Commit after each completed feature with a conventional message.
