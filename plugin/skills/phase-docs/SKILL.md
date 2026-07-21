---
name: phase-docs
description: Shared templates and rules for generating the three phase docs (REQUIREMENTS, ARCHITECTURE, PHASE_STATUS) plus initiative lineage and archival conventions. Referenced by /guv:init (greenfield) and /guv:plan (existing project) so the structures live once. Not a workflow — a reference.
user-invocable: false
---

# Phase Docs — Shared Structures & Rules

Both generators (`/guv:init` for greenfield, `/guv:plan` for an initiative on
an existing project) write the same three documents. The structures and sync rules below
are the single source for both; the commands stay linear and reference this skill instead
of inlining templates.

**Generation order is REQUIREMENTS → ARCHITECTURE → PHASE_STATUS** — each builds on the
previous; do not generate them in parallel. All three are written to
`${roots.control}/docs/`.

## docs/REQUIREMENTS.md

```markdown
# [Project Name] — Development Plan & Requirements

[LINEAGE HEADER — initiatives only; omit for greenfield. See "Lineage header" below.]

## Project Vision

[2-3 paragraphs synthesized from the spec's overview/purpose sections]

---

## Phase N — [Phase Name]

**Goal:** [One sentence from the spec or synthesized]

**Deliverables:**

1. **[N.1]** [Specific, measurable deliverable] `[deps: none]`
2. **[N.2]** [Another deliverable] `[deps: N.1]`

**Why this is Phase N:** [Dependencies and sequencing rationale]

---

[Repeat for all phases]

## Dependencies & Risk Notes

[Extract from spec or synthesize from phase analysis]
```

Rules:

- Deliverables must be specific and testable — "Scout agent with toolkit" not "build the scout functionality"
- Each deliverable should be completable in roughly 1-3 work sessions
- If a spec deliverable is too large, break it into sub-deliverables
- Every deliverable carries a leading bold ID and a trailing deps token per
  "Tracker grammar" below — the ID and token are part of the deliverable's
  wording and sync verbatim into the tracker
- Phase placement carries no ordering ([7.6]): `[deps: none]` means
  *dispatchable immediately*, full stop — across phases. If a deliverable
  must follow another, same phase or not, declare the dep at authoring time;
  a forgotten dep silently parallelizes sequential work (the A-002 authoring
  duty — plan generators and `/guv:replan` inserts are held to this bar)
- Include a validation/acceptance section per phase if the spec has one
- Preserve the spec's own phase structure if it has one — do not re-sequence unless the ordering has clear dependency violations

## docs/ARCHITECTURE.md

```markdown
# [Project Name] — Technical Architecture

## System Overview

[Architecture diagram in ASCII/text or description of major components and data flow]

---

## Phase N — [Phase Name] Architecture

### [Component/Layer Name]

[Detailed architecture for this component]

### Key Architectural Decisions

- [Decision and rationale]

### Data Model

[If applicable — schemas, database structure, key types]

### Deployment

[Where and how Phase N components are deployed]

---

## Phase N+1+ — Architecture Stubs

[1-2 sentence stub per remaining phase — expand when phase begins]
```

Rules:

- The first active phase gets full architectural detail — enough for Claude Code to implement without guessing
- Include data models, directory structure, key interfaces/types, and configuration formats
- Extract technology choices from the spec (databases, frameworks, APIs)
- Later phases get stubs only — detailed architecture written too early becomes stale
- If the spec has architectural diagrams or component descriptions, preserve their substance
- **Initiatives only:** this is a refactor of a living system, not a blank slate. Each
  phase section documents **current state and target state** (what exists today, what it
  becomes). ARCHITECTURE.md is **revised in place**, never archived-and-regenerated:
  completed-phase sections become current-state description; new phases get the
  detailed-first-plus-stubs treatment above.

## docs/PHASE_STATUS.md

```markdown
# Phase Status Tracker

> **Current Phase: N — [Phase Name]**
> Last updated: YYYY-MM-DD, session-YYYY-MM-DD-NNN

---

## Phase N — [Phase Name]

_Goal: [Copy from REQUIREMENTS.md]_

- ⬜ **[N.1]** [Deliverable 1 — exact wording from REQUIREMENTS.md] `[deps: none]`
- ⬜ **[N.2]** [Deliverable 2 — exact wording from REQUIREMENTS.md] `[deps: N.1]`

---

[Repeat for all phases]
```

