---
name: phase-docs
description: Shared templates and rules for generating the three phase docs (REQUIREMENTS, ARCHITECTURE, PHASE_STATUS) plus initiative lineage and archival conventions. Referenced by /init-project (greenfield) and /plan-initiative (existing project) so the structures live once. Not a workflow — a reference.
user-invocable: false
---

# Phase Docs — Shared Structures & Rules

Both generators (`/init-project` for greenfield, `/plan-initiative` for an initiative on
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

1. [Specific, measurable deliverable]
2. [Another deliverable]

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

- ⬜ [Deliverable 1 — exact wording from REQUIREMENTS.md]
- ⬜ [Deliverable 2 — exact wording from REQUIREMENTS.md]

---

[Repeat for all phases]
```

Rules (the verbatim-sync contract):

- Every deliverable line must be copied verbatim from REQUIREMENTS.md
- All items start as ⬜ (markers: ✅ complete · 🔄 in progress · ⬜ not started · ❌ blocked)
- Do not add, remove, or reword any deliverables — the tracker and REQUIREMENTS must
  match exactly, forever; wording changes happen in REQUIREMENTS first and sync here

## Spec provenance

When a source spec is copied into the repo, write it to `docs/spec/<original-name>.md`
(NOT `docs/REQUIREMENTS.md` — generated docs must never be mistaken for, or overwrite,
the source). Stamp a provenance header at the top: source path/URL, ingestion date, and a
one-line note that it is the immutable source the generated docs derive from.

## Initiative lineage & archival

These conventions apply when a project runs more than one phased initiative over its
life (the `/plan-initiative` path). The three docs have different lifecycles:

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
  no lineage lines — because `/start-phase`'s governing-spec resolution and `/status`'s
  Initiative line both key off it. The **governing spec** named on the "This
  initiative" line is what `/start-phase`'s spec-alignment check targets — specs
  accumulate in `docs/spec/`, and this line is what disambiguates them.
- **One active initiative at a time:** generators must refuse to start a new initiative
  while the current tracker has incomplete deliverables. Abandonment is explicit:
  archive with the incomplete status noted (`--force` stamps the ABANDONED line) —
  an honest record, not deletion.
