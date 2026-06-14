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

This is the **third entry path**: greenfield → `/guv:init-project`, existing repo adoption →
`/guv:onboard`, scoped change → `/guv:task`, **multi-phase initiative on an existing project →
this command**. It generates only the three phase docs and flips ceremony — it does NOT
write a manifest, render `CLAUDE.md`, or render a README (the project already has all
three; that is what "existing" means).

Doc structures, sync rules, lineage, and archival conventions live in the
**`phase-docs` skill** — shared with `/guv:init-project`, referenced not restated. Read it
before generating.

## Step 0 — Preconditions

Read `.claude/project.json`. If it doesn't exist, this project isn't guv-governed
yet — stop and direct the user to `/guv:init-project` (greenfield) or `/guv:onboard` (adopt).
Confirm it parses (`jq empty .claude/project.json`) — the "before" half of the D3
validation contract — and note `roots.control` (docs go there) and the current
`ceremony`.

## Step 1 — One active initiative at a time

Run the completeness check:

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/archive-initiative.sh --check
```

- **Exit 3 (INCOMPLETE):** refuse. Show the incomplete deliverable lines the script
  printed and stop: the user must finish the current initiative or explicitly abandon it
  (`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/archive-initiative.sh --archive <name> --force` — stamps an ABANDONED
  note into the frozen tracker). Do not archive on their behalf.
- **Exit 0 (COMPLETE):** a finished initiative is in place — it will be archived in
  Step 3. Note `max_phase=N` from the output; the new initiative numbers from N+1.
- **Exit 4 (NONE):** no tracker exists (first initiative on this project, e.g. it was
  adopted via `/guv:onboard` or has run task-mode only). Nothing to archive; numbering
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
- **Session estimates** ([9.6]): you are reading every deliverable's wording and
  acceptance here anyway, so propose a session estimate per deliverable in the same
  breath. guv pushes deliverables toward session-sized, so the **default is
  1** — propose 1 unless the scope genuinely reads as multi-session, and **flag any
  balloon** (estimate > 1) explicitly so the user sees it. Estimates are
  interpretation, not plan state: they go in the **sidecar**, never in a deliverable
  line (`"${CLAUDE_PLUGIN_ROOT}"/scripts/estimate.shape.md` documents the shape; the tracker stays
  byte-identical regardless of estimates). The user **ratifies the estimates in this
  same confirm gate** as the plan itself — present them as a column of the summary
  (ID → estimate, balloons marked), and fold any adjustment into the confirmation.

**Wait for the user to confirm or adjust before writing any files.** The confirmation
covers the plan *and* its estimates — one gate, both ratified.

## Step 3 — Archive the completed predecessor (if Step 1 found one)

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/archive-initiative.sh --archive "<prior-initiative-name>"
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
4. **The estimate sidecar** ([9.6]) — record the estimates the user ratified in Step 2.
   This is a **separate file** (`docs/estimates.json` by default), keyed by deliverable
   ID, written **only** through the helper — never a tracker line, so the tracker stays
   byte-identical to REQUIREMENTS:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/estimate.sh set <ID> <N>   # once per deliverable; default N is 1
   ```

   A deliverable left at the default 1 may be `set` for completeness or left unset
   (an unrecorded ID reads as 1). Validate the result: `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/estimate.sh
   validate`. The shape and rationale live in `"${CLAUDE_PLUGIN_ROOT}"/scripts/estimate.shape.md`.

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
revert machinery: "phased with a fully-✅ tracker" is a clean resting state (`/guv:task`
works inside phased projects, and the next `/guv:plan` picks up from there).
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
`/guv:phase A`. Verify `/guv:status` reports phase progress correctly before ending the
session that ran this command.
