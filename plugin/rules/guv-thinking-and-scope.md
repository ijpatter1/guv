<!-- Ownership convention: guv-*.md files are harness-owned — harness syncs/updates replace guv-* only and never touch unprefixed files, which are consumer-owned. These rules load unconditionally by design; `paths:` frontmatter scoping is available if a consumer rule needs it. -->

# Engineering Rules — Behavioral Core

How an agent should *think and act* on this codebase. These rules are stack- and
task-agnostic, so they ship as the harness-owned `guv-*` files in `.claude/rules/`,
loaded natively every session (project-specific rules go in unprefixed files alongside).

Three layers, three jobs — don't confuse them:

- **These rules** govern *judgment* — the calls you make in the moment.
- **The commands** (`/phase`, `/task`, `/handoff`, … — `/guv:`-namespaced under a plugin install) govern *process* — repeatable workflows. When a command gives numbered steps, follow them; Rule 4 is about tasks the commands *don't* script, not a license to skip a command's procedure.
- **The hooks** (bash-guard, auto-format, stop-check) and the **evaluator / reviewer** enforce *invariants* deterministically. Where a hook already guarantees something, these rules don't restate it — they cover what enforcement can't.

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