Rules (the verbatim-sync contract):

- Every deliverable line must be copied verbatim from REQUIREMENTS.md
- All items start as ⬜ (markers: ✅ complete · 🔄 in progress · ⬜ not started · ❌ blocked · 🔒 human-gated)
  - **🔒 human-gated / awaiting-manual** is the fifth marker: a deliverable blocked
    on out-of-sandbox human or manual work — the kind `/guv:manual` writes to
    `docs/manual/` — rather than on a dependency. It is *not* ❌ (no descope, the
    work is real and pending) and *not* ⬜/blocked (no in-graph dep gates it; the
    gate is a person). The marker-counting skills (`status`, `handoff`) count 🔒 as
    human-gated, a category of its own, never folded into the dependency-blocked
    tally. Pair a 🔒 line with the `docs/manual/` artifact that carries the manual
    step (a tracker-local annotation after the deps token, like any completion note).
- Do not add, remove, or reword any deliverables — the tracker and REQUIREMENTS must
  match exactly, forever; wording changes happen in REQUIREMENTS first and sync here
- The ID and deps token are part of the wording and sync verbatim with it.
  Completion annotations (date, session reference, blocked-on notes) are
  tracker-local and go **after** the deps token — they never sync back

## Tracker grammar — IDs & deps tokens

The dependency grammar for phase docs is defined here and only here; every
consumer (the templates above, the sync rules, `archive-initiative.sh`'s
validation, the resolver contract below) follows this section.

**ID:** every deliverable leads with a bold bracketed ID — `**[N.M]**`, where
`N` is the phase number and `M` the ordinal within the phase. Continuous phase
numbering (below) makes IDs globally unique across the project's history.

**Deps token:** every deliverable's *wording* ends with a backticked deps
token — `` `[deps: 6.1]` ``, comma-separated for multiples with the separator
exactly comma-space (`` `[deps: 6.1, 6.3]` ``, never `6.1,6.3`), and
**mandatory `` `[deps: none]` `` where
empty**. In the tracker, tracker-local completion annotations may follow it.
Backticks because inline code survives the auto-format hook untouched;
mandatory `none` because absence-means-no-deps would let a forgotten
annotation silently parallelize sequential work — omission must fail loud as
MALFORMED. Because annotations follow the token, tooling validates the **last**
deps-shaped construct on each line as the deliverable's own — a deps-token
example quoted in the wording must precede the real token, where it is
tolerated and ignored.

The canonical regex is the shared `DEPS_RE` defined identically in the three
enforcing scripts — `resolve-ready.sh`, `replan.sh`, and
`archive-initiative.sh` — which are this token's **source of truth**; the
prose above is the human-readable gloss, the regex is the law:

```
DEPS_RE='`\[deps: (none|[0-9]+\.[0-9]+(, [0-9]+\.[0-9]+)*)\]`'
```

Quoted here verbatim so the grammar is documented where it is taught, not only
where it is enforced; `grammar-surface.test.sh` guards this copy byte-identical
against the scripts' `DEPS_RE` (a doc-drift fails loud rather than rotting silently).

**Semantics:**

- Deps tokens encode "must follow"; document order is presentation only.
  A deliverable is *ready* when every ID in its deps token is ✅.
- Deps are the only ordering; phases are reporting ([7.6], per the A-002
  decision). A cross-phase dep in either direction is an ordinary edge — a
  ❌ dep propagates blockage wherever it sits. Phases remain the unit of
  narrative, review, and UAT; dispatch is deps-only. (Forward cross-phase
  deps were MALFORMED while the phase barrier gated dispatch; the lint
  repealed with the barrier whose companion it was.)
- Deps live in the deliverable's wording, never in the annotation zone — they
  sync verbatim, and dep changes happen in REQUIREMENTS first like any other
  wording change.

**LEGACY:** a tracker with no IDs and no deps tokens is LEGACY — document
order encodes dependency order (the original semantics, exactly), the first ⬜
in document order is next, and there is no parallel set. Old initiatives are
never misread; the grammar is opt-in by annotation. Mixing is MALFORMED: once
any line carries a token, every line must. Opting in is therefore a one-time
migration act: annotate **every** line in one edit — REQUIREMENTS first, then
the tracker, document order becoming explicit `[deps: …]` edges — and validate
with `archive-initiative.sh --check`. This single all-lines edit is the one
sanctioned hand edit of a live tracker (there is no `/guv:replan` verb for it,
deliberately — the door requires the grammar it would be installing); from
that commit on, `/guv:replan` owns every mutation.

