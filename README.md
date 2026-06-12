# Governor (guv) — a control plane for Claude Code

A governor is a device that sits on a powerful engine and keeps it from running away — restraint built into the mechanism. That is what this harness adds to autonomous Claude Code sessions: a machine-readable project manifest, ceremony tiers, calibrated QA reviewers, deterministic safety hooks, a committed team-visible session record, and two-tier sandboxed isolation — native sandbox by default, Docker opt-in.

Installs as the versioned **guv plugin** from this repo's marketplace; cloning the repo as a template remains the fallback path.

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

**Dynamic workflows** — Saved workflows in `.claude/workflows/` register as slash commands. The planning layer is the phase docs and the commands; the execution layer is the model, subagents, and — for wide mechanical fan-out — workflows (`.claude/rules/guv-workflows.md`: QA stages invoke the calibrated reviewers by name; ultracode is fan-out-only, dropped back after). Ships with `/evaluate-parallel`: both reviewers concurrently over a commit-range scope, returning both reports plus the combined summary — the fix loop stays conversational, in the main session.

**Manifest-driven** — `.claude/project.json` is the single source of truth for stack, commands, repo topology (`roots`), and ceremony. Hooks, commands, the sandbox, and the firewall all read from it, so there's nothing to drift. Behavioral rules live in `.claude/rules/` (`guv-*.md`, loaded natively).

**Repo topology** — single repo by default (`roots` both `"."`). For a control-plane / code split, Claude launches in the control plane and the product is a sibling repo. Convention: the code repo keeps the plain product name, the control plane is `<product>-control`, and the manifest's `name` stays the _product_ name (it feeds image/container labels):

```
~/dev/
├── <product>/           # code repo            → roots.code: "../<product>"
└── <product>-control/   # control plane (cwd)  → roots.control: "."
```

**QA evaluator subagent** — An independent, skeptical reviewer that grades work on five criteria (Functionality, Test Quality, Code Quality, Completeness, Integration). Runs in its own context window with read-only enforcement. Auto-invoked before every session handoff.

**Two isolation tiers** — Default: Claude Code's **native sandbox** (OS-enforced filesystem/network limits, zero Docker steps — recommended settings ship in `.claude/settings.sandbox-example.json`). Opt-in: a **Docker sandbox** with iptables firewall for full environment reproducibility, `--dangerously-skip-permissions` autonomy, or platforms without native support. Pick one tier per project — see [Security Model](#security-model).

**Safety hooks** — Deterministic enforcement of dangerous command blocking (bash-guard), auto-formatting (auto-format), and session reminder (stop-check).

**Session continuity** — Handoff artifacts and phase status tracking that carry context across sessions and context resets.

## Quick Start

### 1. Install the harness

**Default — the guv plugin** (versioned; updates ride releases, see `CHANGELOG.md`):

```bash
claude plugin marketplace add ijpatter1/guv
claude plugin install guv@guv

# then, inside your project directory:
claude
/guv:scaffold   # deploys the project shell: manifest scaffolding, rules, docs skeletons, .gitignore block
```

Under a plugin install every harness command carries the `guv:` prefix —
`/guv:init-project`, `/guv:status`, `/guv:handoff` — and the reviewer agents
resolve as `guv:evaluator` / `guv:product-reviewer`.

