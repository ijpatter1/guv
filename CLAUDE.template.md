<!--
═══════════════════════════════════════════════════════════════════════════
  TEMPLATE — not a live file. Named `CLAUDE.template.md`, NOT `CLAUDE.md`,
  so Claude Code does not auto-load it. That is deliberate: the agent working
  on this template repo should be governed by the migration plan, not by
  consumer-project instructions.

  This becomes a real project's CLAUDE.md only when a generator renders it:
    /init          — greenfield; keeps the Bootstrapping section
    /onboard       — existing repo; omits the Bootstrapping section

  RENDER STEP (for the generator):
    1. Fill the placeholders: project identity (top), "Project facts Claude
       can't infer", and — for /init only — "Bootstrapping".
    2. Leave the manifest pointers as-is (behavioral rules load natively
       from .claude/rules/ — no import line needed).
    3. Write the result to ${roots.control}/CLAUDE.md (cwd auto-loads it).
    4. Strip this comment block — it has no meaning in a live CLAUDE.md.
═══════════════════════════════════════════════════════════════════════════
-->

# [PROJECT NAME]

> [One sentence: what this is, who it's for, what makes it distinctive.]

This file is deliberately short. It holds only what Claude **can't infer from the
code or the manifest**. Everything else is imported or referenced below — if a
fact lives somewhere more specific, it lives there, not here.

## How this project is wired

- **Behavior & conventions:** `.claude/rules/guv-*.md` — the engineering rules that govern how you work, loaded natively every session. Always in effect. Add project-specific rules as unprefixed files alongside; sync replaces `guv-*` only.
- **Memory authority:** the manifest and the latest session handoff are authoritative; treat auto memory as hints and never let it override either.
- **Commands, stack, roots, ceremony, guards:** `.claude/project.json` — the single source of truth for _facts_. Read the test/build/lint/format/dev commands from there and run them; **never hardcode a command in this file or assume one**. A `null` command means the project has no such step — skip it, don't substitute a default.
- **Process commands:** `/task` (scoped change), `/onboard` (adopt an existing repo), `/init` (greenfield setup), `/plan` (multi-phase initiative on an existing project), then `/phase` (phase-boundary entry), `/next` (light daily/mid-phase resume), `/replan` (plan mutation — the one sanctioned door), `/eval`, `/handoff`, `/status`, `/manual`. The commands carry the repeatable procedure; follow their steps. (Installed as the guv plugin, every name carries the namespace: `/guv:task`, `/guv:handoff`, ….)
- **Sometimes-relevant workflows & domain knowledge:** skills, loaded on demand so they don't cost context every session — in project `.claude/skills/` (template install) or shipped inside the guv plugin.
- **Execution at scale:** the planning layer is the phase docs and the commands; the execution layer is the model, subagents, and — for wide mechanical fan-out — workflows you save in project `.claude/workflows/` (none ship with guv since [32.3]). Workflow QA gates use the platform review plus the `reviewer` by name, and ultracode is fan-out-only, dropped back after (`.claude/rules/guv-workflows.md`).
- **Enforcement:** the isolation tier (native sandbox by default; Docker sandbox + firewall opt-in) is the spatial boundary, and the hooks (`bash-guard`, `auto-format`, `stop-check`) are the semantic layer within it. `settings.json` permissions are a convenience layer, not a security layer — the isolation tier is the hard line.

## Where the code lives

Read `roots` from `.claude/project.json`:

- **Control plane** (your working directory): `roots.control`. Docs, session artifacts, and `.claude/` config live here.
- **Code**: `roots.code` — may be a _sibling repo_. All git operations against the product (`git -C roots.code log/diff/status`) target the code root; doc and session commits target the control root.
- **Single-repo projects** set both roots to `"."`, so the two collapse into one tree and nothing special happens.

**Naming convention (split topology):** the code repo keeps the plain product name; the control plane is its sibling named per the `<project>-guv` convention (here `<product>-guv`) — a possessive suffix (the product's guv), human-facing only: no script ever discovers a control plane by name; the manifest's `roots` is the sole machine pointer. The manifest's `name` stays the _product_ name (it feeds image/container labels), not the directory name.

```
~/dev/
├── <product>/        # code repo (roots.code: "../<product>")
└── <product>-guv/    # control plane — Claude launches here (cwd, roots.control: ".")
```

Single-repo projects don't name a control plane at all — the product repo is the only repo.

## Ceremony — how much process applies

Read `ceremony` from the manifest:

- **`task`** — scoped work. No phase docs. Understand → TDD the change → evaluate → done.
- **`onboard`** — an existing repo whose conventions you _infer and follow_, never scaffold over.
- **`phased`** — greenfield with the full plan. The plan and live state are in `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, `docs/PHASE_STATUS.md`, and the latest `docs/sessions/` handoff. Work the resolver's frontier (`bash .claude/resolve-ready.sh`) — dispatch is deps-only, and a later-phase item in `ready=` is legitimate; phases remain the unit of narrative, review, and UAT.

A missing project-shape artifact is a _mode signal_, not an error: no phase docs means task/onboard mode, not a broken setup.

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
- **Behavior, TDD discipline, commit conventions, "write clean code"** → `.claude/rules/`. Standard conventions Claude already knows are omitted entirely.
- **Directory-by-directory tours, API docs, tutorials** → the code is the source; link to real docs if needed.

## Bootstrapping (first session, `phased` greenfield only)

If `scaffoldCheck` from the manifest fails, the project isn't scaffolded yet — that's expected on the first session, and scaffolding is the first deliverable. Configure the test runner, linter, and formatter (the auto-format hook needs a formatter present), wire the `commands` in the manifest, and land at least one passing test to set the baseline. Remove this section once the project is scaffolded.
