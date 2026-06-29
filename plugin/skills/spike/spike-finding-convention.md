# The spike-finding convention

A spike's value is its **finding** — and a finding only outlives the spike if it is
legible to the next reader. This convention fixes the **shape** a spike finding takes:
which sections, in what order. It is the shape a three-spike road-test in guv's own
development converged on (the shape emerged across three successive spikes, then was
codified here as the standing convention). Follow it when you write a spike finding to
`docs/spikes/` — the `/guv:spike` skill's close (Step 5) points here for exactly that.

It is a **convention, not a gate**: nothing enforces it mechanically. Its discipline is
that a finding written to this shape is one a person can act on without re-deriving it.

## The shape — seven parts, in order

A spike finding has these parts, in order. The order is the contract: a question's
Decision should be readable before the next question opens, and the failure paths
belong gathered in one place rather than scattered.

## 1. Header block

Deliverable / phase / initiative / spec refs; a **Status** line (DRAFTED → RATIFIED,
naming the ratifying session — see the status convention below); and a one-line note
placing the finding in its lineage.

## 2. Why this spike exists

The gap, in one or two paragraphs — what is missing, the **originating requirement or
spec gap** the spike traces to, and the motivating evidence (cite `file:line` where the
claim is about code). State what the spike does **not** do: a spike composes existing
primitives and answers a question; it does not re-implement.

## 3. Name the asymmetry up front

A short framing section that names the distinction the per-question decisions fall out
of (each road-test finding opened by naming a two-layer asymmetry — scope-knowing vs
scope-discovering, two artifact classes, and so on). **Optional but load-bearing where
it applies:** naming the asymmetry up front makes the per-question decisions *obvious*
instead of argued. This is one of the two refinements the road-test added (see below).

## 4. Per-question sections — Evidence → Decision

One section per open question (Q1, Q2, …). Each runs **Evidence → Decision**:

- **Evidence** — what already exists, cited `file:line` where it is a code claim.
- **Decision** — rendered one of two ways, by the question's nature:
  - an **Options table** where the question is a **fork** — a small set of
    mutually-exclusive choices, each carrying a verdict; or
  - **prose** where the question is a **composition or placement** ("where does this
    live", "which rung", "how do these compose"). Forcing a verdict table onto a
    composition/placement question reads worse than prose. This is the second of the
    two refinements (see below).

## 5. Designed default + loud path

One section gathering the **designed default** and every **loud / degraded path** — the
Rule 15 failure behavior in one legible place, rather than smeared across the
per-question sections. Failure selects a written-down path; a finding makes those paths
visible at a glance.

## 6. What this spike gates

The build set, named concretely for `/guv:replan insert` — each item with a *candidate*
size (a hint, ratified at the insert gate, not binding here) and an explicit
split / no-split call. A finding that gates build work owes its build set here; a
**terminal** finding (nothing to build) says so and stops.

## 7. Build-time refinements & watch-items

What is deliberately left open (so the spike does not reopen at build time) and what the
builder must not get wrong (the correctness cores). This is where the finding hands the
builder its guardrails.

## The two refinements

Everything above is the shape the first spike proposed, with exactly two refinements the
later spikes added — and nothing else changed:

- **(a) Prose Decision where the question is a composition or placement; an Options
  table where it is a fork.** A fork wants a verdict per branch; a "where / which / how"
  question reads better argued in prose.
- **(b) An up-front asymmetry / two-layers framing** (part 3) that makes the per-question
  decisions fall out cleanly.

## Status convention

A spike finding is **DRAFTED** when authored (for instance, under an autonomous loop)
and **RATIFIED** when a maintainer accepts it at the confirm gate — at which point its
gated build set is groomed via `/guv:replan` and its gating deliverable flips ✅. A
**DRAFTED** finding never mutates plan state; **ratification is the gate between design
and build.** Record the transition on the Status line in the header block (part 1).
