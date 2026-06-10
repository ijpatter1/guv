# Engineering Rules — Behavioral Core

How an agent should *think and act* on this codebase. These rules are stack- and
task-agnostic, so they live in one place and are imported by every project's
`CLAUDE.md` (and may also sit at `~/.claude/CLAUDE.md` to apply globally).

Three layers, three jobs — don't confuse them:

- **These rules** govern *judgment* — the calls you make in the moment.
- **The commands** (`/start-phase`, `/task`, `/handoff`, …) govern *process* — repeatable workflows. When a command gives numbered steps, follow them; Rule 4 is about tasks the commands *don't* script, not a license to skip a command's procedure.
- **The hooks** (bash-guard, auto-format, stop-check) and the **evaluator / product-reviewer** enforce *invariants* deterministically. Where a hook already guarantees something, these rules don't restate it — they cover what enforcement can't.

Bias: caution over speed on non-trivial work; use judgment on trivial work.

---

## 1 — Think before coding
State assumptions out loud. When the request is ambiguous, present the interpretations rather than silently picking one. Push back when a simpler approach exists. When you're confused, stop and name what's unclear instead of guessing forward.

## 2 — Scope your changes to the task tier
Match the size of the change to the size of the task. A bug fix is surgical; a greenfield deliverable where the abstraction *is* the work is structural. The manifest's `ceremony` (`task` / `onboard` / `phased`) tells you which you're in — `task` means minimal and contained, `phased` means building structure is legitimate. Don't bring phased-scale architecture to a one-line fix, or one-line thinking to a foundational build.

## 3 — Simplicity first
Write the minimum that solves the problem. No speculative features, no abstractions for single-use code. Test: would a senior engineer call this overcomplicated? If yes, cut it. This also applies to reacting to review feedback — a reviewer asked to find gaps will find some; adding defensive layers and tests for impossible cases is its own failure.

## 4 — Surgical changes
Touch only what the task requires. Don't "improve" adjacent code, comments, or formatting on the way past. Don't refactor what isn't broken. Match the surrounding style even where it isn't your preference.

## 5 — Read before you write
Before adding code, read the exports you'll touch, the immediate callers, and the shared utilities involved. "Looks orthogonal" is where regressions hide. If you can't explain why existing code is structured the way it is, find out before changing it.

## 6 — Match the codebase's conventions, even if you disagree
Inside a codebase, conformance beats taste. This matters most when adopting an existing repo (`/onboard`): infer and follow what's there, don't impose a fresh style. If a convention is genuinely harmful, surface it — don't fork it silently.

## 7 — Surface conflicts, don't average them
When two patterns contradict, pick one — the more recent or better-tested — say why, and flag the other for cleanup. Blending two conflicting approaches produces something that follows neither and confuses the next reader.

## 8 — Tests verify intent, not just behavior
A test should encode *why* the behavior matters, not merely *what* the code currently does. A test that can't fail when the business logic changes is testing nothing. This is the standard the evaluator grades against — shallow "renders without crashing" tests score as untested.

## 9 — Give yourself a check, and show the evidence
Define what "done" means as something you can verify — a passing test, a clean build, a diffed output, a screenshot — then loop until it holds. Don't assert success; show the check you ran and what it returned. If you can't verify it, you're not done, and you say so.

## 10 — Fail loud
"Completed" is false if anything was skipped silently. "Tests pass" is false if any were skipped or stubbed. If you cut a corner, hit a wall, or made a tradeoff you're unsure about, surface it — in the response and in the session handoff. Hidden uncertainty is the most expensive kind. (The stop-check hook and the evaluator are the deterministic backstop; this rule is your half of it.)

## 11 — Manage context deliberately
Context is the scarce resource and performance degrades as it fills. Don't let an investigation balloon the working set — delegate wide reads to a subagent and keep only the findings. Checkpoint after each meaningful step: be able to state what's done, what's verified, and what's left. If you've lost the thread, stop and restate rather than building on a state you can't describe.

## 12 — Use the model only for judgment calls
This one is about *what you build*, not how you behave. Reach for an LLM where judgment is required — classification, drafting, summarization, extraction. Do not put one in the loop for routing, retries, or deterministic transforms. If code can answer deterministically, code answers — it's cheaper, faster, and testable.