**MALFORMED (fail loud, exit 5 in tooling):** duplicate IDs; an ID'd line
missing its deps token; a malformed token (empty list, unknown format, missing
backticks); a deps token on a line with no ID; a dep on an unknown ID; a
dependency cycle. `archive-initiative.sh --check` validates well-formedness
(the first four); the resolver owns dep semantics (unknown ID + cycle — the
whole semantic set since [7.6] repealed the forward-cross-phase-dep rule).

**Append-only mutation rules:**

- Every mutation of a live tracker goes through `/guv:replan`, the single
  sanctioned door (classify → confirm → REQUIREMENTS first, tracker synced
  verbatim → amendment record); its deterministic half is
  `"${CLAUDE_PLUGIN_ROOT}"/scripts/replan.sh`. No hand edit of a live tracker is legitimate.
- Completed phases are immutable; ordinals are never reused or reshuffled.
  Immutability is phase-grained: a ✅ deliverable in an *open* phase may still
  be reworded (the amendment record keeps the audit trail) but never descoped;
  its wording freezes when its phase completes.
- A phase with all deliverables ✅/❌ auto-tallies complete — *except* a
  **lone-deliverable phase**, which stays mutable so a **spike-gated phase**
  (one gating spike flipped ✅ before its gated build set is groomed in) does
  not freeze and strand the build set ([15.7], lived in [14.1]→[14.2]–[14.6]).
  Groom the gated build set in behind the spike (`insert`), and the phase
  tallies on its own once it holds ≥2 done deliverables. A genuinely-finished
  *single*-deliverable phase is sealed deliberately by the explicit
  **phase-close** step (`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/replan.sh phase-close <session> <phase>`),
  recorded as `> - DATE — phase-close [N] (session)` — distinct from the
  auto-tally, refused while the phase has open work (Rule 15: the designed seal,
  never a silent strand).
- Insert appends the next ordinal at the end of its phase (max+1 discipline) —
  deps express its logical position, not list placement.
- Descope marks the line ❌ with a dated note; the line survives. Deletion
  does not exist.

**Amendment records:** every mutation appends one record line to the tracker
header — into a `> **Amendments:**` block at the end of the header
blockquote, created on first use:

```markdown
> **Amendments:**
> - YYYY-MM-DD — OP [N.M] (session-YYYY-MM-DD-NNN) — detail
```

`OP` is the `/guv:replan` verb (reorder, split, merge, insert, descope, abandon,
deps-amend); composed verbs leave one record per primitive engine call, each
under the verb. The detail is op-specific (the descope note; the old → new
deps diff). Records use plain bracketed IDs — no bold, no deps shape — so
they are inert to the parse rules above; they are header-local and never
sync to REQUIREMENTS. Being outside the verbatim-sync contract also bounds
the no-hand-edit rule: deliverable lines are engine-only, but correcting the
*content* of an engine-written record (a wrong or under-telling detail) is a
disclosed manual act — say so in the commit, in the session that wrote it.

### Resolver contract

`"${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh` computes the ready frontier from a tracker
(`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh [tracker-path]`, default
`docs/PHASE_STATUS.md`). This section is the contract its consumers (entry
split, lane dispatch, status render) program against.

- **Output**, name=value, one per line:
  - `mode=GRAMMAR|LEGACY`
  - `phase=N` — the first phase with open work (⬜, 🔄, or 🔒) — reporting
    only, never gates dispatch ([7.6]); GRAMMAR only
  - `in_progress=` — 🔄 IDs in document order (finish before starting new
    work, wherever the in-flight item sits)
  - `ready=` — every ⬜ whose deps are all ✅ — document order, across ALL
    phases ([7.6]: deps are the only ordering; the phase barrier stopped
    gating dispatch; phases remain the unit of narrative, review, and UAT)
  - `blocked=` — every open ⬜ with an unsatisfied dep, as `ID:ROOT`, where
    ROOT is the transitive blocking ID (the deepest unsatisfied dep that is
    itself ready, in progress, ❌, or 🔒 — each propagates blockage)
  - `serial=` — first 🔄, else first ready item
