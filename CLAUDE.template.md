# [PROJECT NAME]

> [One sentence: what this is, who it's for, what makes it distinctive.]

This file is deliberately short. It holds only what Claude **can't infer from the
code or the manifest**. Everything else is imported or referenced below — if a
fact lives somewhere more specific, it lives there, not here.

## How this project is wired

- **Behavior & conventions:** @.claude/RULES.md — the engineering rules that govern how you work. Always in effect.
- **Commands, stack, roots, ceremony, guards:** `.claude/project.json` — the single source of truth for *facts*. Read the test/build/lint/format/dev commands from there and run them; **never hardcode a command in this file or assume one**. A `null` command means the project has no such step — skip it, don't substitute a default.
- **Process commands:** `/task` (scoped change), `/onboard` (adopt an existing repo), `/init-project` (greenfield setup), then `/start-phase`, `/evaluate`, `/handoff`, `/status`, `/manual`. The commands carry the repeatable procedure; follow their steps.
- **Sometimes-relevant workflows & domain knowledge:** `.claude/skills/` — loaded on demand so they don't cost context every session.
- **Enforcement:** hooks (`bash-guard`, `auto-format`, `stop-check`) + the firewall + the sandbox are the real boundary. `settings.json` permissions are a convenience layer, not a security layer — the sandbox is the hard line.

## Where the code lives

Read `roots` from `.claude/project.json`:

- **Control plane** (your working directory): `roots.control`. Docs, session artifacts, and `.claude/` config live here.
- **Code**: `roots.code` — may be a *sibling repo*. All git operations against the product (`git -C roots.code log/diff/status`) target the code root; doc and session commits target the control root.
- **Single-repo projects** set both roots to `"."`, so the two collapse into one tree and nothing special happens.

## Ceremony — how much process applies

Read `ceremony` from the manifest:

- **`task`** — scoped work. No phase docs. Understand → TDD the change → evaluate → done.
- **`onboard`** — an existing repo whose conventions you *infer and follow*, never scaffold over.
- **`phased`** — greenfield with the full plan. The plan and live state are in `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, `docs/PHASE_STATUS.md`, and the latest `docs/sessions/` handoff. Work the current phase only.

A missing project-shape artifact is a *mode signal*, not an error: no phase docs means task/onboard mode, not a broken setup.

## Project facts Claude can't infer

[This is the heart of the file — the only content that truly belongs here. Fill in
the non-obvious, can't-read-from-code facts and delete the prompts. Keep each line
to the pruning test: *would removing it cause a mistake?* If not, cut it.]

- **Stack quirks / required env vars:** [e.g. "DATABASE_URL must be set or the test runner silently uses prod"]
- **Non-obvious behaviors / gotchas:** [e.g. "the auth middleware short-circuits in dev mode; tests must set NODE_ENV=test"]
- **Architectural decisions specific to this project:** [e.g. "events are append-only — never mutate, emit a correction"]
- **Repository etiquette beyond the defaults:** [branch naming, PR conventions, anything non-standard]

## What is intentionally NOT in this file

So future edits don't drift it back toward bloat:

- **Commands** → `.claude/project.json`. Never restated here.
- **Behavior, TDD discipline, commit conventions, "write clean code"** → `@.claude/RULES.md`. Standard conventions Claude already knows are omitted entirely.
- **Directory-by-directory tours, API docs, tutorials** → the code is the source; link to real docs if needed.

## Bootstrapping (first session, `phased` greenfield only)

If `scaffoldCheck` from the manifest fails, the project isn't scaffolded yet — that's expected on the first session, and scaffolding is the first deliverable. Configure the test runner, linter, and formatter (the auto-format hook needs a formatter present), wire the `commands` in the manifest, and land at least one passing test to set the baseline. Remove this section once the project is scaffolded.