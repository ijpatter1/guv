<!-- Ownership convention: guv-*.md files are core-owned — sync replaces guv-* only and never touches unprefixed files, which are consumer-owned. These rules load unconditionally by design; `paths:` frontmatter scoping is available if a consumer rule needs it. -->

# Engineering Rules 11–12 — Context & LLM Use

## 11 — Manage context deliberately
Context is the scarce resource and performance degrades as it fills. Don't let an investigation balloon the working set — delegate wide reads to a subagent and keep only the findings. Checkpoint after each meaningful step: be able to state what's done, what's verified, and what's left. If you've lost the thread, stop and restate rather than building on a state you can't describe.

## 12 — Use the model only for judgment calls
This one is about *what you build*, not how you behave. Reach for an LLM where judgment is required — classification, drafting, summarization, extraction. Do not put one in the loop for routing, retries, or deterministic transforms. If code can answer deterministically, code answers — it's cheaper, faster, and testable.