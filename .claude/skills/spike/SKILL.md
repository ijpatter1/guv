---
name: spike
description: "Free-form / exploratory entry door. For work that has a goal but no deliverable DAG — a question to answer, a design to road-test, an investigation that produces a finding — held with light structure (goal, timebox, findings drain) and no phase ceremony. Use when the work is exploratory and fits neither a scoped change (task), a repo adoption (onboard), nor a multi-phase initiative (phased)."
user-invocable: true
---

This is the **exploration** door — the counterpart to `/task` (a scoped change),
`/onboard` (adopt a repo), and `/phase`·`/next` (a planned initiative). Reach for
it when the work is genuinely free-form: a question to answer, a design to
road-test, an audit or investigation whose **output is a finding**, not a shipped
deliverable. A spike has a goal and a timebox but **no deliverable DAG** — there is
no `PHASE_STATUS.md`, no resolver frontier, no red/green gate. Its structure is
deliberately light: **a goal, a timebox, and a findings drain.** Everything it
needs already exists — this door composes existing primitives, it does not add new
machinery.

Which door applies is decided deterministically by the router
(`.claude/route.sh`, [8.1]); Step 0 defers to it, and a wrong-door invocation is
redirected rather than errored.

## Step 0 — Routing Guard

Ask the deterministic router whether this is the right door (the routing collapse
— manifest + repo state select the entry, no disambiguation):

```bash
bash .claude/route.sh --for spike
```

The router's exit code is the contract, identical across all entry doors:

- **`match=yes`** (exit 0) — this is the right door; continue to Step 1.
- **`match=no`** (exit 0) — **wrong door: redirect, don't error.** The router
  names the correct door in `door=` (e.g. `door=next`/`door=phase` in a phased
  project, `door=task` in a scoped one, `door=onboard`/`door=init-project` on a
  fresh repo). Tell the user the routed door and the `reason=`, and defer to it.
- **Exit 3 (loud stop)** — an **ambiguous existing** project (unrecognized
  ceremony, or a MALFORMED tracker). The router emits no `door=`; surface its
  `reason=` and **stop** (rule 15) — do not start a spike off an undetermined state.
- **Exit 4 (pre-scaffold)** — no manifest here yet: there is nothing to explore in
  an empty repo. The router returns `match=no`; tell the user to scaffold first —
  `/onboard` for an existing repo, `/init-project` for a spec — and **stop**.
- **Exit 2** — the router is unavailable/misinvoked (absent, a wrong flag, or `jq`
  missing); fall back to the mode check below and proceed.

## Step 0b — Confirm Spike Mode (router-unavailable fallback)

Read `ceremony` from `.claude/project.json`:

- If `ceremony` is **`spike`**, continue.
- If it is `phased`, `onboard`, or `task`, this project is not in spike mode —
  that is a **mode signal, not an error**: name the door that fits
  (`/next` or `/phase` for phased, `/task` for a scoped change, `/onboard` to
  adopt a repo) and stop here.

A spike takes **no tracker argument** — there is no plan DAG to resolve. The goal
is whatever the user brought; the structure is the three light pieces below.

## Step 1 — State the Goal

Write down the **one thing this spike is to settle** — the question to answer or
the decision to inform — in a sentence or two. This is the spike's whole scope: a
spike with no stated goal is unbounded exploration, which is the failure mode this
ceremony exists to prevent. The goal becomes the header of the finding you drain in
the closing step.

## Step 2 — Set the Timebox / Budget

A spike is **bounded exploration, not open-ended**. Confirm the budget the same way
every other session does — the `budgets.session` setpoint in `.claude/project.json`
and the `budget-gate.sh` tension gate ride a spike exactly as they ride a phased
session (the gate is ceremony-agnostic). State the timebox you intend (a token
budget, a number of compaction windows, or a wall-clock bound) so the exploration
has an edge to stop at rather than drifting.

## Step 3 — Name the Findings Drain

**Before you begin, decide where the finding will land.** A spike's value is its
finding, and a finding with no destination evaporates. Name one drain now:

- **`docs/spikes/`** — write the finding as a dated design note (the home the
  [21.1]/[22.1] findings use). The default for an investigation whose output is the
  reasoning itself.
- **`/plan` or `/replan insert`** — when the finding gates real build work, groom
  it into the plan as deliverables.
- **`/feedback`** — when the finding is friction with guv itself.

Naming the drain up front is what keeps the spike honest: you are exploring *toward*
a destination, not wandering.

## Step 4 — Begin the Exploration

Do the work. A spike has **no phase DAG and no resolver** — you are not building a
deliverable against a red/green gate, you are answering the goal. Capture the
finding as you go (in the drain you named), so the record is the work product, not
an afterthought. Stay inside the timebox from Step 2; when the goal is answered — or
the timebox is spent — stop and drain the finding to its named destination, then
close with the non-phased `/handoff` (a spike records like any other session; there
is no phase to seal).

## Reminders

- **Light by design.** No `PHASE_STATUS.md`, no deliverable DAG, no per-step
  red/green. If you find yourself wanting a plan with sequenced deliverables, the
  work is not a spike — it is a phased initiative (`/plan`) or a scoped change
  (`/task`); route there instead.
- **The finding outlives the spike.** The ceremony is the scaffolding; the finding
  in its drain is what persists. A spike that ends without a drained finding has
  produced nothing — name the drain in Step 3 and honor it on the way out.
- **Compose, don't build.** The timebox is `budgets.session`/`budget-gate.sh`, the
  drain is `docs/spikes/` + `/feedback`, the record is the non-phased `/handoff` —
  all existing. The spike door adds a goal and a destination, nothing more.