- **🔒 human-gated ([10.1]):** the resolver RECOGNIZES the fifth marker — a 🔒
  line is parsed, surfaces in `--json` as `status="human_gated"`, counts as open
  work in `phase=`, and is a valid dep target (a ⬜ depending on a 🔒 ID is
  `blocked` with the 🔒 named as ROOT, not a MALFORMED crash) — so a 🔒
  deliverable is never silently dropped. It is **open-but-non-dispatchable**:
  never listed in `ready=` (a person gates it, not a dep) and never the subject
  of `blocked=`. The full ready-vs-blocked frontier semantics for 🔒 (a distinct
  frontier bucket? a `serial=` posture?) are a **deliberate follow-on** — this
  contract fixes only that 🔒 is visible, never vanishing from the parse, JSON,
  or counts.
- **Exit codes:** 0 resolved (a complete tracker resolves to an empty
  frontier — a resting state, not an error) · 2 usage (unknown argument,
  or `--json` without jq) · 4 no tracker · 5 on any
  MALFORMED condition above (unknown ID, duplicate ID, cycle, missing
  token, or a tracker with no deliverable bullets at all), naming the
  offenders on stderr.
- **LEGACY mode:** no IDs exist, so `serial=` carries the line *text* —
  first 🔄's, else first ⬜'s (finish before start) — and `ready=`,
  `in_progress=`, and `blocked=` are all emitted explicitly empty (nothing
  to list IDs for; an in-flight line surfaces via `serial=`). Only `phase=`
  is absent (GRAMMAR-only, as above).
- Pure bash plus standard Unix text tools (grep, sed, sort, uniq, head,
  tail) — no jq needed for the name=value output (`--json` adds jq); runs on
  stock macOS bash 3.2. The parse (lead-position IDs,
  last-construct deps token, comma-space separator) is the same grammar
  `archive-initiative.sh` enforces — one dialect, with the shared deps-token
  regex guarded identical to the skill's quoted copy by `grammar-surface.test.sh`.

### status.json shape

`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh [tracker-path] --json` emits the same parse and
frontier as one canonical JSON document. This shape is **published contract
surface** alongside the tracker grammar and the manifest schema (the A-001
one-parser decision): the resolver is the grammar's only implementation, and
every other reader of plan state — the status renderer first, external tools
later — consumes this JSON and never parses the tracker. Changing the shape
pays contract cost.

