---
name: phase-docs
description: Shared templates and rules for generating the three phase docs (REQUIREMENTS, ARCHITECTURE, PHASE_STATUS) plus initiative lineage and archival conventions. Referenced by /guv:init-project (greenfield) and /guv:plan-initiative (existing project) so the structures live once. Not a workflow — a reference.
user-invocable: false
---

# Phase Docs — Shared Structures & Rules

Both generators (`/guv:init-project` for greenfield, `/guv:plan-initiative` for an initiative on
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
- All items start as ⬜ (markers: ✅ complete · 🔄 in progress · ⬜ not started · ❌ blocked)
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

**Semantics:**

- Deps tokens encode "must follow"; document order is presentation only.
  A deliverable is *ready* when every ID in its deps token is ✅.
- Phases coarse-gate; deps refine within a phase. Backward cross-phase deps are
  legal (a ❌ prior-phase item propagates blockage). Forward cross-phase deps
  are MALFORMED — they mean the phasing is wrong, and tooling must not paper
  over that.
- Deps live in the deliverable's wording, never in the annotation zone — they
  sync verbatim, and dep changes happen in REQUIREMENTS first like any other
  wording change.

**LEGACY:** a tracker with no IDs and no deps tokens is LEGACY — document
order encodes dependency order (the original semantics, exactly), the first ⬜
in document order is next, and there is no parallel set. Old initiatives are
never misread; the grammar is opt-in by annotation. Mixing is MALFORMED: once
any line carries a token, every line must.

**MALFORMED (fail loud, exit 5 in tooling):** duplicate IDs; an ID'd line
missing its deps token; a malformed token (empty list, unknown format, missing
backticks); a deps token on a line with no ID; a forward cross-phase dep;
a dep on an unknown ID; a dependency cycle. `archive-initiative.sh --check`
validates well-formedness (the first four); the resolver owns dep semantics
(the rest).

**Append-only mutation rules:**

- Completed phases are immutable; ordinals are never reused or reshuffled.
- Insert appends the next ordinal at the end of its phase (max+1 discipline) —
  deps express its logical position, not list placement.
- Descope marks the line ❌ with a dated note; the line survives. Deletion
  does not exist.

### Resolver contract

`"${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh` computes the ready frontier from a tracker
(`bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh [tracker-path]`, default
`docs/PHASE_STATUS.md`). This section is the contract its consumers (entry
split, lane dispatch, status render) program against.

- **Output**, name=value, one per line:
  - `mode=GRAMMAR|LEGACY`
  - `phase=N` — current phase: the first phase with a ⬜ or 🔄 (GRAMMAR only)
  - `in_progress=` — 🔄 IDs in document order (finish before starting new
    work; unscoped, so an in-flight later-phase item still surfaces)
  - `ready=` — every current-phase ⬜ whose deps are all ✅, document order
  - `blocked=` — current-phase ⬜ entries as `ID:ROOT`, where ROOT is the
    transitive blocking ID (the deepest unsatisfied dep that is itself
    ready, in progress, or ❌ — a ❌ propagates blockage)
  - `serial=` — first 🔄, else first ready item
- **Exit codes:** 0 resolved (a complete tracker resolves to an empty
  frontier — a resting state, not an error) · 4 no tracker · 5 on any
  MALFORMED condition above (unknown ID, duplicate ID, cycle, missing
  token, forward cross-phase dep, or a tracker with no deliverable bullets
  at all), naming the offenders on stderr.
- **LEGACY mode:** no IDs exist, so `serial=` carries the line *text* —
  first 🔄's, else first ⬜'s (finish before start) — and `ready=`,
  `in_progress=`, and `blocked=` are all emitted explicitly empty (nothing
  to list IDs for; an in-flight line surfaces via `serial=`). Only `phase=`
  is absent (GRAMMAR-only, as above).
- Pure bash plus standard Unix text tools (grep, sed, sort, uniq, head,
  tail) — no jq needed; runs on stock macOS bash 3.2. The parse (lead-position IDs,
  last-construct deps token, comma-space separator) is the same grammar
  `archive-initiative.sh` enforces — one dialect, with the shared ID/token
  regexes guarded identical by the resolver's suite.

## Spec provenance

When a source spec is copied into the repo, write it to `docs/spec/<original-name>.md`
(NOT `docs/REQUIREMENTS.md` — generated docs must never be mistaken for, or overwrite,
the source). Stamp a provenance header at the top: source path/URL, ingestion date, and a
one-line note that it is the immutable source the generated docs derive from.

## Initiative lineage & archival

These conventions apply when a project runs more than one phased initiative over its
life (the `/guv:plan-initiative` path). The three docs have different lifecycles:

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
  no lineage lines — because `/guv:start-phase`'s governing-spec resolution and `/guv:status`'s
  Initiative line both key off it. The **governing spec** named on the "This
  initiative" line is what `/guv:start-phase`'s spec-alignment check targets — specs
  accumulate in `docs/spec/`, and this line is what disambiguates them.
- **One active initiative at a time:** generators must refuse to start a new initiative
  while the current tracker has incomplete deliverables. Abandonment is explicit:
  archive with the incomplete status noted (`--force` stamps the ABANDONED line) —
  an honest record, not deletion.