**Fallback — template-clone** (unversioned): for forks that customize harness-owned
files (a plugin's surfaces aren't editable; a clone's are) or environments without
plugin support. Updates arrive via `maintainers/setup-control-plane.sh --sync` —
supported indefinitely, though new surface ships plugin-first.

**Already on a template clone?** The decided disposition: **migrate to the plugin**
if you haven't customized harness-owned files. Install it, then in your project
delete only the copied surfaces the plugin now supplies at runtime — commands,
skills, agents, hooks, the loose helper scripts (`resolve-stack.sh` and friends),
and harness-shipped workflows — so the two copies don't double-load, **and remove
the `hooks` block from `.claude/settings.json`**: it registers the hook scripts by
path, so after the deletion every tool call would invoke a missing file (the
plugin's own `hooks.json` takes over; this is a hand edit — `/guv:scaffold` never
touches an existing settings file). **Keep `.claude/rules/guv-*.md`**: rules load
from the project, not from the plugin — the plugin only re-deploys them via
`/guv:scaffold` — so deleting them strips the engineering-rules layer with nothing
taking over. Your manifest (and its schema file), docs, feedback log, unprefixed
rules, and consumer-saved workflows are consumer-owned and stay. If you **have**
customized harness-owned surfaces, keep syncing — that path remains supported.

Click **"Use this template"** on GitHub, or:

```bash
git clone https://github.com/ijpatter1/guv.git my-project
cd my-project
rm -rf .git && git init
```

### 2. Configure for your project

The fastest path — give Claude Code your spec:

```bash
# Start Claude Code (default tier; or `make sandbox` for the Docker tier)
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

> **Don't run Claude Code's native `/init` in a harness-governed repo.** `/init` inlines commands into `CLAUDE.md`, violating the manifest contract (`.claude/project.json` owns commands; `CLAUDE.md` never restates them). `/onboard` is the harness's equivalent and supersedes it.

Review the generated files, adjust anything that needs it, then commit and start building.

> **The template ships no `CLAUDE.md` — that's intentional.** `CLAUDE.md` auto-loads every session, so shipping one would govern the meta-work of _using_ the template. Instead the repo ships the inert `CLAUDE.template.md` (never auto-loaded) plus the `.claude/rules/` behavioral core; `/init-project` or `/onboard` _renders_ `CLAUDE.template.md` → `CLAUDE.md`. Consumers **must commit their rendered `CLAUDE.md`** — it is deliberately not gitignored.

**Manual alternative** — render the template by hand:

- **Copy** `CLAUDE.template.md` to `CLAUDE.md` (leave the template in place — it's the reusable source), then in the copy fill the project identity and the "Project facts Claude can't infer" section (for greenfield, keep "Bootstrapping") and strip the leading `<!-- TEMPLATE … -->` comment. Leave the manifest pointers as-is (rules load natively from `.claude/rules/`).
- **Copy** `README.template.md` to `README.md` (overwriting this harness README), fill the `[bracketed]` placeholders, keep the `<!-- STATUS:START/END -->` markers, and strip the `<!-- TEMPLATE … -->` comment.
- Edit `.claude/project.json` to declare your stack, commands, `roots`, `guards`, and `ceremony`.
- For phased projects, define `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, and `docs/PHASE_STATUS.md`.

If you opt into the Docker tier, also update:

- **`Makefile`** — Change `IMAGE_NAME` and `CONTAINER_NAME` at the top (two lines). The sandbox base image is derived from the manifest's `language`; override with `make build BASE_IMAGE=...`. (Default-tier projects can skip this — the Makefile is only used by `make sandbox` and friends.)

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
# Option A (default tier): native Claude Code + native sandbox
# (enable via .claude/settings.sandbox-example.json or /sandbox in-session;
#  Linux/WSL2: install bubblewrap + socat first — see Security Model below)
claude

# Option B (opt-in tier): Docker sandbox — reproducible env,
# --dangerously-skip-permissions autonomy, or no native sandbox support
make sandbox
```

Then inside Claude Code:

```
/start-phase 1
```

### 5. Daily workflow

```bash
# Terminal 1: Claude Code (or `make sandbox` for the Docker tier)
claude
# /start-phase 1

# Terminal 2: Dev server on the host
make dev

# Terminal 3: Your tools (VS Code, git, tests)
code .
```

## File Structure

```
├── CLAUDE.template.md                 # Inert source for CLAUDE.md (rendered, not auto-loaded)
├── README.template.md                 # Inert source for the PROJECT README (rendered on scaffold/onboard)
├── CHANGELOG.md                       # Plugin release notes (a version bump IS a release)
├── Makefile                           # Container lifecycle (base image from manifest)
├── .gitignore                         # Git exclusions
├── .claude-plugin/
│   └── marketplace.json               # Personal marketplace serving plugin/ (distribution machinery —
│                                      #   template-clone forks can delete it along with plugin/)
├── .claude/
│   ├── project.json                   # MANIFEST — single source of truth (stack/commands/roots/ceremony)
│   ├── project.schema.json            # Manifest schema (validation + self-docs)
│   ├── rules/                         # Behavioral core (guv-*.md harness-owned; unprefixed = yours)
│   ├── resolve-stack.sh               # Detect-to-propose stack manifest (onboard/init)
│   ├── check-citations.sh             # Advisory: stale commit citations (split topology)
│   ├── update-readme-status.sh        # Maintains the README STATUS block in place
│   ├── archive-initiative.sh          # Freeze a finished initiative's phase docs (plan-initiative)
│   ├── settings.json                  # Permissions (convenience layer) + hooks
│   ├── settings.sandbox-example.json  # Recommended native-sandbox fragment (default tier)
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
│   ├── workflows/
│   │   └── evaluate-parallel.js       # /evaluate-parallel — both reviewers, concurrent
│   ├── tests/                         # Bash test suites for the harness scripts/skills
│   └── feedback/                      # Harness-friction log (created on first /log-feedback)
├── maintainers/                       # Maintainer-only — developing the harness (consumers can delete)
│   ├── DOGFOODING.md                  # How to dogfood the harness via a control-plane split
│   ├── RELEASING.md                   # Release flow: bump policy, checklist, feedback drain
│   ├── setup-control-plane.sh         # Scaffold/sync a dogfooding control plane (also the
│   │                                  #   template-clone fallback's --sync update path)
│   ├── build-plugin.sh                # Generates plugin/ from .claude/ + plugin-src/ (Phase 5)
│   └── plugin-src/                    # Authored plugin-only sources (manifest, hooks.json, guv-only skills)
├── plugin/                            # GENERATED — the guv plugin package; never hand-edit, run
│                                      #   maintainers/build-plugin.sh (drift-guarded by plugin.test.sh)
├── docs/
│   ├── REQUIREMENTS.md                # Development plan (phased; YOU EDIT THIS)
│   ├── ARCHITECTURE.md                # Technical architecture (phased; YOU EDIT THIS)
│   ├── PHASE_STATUS.md                # Phase tracker (phased; YOU EDIT THIS)
│   └── sessions/
│       └── .gitkeep
└── sandbox/                           # Docker isolation tier (opt-in; default is native)
    ├── Dockerfile                     # Sandbox image (BASE_IMAGE build arg)
    ├── init-firewall.sh               # Per-language registry allowlist firewall
    ├── entrypoint.sh                  # Privilege drop + Claude start
    └── README.md                      # Sandbox documentation
```

> A rendered `CLAUDE.md` (the live file) and `.claude/project.json` are created/filled per project by `/init-project` or `/onboard`. The template repo ships **no** `CLAUDE.md`.

The **durable core** — the `guv-*` rules in `.claude/rules/`, the manifest, the evaluator/reviewer, the universal hooks — is never edited per project. The **project shell** — the rendered `CLAUDE.md`, the manifest's values, phase docs (`YOU EDIT THIS`), and stack-specific guards/firewall additions — is filled per project. Same core, different shell.

## Security Model

Isolation is three layers with distinct jobs:

1. **Native sandbox — the spatial boundary (default tier).** OS-enforced limits (macOS
   Seatbelt; bubblewrap on Linux/WSL2) on every Bash command and its child processes:
   writes confined to the working directory, network confined to allowlisted domains.
   Enable it with the shipped fragment `.claude/settings.sandbox-example.json` — copy
   its `sandbox` block into `.claude/settings.json`, or run `/sandbox` in-session. The
   fragment's starter domain allowlist mirrors the firewall's core set (Anthropic +
   GitHub) and its comments carry the per-language registry table for your stack.
   macOS needs nothing installed; on Linux/WSL2 install `bubblewrap` and `socat`
   first (see the [official sandboxing docs](https://code.claude.com/docs/en/sandboxing)).
2. **bash-guard — the semantic boundary within it.** The native sandbox permits writes
   anywhere in the working directory, so destructive patterns inside the boundary —
   `rm -rf .`, hard resets, publishes — remain bash-guard's job in both tiers
   (deterministic PreToolUse hook; universal blocks plus manifest-keyed optional
   guards).
3. **Permissions — the convenience layer.** The allow/deny rules in
   `.claude/settings.json` decide what runs without prompting. They reduce friction;
   they are not the enforcement boundary.

The Docker sandbox (`make sandbox`) is the **opt-in tier** that replaces layer 1 with
a container + iptables firewall — see [sandbox/README.md](sandbox/README.md) for when
to choose it. **Pick one tier per project:** running the native sandbox inside the
container requires a weakened mode (`enableWeakerNestedSandbox`) and should not be
combined.

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