**Contract version ([10.1]):** the shape carries a `contract_version` integer
(currently `2`) as its leading field — the single negotiation surface a
breaking change has with external consumers. It is the published surface's
version marker, the same number documented in the JSON example below and
emitted by `resolve-ready.sh --json`; the tracker grammar and the status.json
shape version together (one parser, one version). A semantic-only change (like
[7.6]'s frontier widening) does **not** bump it — only a breaking shape or
grammar change does, at which point the bump is the consumer's signal to
re-read. The downstream manifest contract change (the multi-repo `roots.code`
map — [11.2]) took the first bump on this marker, `1` → `2`: `roots.code`
became a string-or-named-map (a string is the single-repo shorthand), a
breaking manifest-contract change the published-contract family versions
through this one number.

[7.6] changed frontier *semantics* with the shape structurally unchanged:
`ready`/`blocked` widened from current-phase to all phases, and `phase`
demoted to reporting (first phase with open work). Recorded here — and as a
data point on the parked `grammar-version` entry — rather than as a version
bump: same fields, same types, different meaning.

The Phase-9 governor shapes join this published-contract family and are each
documented beside their own helper, cross-referenced here so the surfaces are
discoverable from one place: the cost-and-performance **metering log**
(`.claude/metering-log.md`, written by `meter.sh` — [9.1]) and the **estimate
sidecar** (`"${CLAUDE_PLUGIN_ROOT}"/scripts/estimate.shape.md`, keyed by deliverable ID via
`estimate.sh` — [9.6]). Same one-parser discipline: consumers read the
documented shape, never re-derive it.

```json
{
  "contract_version": 2,                    // published-surface version ([10.1]);
                                            //   bump only on a breaking shape or
                                            //   grammar change — the negotiation
                                            //   surface for external consumers
                                            //   (v2: [11.2] roots.code named map)
  "generated": "2026-06-12T14:57:21Z",      // ISO-8601 UTC stamp
  "mode": "GRAMMAR",                        // or "LEGACY"
  "phase": 6,                               // first open phase (reporting only);
                                            //   null when none open
  "phases": [6, 7, 8],                      // phase boundaries, document order
  "deliverables": [                         // document order
    { "id": "6.4",                          // null in LEGACY (no IDs exist)
      "phase": 6,                           // null in LEGACY
      "status": "done",                     // done | in_progress | todo | descoped
                                            //   | human_gated (🔒, [10.1])
      "deps": ["6.1", "6.3"],               // always [] in LEGACY — empty edges,
                                            //   never invented from document order
      "text": "wording after the marker, verbatim (deps token included)" }
  ],
  "frontier": {                             // field-for-field the shell output
    "in_progress": [],                      // 🔄 IDs, unscoped
    "ready": ["6.6"],                       // dispatchable ⬜, all phases ([7.6])
    "blocked": [ { "id": "6.5", "blocked_by": "6.6" } ],
    "serial": "6.6"                         // null when the tracker is complete;
                                            //   line TEXT in LEGACY mode
  }
}
```

Exit codes and stderr are identical in both output modes — MALFORMED is
MALFORMED regardless of how the answer would have been formatted — with one
mode-specific exception: a missing jq refuses exit 2 under `--json` before any
resolving (the name=value path stays jq-free). Status words never carry emoji;
the markers stay a tracker-surface concern. `phases` is derived from
deliverable IDs, so a phase section that currently has no deliverable lines
does not appear, and phase *goal* lines are not carried — the JSON serializes
the dependency graph, not the tracker's prose.

## Spec provenance

When a source spec is copied into the repo, write it to `docs/spec/<original-name>.md`
(NOT `docs/REQUIREMENTS.md` — generated docs must never be mistaken for, or overwrite,
the source). Stamp a provenance header at the top: source path/URL, ingestion date, and a
one-line note that it is the immutable source the generated docs derive from.

## Initiative lineage & archival

These conventions apply when a project runs more than one phased initiative over its
life (the `/guv:plan` path). The three docs have different lifecycles:

| Doc | Describes | Lifecycle |
| --- | --- | --- |
| REQUIREMENTS.md + PHASE_STATUS.md | **work** | complete → frozen in `docs/initiatives/` |
| ARCHITECTURE.md | **the system** | persists at top level, revised in place |
| docs/sessions/, docs/spec/, feedback log | the journal / sources | **never archived** |

- **Archive layout:** a completed (or explicitly abandoned) initiative's
  REQUIREMENTS + PHASE_STATUS pair moves to `docs/initiatives/NNN-<kebab-name>/`,
  frozen — never edited again. An ARCHITECTURE snapshot may be copied alongside.
  The scriptable half (completeness check, move, numbering, abandonment stamp) is
  `"${CLAUDE_PLUGIN_ROOT}"/scripts/archive-initiative.sh` — use it rather than hand-moving files.
- **Continuous phase numbering:** the next initiative's first phase is
  (highest phase number ever used) + 1, across all archived initiatives. A project whose
  greenfield build ended at Phase 5 starts its next initiative at Phase 6. This keeps
  every historical reference globally unique forever — handoff `Phase:` fields,
  `phase/N-*` branches, and `docs/uat/phase-N-*` artifacts never collide.
- **Lineage header** (top of every initiative-generated REQUIREMENTS.md, directly under
  the title):

  ```markdown
  > **Lineage:** Phases 1–5 — greenfield build, archived at `docs/initiatives/001-greenfield/`.
  > **This initiative:** Phases 6–8 — governed by `docs/spec/<name>.md`.
  ```

  One `Phases A–B` line per prior initiative, in order. **A project's first initiative
  (nothing archived yet) still writes the header** — just the "This initiative:" line,
  no lineage lines — because `/guv:phase`'s governing-spec resolution and `/guv:status`'s
  Initiative line both key off it. The **governing spec** named on the "This
  initiative" line is what `/guv:phase`'s spec-alignment check targets — specs
  accumulate in `docs/spec/`, and this line is what disambiguates them.
- **One active initiative at a time:** generators must refuse to start a new initiative
  while the current tracker has incomplete deliverables. Abandonment is explicit:
  archive with the incomplete status noted (`--force` stamps the ABANDONED line) —
  an honest record, not deletion.
