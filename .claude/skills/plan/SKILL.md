---
name: plan
description: "Generate a phased plan from a spec against an ALREADY-EXISTING project."
user-invocable: true
---


## Input

$ARGUMENTS

A file path to the initiative's spec document. Read the entire file before proceeding.
If no path is provided, check `docs/spec/` and the workspace for likely candidates
(`*spec*`, `*prd*`, `*design*`) and confirm with the user; if nothing is found, ask.

## When this command applies

This is the **third entry path**: greenfield → `/init-project`, existing repo adoption →
`/onboard`, scoped change → `/task`, **multi-phase initiative on an existing project →
this command**. It generates only the three phase docs and flips ceremony — it does NOT
write a manifest, render `CLAUDE.md`, or render a README (the project already has all
three; that is what "existing" means).

Doc structures, sync rules, lineage, and archival conventions live in the
**`phase-docs` skill** — shared with `/init-project`, referenced not restated. Read it
before generating.

## Step 0 — Preconditions

Read `.claude/project.json`. If it doesn't exist, this project isn't guv-governed
yet — stop and direct the user to `/init-project` (greenfield) or `/onboard` (adopt).
Confirm it parses (`jq empty .claude/project.json`) — the "before" half of the D3
validation contract — and note `roots.control` (docs go there) and the current
`ceremony`.

## Step 1 — One active initiative at a time

Run the completeness check:

```bash
bash .claude/archive-initiative.sh --check
```

- **Exit 3 (INCOMPLETE):** refuse. Show the incomplete deliverable lines the script
  printed and stop: the user must finish the current initiative or explicitly abandon it
  (`bash .claude/archive-initiative.sh --archive <name> --force` — stamps an ABANDONED
  note into the frozen tracker). Do not archive on their behalf.
- **Exit 0 (COMPLETE):** a finished initiative is in place — it will be archived in
  Step 3. Note `max_phase=N` from the output; the new initiative numbers from N+1.
- **Exit 4 (NONE):** no real initiative to archive — either no tracker file exists, or
  the tracker holds only the scaffold's verbatim placeholder stubs (a freshly-scaffolded
  project whose phase docs aren't authored yet — the common fresh-onboard → first-plan
  path; also `/onboard`-adopted or task-mode-only repos). Nothing to archive; numbering
  starts at the value decided in Step 2 (default 1).
- **Exit 5 (MALFORMED):** the tracker has no recognizable deliverable bullets or phase
  headers. Stop — show the user, and repair the tracker by hand before re-running;
  never archive or overwrite something the script can't reason about.

## Step 2 — Analyze the Spec & Confirm

Extract and present a summary for the user to confirm — identity, phases, deliverables —
**skipping stack and topology**, which the existing manifest already declares:

- **Initiative identity:** name (becomes the archive slug later), one-sentence goal,
  and the governing spec path.
- **Phases:** name and goal (one sentence each), deliverable count per phase, key
  dependencies between phases. Number them continuously: first new phase =
  `max_phase + 1` from Step 1 (or 1 on a fresh project).
- **Constraints/invariants** the spec declares, if any — these carry into REQUIREMENTS'
  Dependencies & Risk Notes.
- **Session estimates, sized by the rubric** ([9.6], [13.2]): you are reading every
  deliverable's wording and acceptance here anyway, so size each one in the same
  breath. Don't guess a bare integer — judge what **fraction of a session's context
  budget** (the [9.2] occupancy setpoint) the deliverable will occupy, using the
  **rubric**: **light ≈ 0.35**, **medium ≈ 0.5**, **heavy ≈ 0.9** (`bash
  .claude/estimate.sh rubric` is the map). Calibrate against the dogfooded shape of
  each class: **light** is a focused change — an investigation or a small edit plus
  a test or two; **medium** is a new field/behavior with its doc, a caller
  integration, and tests; **heavy** is a core change across several files with
  logic, tests, a shape doc, the plugin mirror, and an eval pass. The judgment
  (which class) is yours; the helper maps the class to the stored fraction
  deterministically. The discipline is the point: a deliverable that would exceed
  **one** session's budget is a **balloon** — **SPLIT it** into deliverables that
  each fit one session, never record it as N > 1 (`set-sized` refuses a balloon); a
  deliverable judged *near* a full session is sized **heavy** (and watched), not
  left between classes. So "one deliverable ≈ one session" holds by construction,
  and the projection's quantity takeoff is honest.
  Estimates are interpretation, not plan state: they go in the **sidecar**, never in
  a deliverable line (`.claude/estimate.shape.md` documents the dual-form shape; the
  tracker stays byte-identical regardless of estimates). The user **ratifies the
  sizing in this same confirm gate** as the plan itself — present them as a column of
  the summary (ID → size class → fraction; any balloon shown as "split"), and fold
  any adjustment into the confirmation.

**Wait for the user to confirm or adjust before writing any files.** The confirmation
covers the plan *and* its estimates — one gate, both ratified.

## Step 3 — Archive the completed predecessor (if Step 1 found one)

