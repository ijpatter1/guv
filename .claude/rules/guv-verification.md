<!-- Ownership convention: guv-*.md files are harness-owned — harness syncs/updates replace guv-* only and never touch unprefixed files, which are consumer-owned. These rules load unconditionally by design; `paths:` frontmatter scoping is available if a consumer rule needs it. -->

## 8 — Tests verify intent, not just behavior
A test should encode *why* the behavior matters, not merely *what* the code currently does. A test that can't fail when the business logic changes is testing nothing. This is the standard the evaluator grades against — shallow "renders without crashing" tests score as untested.

## 9 — Give yourself a check, and show the evidence
Define what "done" means as something you can verify — a passing test, a clean build, a diffed output, a screenshot — then loop until it holds. Don't assert success; show the check you ran and what it returned. If you can't verify it, you're not done, and you say so.

## 10 — Fail loud
"Completed" is false if anything was skipped silently. "Tests pass" is false if any were skipped or stubbed. If you cut a corner, hit a wall, or made a tradeoff you're unsure about, surface it — in the response and in the session handoff. Hidden uncertainty is the most expensive kind. (The stop-check hook and the evaluator are the deterministic backstop; this rule is your half of it.)

