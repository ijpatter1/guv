# Governor (guv) — a control plane for Claude Code

<!-- guv-template-readme: this is the TEMPLATE repo's README — /init-project
     replaces this file in rendered projects. Test suites key consumer-shape
     skips on this marker (it survives headline rewording; remove it only if
     you mean to disable those guards). -->

A governor is a device that sits on a powerful engine and keeps it from running away — restraint built into the mechanism. That is what this harness adds to autonomous Claude Code sessions: a machine-readable project manifest, ceremony tiers, calibrated QA reviewers, deterministic safety hooks, a committed team-visible session record, and two-tier sandboxed isolation — native sandbox by default, Docker opt-in.

Installs as the versioned **guv plugin** from this repo's marketplace; cloning the repo as a template remains the fallback path.

Based on patterns from [Anthropic's harness design research](https://www.anthropic.com/engineering/harness-design-long-running-apps) and [Simon Willison's Agentic Engineering Patterns](https://simonwillison.net/guides/agentic-engineering-patterns/).

## Philosophy

guv treats software engineering as a data engineering problem.

When a model writes the code, the code stops being the source. It is one of many
codebases the model could have written from the spec: regenerate it and you get a
different one, with different bugs. Git keeps the version that passed its checks
because that is where verification is banked, not where truth lives. The truth is
everything upstream of the code: what you asked for, what depends on what, what has
been done, and what counts as good. Keeping that reliable is a pipeline problem, and
data engineering already knows how to run pipelines on unreliable compute.

A model is not reliable the way a compiler is reliable, so guv divides the work
accordingly: machines check, people decide. Anything that can be checked against the
same standard every time gets built into the machinery. Everything that can't is a
decision, and decisions stay with a person. The line between the two moves in one
direction: once a decision becomes precise enough to check, it crosses over and does
not come back.

The name says the rest. Watt's governor held an engine at the speed a person chose.
Choosing the speed was never its job.

## What's Included

**Entry points** — four ways in, scaled to the work:

- `/init-project <spec>` — greenfield: generate phase docs + manifest, render `CLAUDE.md`
- `/onboard` — adopt an existing repo: detect the stack, infer conventions, render `CLAUDE.md`, no phase ceremony
- `/task "<description>"` — scoped change: understand → red/green TDD → evaluate → done
- `/plan <spec>` — multi-phase initiative on an existing project: archive the prior initiative, generate fresh phase docs with continuous numbering, flip ceremony to `phased`

**Session workflow** — commands that encode a Planner → Generator → Evaluator loop (phased projects):

- `/phase N` — Phase-boundary entry: branch, deep-read, full context + spec-alignment, present a plan (crossing into a phase)
- `/next` — Light daily/mid-phase resume: read the resolver's ready-frontier and present the next pick with a plan, no boundary ritual
- `/replan` — Mutate the live plan through the one sanctioned door: classify, confirm, apply atomically with an amendment record
- `/eval` — Trigger independent dual QA review mid-session
- `/handoff` — End session with full QA + handoff artifact for continuity
- `/status` — Quick 10-line project orientation

**Dynamic workflows** — Saved workflows in `.claude/workflows/` register as slash commands. The planning layer is the phase docs and the commands; the execution layer is the model, subagents, and — for wide mechanical fan-out — workflows (`.claude/rules/guv-workflows.md`: QA stages invoke the calibrated reviewers by name; ultracode is fan-out-only, dropped back after). Ships with `/eval-parallel`: both reviewers concurrently over a commit-range scope, returning both reports plus the combined summary — the fix loop stays conversational, in the main session.

**Manifest-driven** — `.claude/project.json` is the single source of truth for stack, commands, repo topology (`roots`), and ceremony. Hooks, commands, the sandbox, and the firewall all read from it, so there's nothing to drift. Behavioral rules live in `.claude/rules/` (`guv-*.md`, loaded natively).

**Repo topology** — single repo by default (`roots` both `"."`). For a control-plane / code split, Claude launches in the control plane and the product is a sibling repo. Convention: the code repo keeps the plain product name, the control plane is its sibling named per the `<project>-guv` convention (here `<product>-guv` — a possessive suffix, the product's guv; human-facing only, never used for discovery: the manifest is the sole machine pointer), and the manifest's `name` stays the _product_ name (it feeds image/container labels):

```
~/dev/
├── <product>/        # code repo            → roots.code: "../<product>"
└── <product>-guv/    # control plane (cwd)  → roots.control: "."
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
resolve as `guv:evaluator` / `guv:reviewer`.

**Fallback — template-clone** (unversioned): for forks that customize harness-owned
files (a plugin's surfaces aren't editable; a clone's are) or environments without
plugin support. Updates arrive via `maintainers/setup-control-plane.sh --sync` —
supported indefinitely, though new surface ships plugin-first.

**Already on a template clone?** The decided disposition: **migrate to the plugin**
if you haven't customized harness-owned files. In order:

1. Install the plugin (marketplace add + install, as above).
2. Delete the copied surfaces the plugin now supplies at runtime, so the two
   copies don't double-load: `.claude/skills/`,
   `.claude/agents/`, `.claude/hooks/`, the loose helper scripts
   (`resolve-stack.sh` and friends), and harness-shipped workflows. If you've
   added files of your own inside those directories (a custom skill or agent),
   move them aside first — the directories have no ownership convention, so
   the deletion takes everything.
3. **Remove the `hooks` block from `.claude/settings.json`** — it registers the
   just-deleted hook scripts by path, so every tool call would invoke a missing
   file. The plugin's own `hooks.json` takes over. This is a hand edit:
   `/guv:scaffold` never touches an existing settings file.
4. Keep everything else. **Keep `.claude/rules/guv-*.md`** in particular: rules
   load from the project, not from the plugin — the plugin only re-deploys them
   via `/guv:scaffold` — so deleting them strips the engineering-rules layer with
   nothing taking over. Your manifest (and its schema file), docs, feedback log,
   unprefixed rules, and consumer-saved workflows are consumer-owned and stay.

If you **have** customized harness-owned surfaces, keep the clone — but update
deliberately: `--sync` replaces harness-owned surfaces **wholesale** (commands,
skills, agents, hooks, settings, helper scripts — only unprefixed rules files and
consumer-saved workflows are ownership-protected), so a blind sync reverts exactly
the customizations this path exists for. Re-apply your edits after a sync, pull
upstream changes selectively, or move the customizations into consumer-owned
surfaces (unprefixed rules, your own workflows) and then migrate.

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

The tracker has a rendered view: a single self-contained `status.html` (DAG of
deliverables, ready frontier ringed, blocked chains traceable) produced by

```bash
bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json > status.json
bash .claude/render-status.sh status.json > status.html
```

— it opens from disk, and committing it as a derived artifact is permitted (the
optional `views` manifest entry declares it; rebuilt, never line-merged). Before
serving it with GitHub Pages, mind that Pages sites from private repos are
public on non-Enterprise plans.

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
/phase 1
```

### 5. Daily workflow

```bash
# Terminal 1: Claude Code (or `make sandbox` for the Docker tier)
claude
# /next   (or /phase N when crossing into a new phase)

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
│   ├── resolve-ready.sh               # Deterministic ready-frontier resolver (DAG tracker)
│   ├── render-status.sh               # Renders status.json as one self-contained status.html (a view, never a source)
│   ├── replan.sh                      # /replan's deterministic engine (guards, ordinals, atomic writes)
│   ├── check-citations.sh             # Advisory: stale commit citations (split topology)
│   ├── update-readme-status.sh        # Maintains the README STATUS block in place
│   ├── archive-initiative.sh          # Freeze a finished initiative's phase docs (plan)
│   ├── guv-git.sh                     # Git against roots.code, once (the retired inline incantation)
│   ├── guv-cmd.sh                     # Manifest command + loud null-skip, once
│   ├── guv-lane.sh                    # Worktree lane lifecycle (create/harvest/destroy)
│   ├── settings.json                  # Permissions (convenience layer) + hooks
│   ├── settings.sandbox-example.json  # Recommended native-sandbox fragment (default tier)
│   ├── settings.local.json            # Personal overrides (gitignored)
│   ├── agents/
│   │   ├── evaluator.md               # Technical QA evaluator subagent
│   │   └── reviewer.md                 # Product reviewer subagent
│   ├── hooks/
│   │   ├── bash-guard.sh               # Blocks dangerous commands (universal + opt-in guards)
│   │   ├── auto-format.sh              # Formats on write (formatter from manifest)
│   │   └── stop-check.sh               # Reminds about evaluation
│   ├── skills/                         # All process verbs are skills (commands flattened in at [8.3])
│   │   ├── task/                       # /task — scoped change entry point
│   │   ├── next/                       # /next — light daily/mid-phase re-entry (resolver frontier)
│   │   ├── phase/                      # /phase — phase-boundary entry (full ritual + spec alignment)
│   │   ├── plan/                       # /plan — phased initiative on an existing project
│   │   ├── init-project/               # /init-project — greenfield: scaffold + render CLAUDE.md
│   │   ├── onboard/                    # /onboard — adopt an existing repo (no phase ceremony)
│   │   ├── replan/                     # /replan — plan mutation: the one sanctioned door (engine: replan.sh)
│   │   ├── eval/                       # /eval — dual QA review
│   │   ├── feedback/                   # /feedback — record harness friction
│   │   ├── handoff/                    # /handoff — session end + dual QA + handoff
│   │   ├── status/                     # /status — quick status check
│   │   ├── manual/                     # /manual — out-of-sandbox task artifacts
│   │   ├── phase-docs/                 # Shared phase-doc templates (init-project + plan)
│   │   └── session-management/         # Context continuity conventions
│   ├── workflows/
│   │   └── eval-parallel.js       # /eval-parallel — both reviewers, concurrent
│   ├── tests/                         # Bash test suites for the harness scripts/skills
│   └── feedback/                      # Harness-friction log (created on first /feedback)
├── maintainers/                       # Maintainer-only — developing the harness (consumers can delete)
│   ├── DOGFOODING.md                  # How to dogfood the harness via a control-plane split
│   ├── RELEASING.md                   # Release flow: bump policy, checklist, feedback drain
│   ├── setup-control-plane.sh         # Scaffold/sync a dogfooding control plane (also the
│   │                                  #   template-clone fallback's --sync update path)
│   ├── build-plugin.sh                # Generates plugin/ from .claude/ + plugin-src/ (Phase 5)
│   ├── render-smoke.js                # Dev-only DOM-stub execution check for render-status.sh's in-page JS
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

## Verifying a plugin install ([10.3])

The guv plugin ships its consumer-meaningful test suites alongside a
layout-reconstructing runner, so you can verify an install actually resolves
and exercises the plugin's own script bytes (not a source checkout). From the
plugin install directory:

```bash
bash tests/run-plugin-tests.sh
```

The runner rebuilds a `.claude/`-shaped tree from the flattened `scripts/`
(scripts at the top level, hooks recovered into `hooks/` from `hooks.json`, the
shipped suites in `tests/`) and runs every shipped suite against it. A green run
means the location-relative harness suites resolve and pass in plugin layout; a
suite that cannot find its script turns the run red and names the offender.