First, **grade the closing initiative** ([13.4]) — the close-time settlement of the
forecast lineage it banked. This reads the banked forecasts, grades the opening
(plan-boundary) forecast against what actually happened, splits the miss into its two
layers (quantity vs rate), and banks the grade so the local record learns:

```bash
bash .claude/projection.sh grade
```

Record the two-error grade in the closing session's handoff / the lineage header.
**Best-effort, never a gate (Rule 15):** a predecessor that banked no forecast (a
pre-[13.4] initiative) exits 4 with "no banked forecast to grade" — note "no forecast
to grade" and continue; do not block archival on it. The banked grade also closes the
lineage window, so the new initiative's opening forecast (Step 5) re-banks cleanly.

Then archive:

```bash
bash .claude/archive-initiative.sh --archive "<prior-initiative-name>"
```

The script moves the completed REQUIREMENTS + PHASE_STATUS pair to
`docs/initiatives/NNN-<slug>/` (frozen), snapshot-copies ARCHITECTURE.md alongside, and
prints `archive_dir=` and `phase_range=` — record both for the lineage header.
`docs/sessions/` and `docs/spec/` are never touched. Name the prior initiative
descriptively (e.g. "greenfield" for an original build).

## Step 4 — Copy the spec with provenance

Copy the spec to `docs/spec/<original-name>.md` with the provenance header, per the
phase-docs skill. If the spec already lives at a `docs/spec/` path with a header, skip.

## Step 5 — Generate the three docs

Follow the phase-docs skill structures, in order, into `${roots.control}/docs/`:

1. **REQUIREMENTS.md** — opens with the **lineage header** (every prior initiative's
   phase range + archive dir from Step 3 / pre-existing lineage, then "This initiative:
   Phases A–B — governed by `docs/spec/<name>.md`"). Phases numbered continuously.
2. **ARCHITECTURE.md** — **revised in place**, not regenerated: existing
   completed-phase content collapses into current-state description; each new phase
   documents **current state and target state** (living system, not blank slate); first
   new phase detailed, later ones stubbed. If no ARCHITECTURE.md exists, generate fresh
   with the same current/target framing.
3. **PHASE_STATUS.md** — deliverables copied **verbatim** from the new REQUIREMENTS,
   all ⬜, Current Phase = the first new phase.
4. **The estimate sidecar** ([9.6], [13.2]) — record the sizing the user ratified in
   Step 2. This is a **separate file** (`docs/estimates.json` by default), keyed by
   deliverable ID, written **only** through the helper — never a tracker line, so the
   tracker stays byte-identical to REQUIREMENTS:

   ```bash
   bash .claude/estimate.sh set-sized <ID> <light|medium|heavy>   # ratify via the rubric
   ```

   `set-sized` records the context-fraction alongside the (always-1) session count.
   A balloon has no class — if a deliverable would exceed one session, **split it**
   (it should already have been split in Step 2); `set-sized` refuses `balloon`
   rather than letting an N > 1 estimate slip in. Validate the result: `bash
   .claude/estimate.sh validate`. The shape and rationale live in
   `.claude/estimate.shape.md`.

5. **The opening forecast** ([13.4]) — with the tracker and sidecar now written, bank
   the opening projection: the cost-to-complete forecast for the whole new initiative,
   made at plan time (n=0 structural, no landings yet). Banked at the `plan` boundary,
   it is the lineage's opening entry — the forecast the initiative-close grade later
   settles ("how good was the plan?"):

   ```bash
   bash .claude/projection.sh bank --at plan
   ```

   Idempotent — re-running /plan for this same initiative does not double-bank (the
   grade in Step 3 closed the predecessor's window, so this `--at plan` re-banks for
   the new initiative rather than colliding with the predecessor's opening forecast).

## Step 6 — Ceremony transition

If `ceremony` is not already `"phased"`, set it — and **announce the change** rather
than applying it silently:

```bash
tmp=$(mktemp) && jq '.ceremony = "phased"' .claude/project.json > "$tmp" && mv "$tmp" .claude/project.json
```

Validate after the edit — concretely: it still parses and the flip took
(`jq -e '.ceremony == "phased"' .claude/project.json`), and no top-level key fell
outside the schema's declared set (compare `jq -r 'keys[]'` output against the
`properties` of `.claude/project.schema.json`, the same check the resolver's tests
use). There is no
revert machinery: "phased with a fully-✅ tracker" is a clean resting state (`/task`
works inside phased projects, and the next `/plan` picks up from there).
Reverting to `task` for a maintenance-only project is a manual, optional act.

## After Generation

Present a summary:

- **docs/REQUIREMENTS.md** — Phases A–B, N total deliverables, lineage header recording
  [prior ranges]
- **docs/ARCHITECTURE.md** — revised in place; Phase A detailed (current → target),
  rest stubbed
- **docs/PHASE_STATUS.md** — N deliverables tracked, all ⬜
- **Archived:** `docs/initiatives/NNN-<slug>/` (or "nothing to archive")
- **Ceremony:** already phased / flipped task → phased (announced)

Suggest the user review the docs, commit them to the control plane, then start with
`/phase A`. Verify `/status` reports phase progress correctly before ending the
session that ran this command.
