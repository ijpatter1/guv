# Claude Code Development Environment

A ready-to-use development environment for autonomous Claude Code sessions with built-in QA evaluation, session management, and Docker sandboxing.

Based on patterns from [Anthropic's harness design research](https://www.anthropic.com/engineering/harness-design-long-running-apps) and [Simon Willison's Agentic Engineering Patterns](https://simonwillison.net/guides/agentic-engineering-patterns/).

## What's Included

**Entry points** — four ways in, scaled to the work:

- `/init-project <spec>` — greenfield: generate phase docs + manifest, render `CLAUDE.md`
- `/onboard` — adopt an existing repo: detect the stack, infer conventions, render `CLAUDE.md`, no phase ceremony
- `/task "<description>"` — scoped change: understand → red/green TDD → evaluate → done
- `/plan-initiative <spec>` — multi-phase initiative on an existing project: archive the prior initiative, generate fresh phase docs with continuous numbering, flip ceremony to `phased`

**Session workflow** — commands that encode a Planner → Generator → Evaluator loop (phased projects):

- `/start-phase N` — Load context, run tests, present a plan for approval
- `/evaluate` — Trigger independent dual QA review mid-session
- `/handoff` — End session with full QA + handoff artifact for continuity
- `/status` — Quick 10-line project orientation

**Manifest-driven** — `.claude/project.json` is the single source of truth for stack, commands, repo topology (`roots`), and ceremony. Hooks, commands, the sandbox, and the firewall all read from it, so there's nothing to drift. Behavioral rules live in `.claude/rules/` (`guv-*.md`, loaded natively).

**Repo topology** — single repo by default (`roots` both `"."`). For a control-plane / code split, Claude launches in the control plane and the product is a sibling repo. Convention: the code repo keeps the plain product name, the control plane is `<product>-control`, and the manifest's `name` stays the _product_ name (it feeds image/container labels):

```
~/dev/
├── <product>/           # code repo            → roots.code: "../<product>"
└── <product>-control/   # control plane (cwd)  → roots.control: "."
```

**QA evaluator subagent** — An independent, skeptical reviewer that grades work on five criteria (Functionality, Test Quality, Code Quality, Completeness, Integration). Runs in its own context window with read-only enforcement. Auto-invoked before every session handoff.

**Docker sandbox** — Isolated container for `--dangerously-skip-permissions` mode with iptables firewall, non-root execution, and domain allowlisting. Optional — works without Docker too.

**Safety hooks** — Deterministic enforcement of dangerous command blocking (bash-guard), auto-formatting (auto-format), and session reminder (stop-check).

**Session continuity** — Handoff artifacts and phase status tracking that carry context across sessions and context resets.

## Quick Start

### 1. Create a new repo from this template

Click **"Use this template"** on GitHub, or:

```bash
git clone https://github.com/YOUR_USERNAME/claude-code-env.git my-project
cd my-project
rm -rf .git && git init
```

### 2. Configure for your project

The fastest path — give Claude Code your spec:

```bash
# Start Claude Code (native or sandbox)
claude
# or: make sandbox

# Point it at your PRD/spec
/init-project path/to/your-spec.md
```

This reads your spec and generates the project-specific artifacts:

- `.claude/project.json` — the manifest: language, package manager, commands, roots, ceremony
- `CLAUDE.md` — **rendered from `CLAUDE.template.md`**, holding only the facts Claude can't infer (behavioral rules load natively from `.claude/rules/`; it points at the manifest for commands)
- `README.md` — **rendered from `README.template.md`** into a _project_-facing README (with a status block `/handoff` keeps current), replacing this harness README
- `docs/REQUIREMENTS.md` — phases and deliverables extracted from your spec
- `docs/ARCHITECTURE.md` — Phase 1 detailed architecture, later phases stubbed
- `docs/PHASE_STATUS.md` — deliverable tracker matching REQUIREMENTS.md

For an existing codebase, run `/onboard` instead — it detects the stack, infers the repo's conventions, writes the manifest, and renders `CLAUDE.md` **without** imposing phase structure.

Review the generated files, adjust anything that needs it, then commit and start building.

> **The template ships no `CLAUDE.md` — that's intentional.** `CLAUDE.md` auto-loads every session, so shipping one would govern the meta-work of _using_ the template. Instead the repo ships the inert `CLAUDE.template.md` (never auto-loaded) plus the `.claude/rules/` behavioral core; `/init-project` or `/onboard` _renders_ `CLAUDE.template.md` → `CLAUDE.md`. Consumers **must commit their rendered `CLAUDE.md`** — it is deliberately not gitignored.

**Manual alternative** — render the template by hand:

- **Copy** `CLAUDE.template.md` to `CLAUDE.md` (leave the template in place — it's the reusable source), then in the copy fill the project identity and the "Project facts Claude can't infer" section (for greenfield, keep "Bootstrapping") and strip the leading `<!-- TEMPLATE … -->` comment. Leave the manifest pointers as-is (rules load natively from `.claude/rules/`).
- **Copy** `README.template.md` to `README.md` (overwriting this harness README), fill the `[bracketed]` placeholders, keep the `<!-- STATUS:START/END -->` markers, and strip the `<!-- TEMPLATE … -->` comment.
- Edit `.claude/project.json` to declare your stack, commands, `roots`, `guards`, and `ceremony`.
- For phased projects, define `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, and `docs/PHASE_STATUS.md`.

Either way, also update:

- **`Makefile`** — Change `IMAGE_NAME` and `CONTAINER_NAME` at the top (two lines). The sandbox base image is derived from the manifest's `language`; override with `make build BASE_IMAGE=...`.

Optionally customize:

- **`sandbox/init-firewall.sh`** — Add project-specific domains to `PROJECT_DOMAINS` (the package registry is selected automatically from the manifest's `language`).
- **`.claude/project.json`** — Add stack-specific `guards` (e.g. `"gcp"`, `"cargo-publish"`); the universal danger blocks are always on. Permissions in `.claude/settings.json` are now a broad convenience layer, not a per-project edit point.

### 3. Set your API key

```bash
echo 'export ANTHROPIC_API_KEY=sk-ant-...' >> ~/.zshrc
source ~/.zshrc
```

### 4. Start coding

```bash
# Option A: Docker sandbox (autonomous, no permission prompts)
make sandbox

# Option B: Native Claude Code (interactive, with Remote Control)
claude
```

Then inside Claude Code:

```
/start-phase 1
```

### 5. Daily workflow

```bash
# Terminal 1: Claude Code
make sandbox
# /start-phase 1

# Terminal 2: Dev server on your Mac
make dev

# Terminal 3: Your tools (VS Code, git, tests)
code .
```

## File Structure

```
├── CLAUDE.template.md                 # Inert source for CLAUDE.md (rendered, not auto-loaded)
├── README.template.md                 # Inert source for the PROJECT README (rendered on scaffold/onboard)
├── Makefile                           # Container lifecycle (base image from manifest)
├── .gitignore                         # Git exclusions
├── .claude/
│   ├── project.json                   # MANIFEST — single source of truth (stack/commands/roots/ceremony)
│   ├── project.schema.json            # Manifest schema (validation + self-docs)
│   ├── rules/                         # Behavioral core (guv-*.md harness-owned; unprefixed = yours)
│   ├── resolve-stack.sh               # Detect-to-propose stack manifest (onboard/init)
│   ├── check-citations.sh             # Advisory: stale commit citations (split topology)
│   ├── update-readme-status.sh        # Maintains the README STATUS block in place
│   ├── archive-initiative.sh          # Freeze a finished initiative's phase docs (plan-initiative)
│   ├── settings.json                  # Permissions (convenience layer) + hooks
│   ├── settings.local.json            # Personal overrides (gitignored)
│   ├── agents/
│   │   ├── evaluator.md               # Technical QA evaluator subagent
│   │   └── product-reviewer.md        # Product reviewer subagent
│   ├── commands/
│   │   ├── init-project.md            # Greenfield: scaffold + render CLAUDE.md
│   │   ├── onboard.md                 # Adopt an existing repo (no phase ceremony)
│   │   ├── plan-initiative.md         # Phased initiative on an existing project
│   │   ├── start-phase.md             # Phased session initialization
│   │   ├── handoff.md                 # Session end + dual QA + handoff
│   │   ├── status.md                  # Quick status check
│   │   └── manual.md                  # Out-of-sandbox task artifacts
│   ├── hooks/
│   │   ├── bash-guard.sh              # Blocks dangerous commands (universal + opt-in guards)
│   │   ├── auto-format.sh             # Formats on write (formatter from manifest)
│   │   └── stop-check.sh              # Reminds about evaluation
│   ├── skills/
│   │   ├── task/                      # /task — scoped change entry point
│   │   ├── phase-docs/                # Shared phase-doc templates (init-project + plan-initiative)
│   │   ├── evaluate/                  # /evaluate — dual QA review
│   │   ├── log-feedback/              # /log-feedback — record harness friction
│   │   └── session-management/        # Context continuity conventions
│   ├── tests/                         # Bash test suites for the harness scripts/skills
│   └── feedback/                      # Harness-friction log (created on first /log-feedback)
├── maintainers/                       # Maintainer-only — developing the harness (consumers can delete)
│   ├── DOGFOODING.md                  # How to dogfood the harness via a control-plane split
│   └── setup-control-plane.sh         # Scaffold/sync a dogfooding control plane
├── docs/
│   ├── REQUIREMENTS.md                # Development plan (phased; YOU EDIT THIS)
│   ├── ARCHITECTURE.md                # Technical architecture (phased; YOU EDIT THIS)
│   ├── PHASE_STATUS.md                # Phase tracker (phased; YOU EDIT THIS)
│   └── sessions/
│       └── .gitkeep
└── sandbox/
    ├── Dockerfile                     # Sandbox image (BASE_IMAGE build arg)
    ├── init-firewall.sh               # Per-language registry allowlist firewall
    ├── entrypoint.sh                  # Privilege drop + Claude start
    └── README.md                      # Sandbox documentation
```

> A rendered `CLAUDE.md` (the live file) and `.claude/project.json` are created/filled per project by `/init-project` or `/onboard`. The template repo ships **no** `CLAUDE.md`.

The **durable core** — the `guv-*` rules in `.claude/rules/`, the manifest, the evaluator/reviewer, the universal hooks — is never edited per project. The **project shell** — the rendered `CLAUDE.md`, the manifest's values, phase docs (`YOU EDIT THIS`), and stack-specific guards/firewall additions — is filled per project. Same core, different shell.

## GCP Access (Optional)

If your project uses Google Cloud:

```bash
make gcp-setup    # Prints step-by-step instructions
```

## Commands Reference

| Command                | Description                              |
| ---------------------- | ---------------------------------------- |
| `make sandbox`         | Build + start Claude Code in Docker      |
| `make attach`          | Reattach to running sandbox after crash  |
| `make shell`           | Bash shell in sandbox for debugging      |
| `make prompt P="..."`  | Run a one-shot headless prompt           |
| `make resume S="name"` | Resume a named session                   |
| `make dev`             | Run dev server on host                   |
| `make stop`            | Stop the sandbox container               |
| `make clean`           | Remove container + image (keeps volumes) |
| `make clean-all`       | Full reset including auth and sessions   |
| `make gcp-setup`       | Print GCP service account instructions   |
| `make test-fw`         | Verify firewall blocks correctly         |

## Origins

This environment encodes three key patterns:

1. **Separated evaluation** (from [Anthropic's harness research](https://www.anthropic.com/engineering/harness-design-long-running-apps)) — The evaluator subagent runs in its own context with read-only access, preventing the self-praise problem where agents rate their own work too generously.

2. **Test-first anchoring** (from [Simon Willison's Agentic Engineering Patterns](https://simonwillison.net/guides/agentic-engineering-patterns/)) — Every session starts by running the test suite. Every feature uses red/green TDD. Tests are the regression safety net across phases.

3. **Structured handoffs** (from both sources) — Session artifacts carry enough context for a clean restart, avoiding the quality degradation that comes from context window growth and compaction.
