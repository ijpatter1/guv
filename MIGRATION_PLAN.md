# Migration Plan — Stack-Agnostic, Task-Agnostic, Control-Plane Template

**Audience:** a Claude Code instance executing this migration.
**Goal:** convert this Node/greenfield/single-repo template into one that works for any stack, any task size, and either a single repo or a control-plane/code-repo split — without ever leaving the repo in a broken state.

## Locked decisions (do not re-litigate these)

1. **Manifest holds parseable facts; CLAUDE.md references it.** Introduce `.claude/project.json`. Every hardcoded command, path, and toggle moves there. CLAUDE.md keeps prose context and *points at* the manifest rather than restating values, so there is nothing to drift.
2. **Permissions are loosened; the sandbox is the hard line.** Do not maintain tight `Write(src/**)`-style globs. The real enforcement boundary is the firewall + bash-guard universal blocks + the Docker sandbox + the auto-mode classifier. settings.json becomes a thin convenience layer, not a security layer.
3. **Topology: control-plane-as-cwd.** Claude Code launches in the control-plane repo. The code repo is a sibling. The manifest declares both roots. Git becomes root-aware. **Single-repo is the degenerate case where both roots are `"."`** — build that path for free, never as a special case.
4. **Ceremony scales with the work.** Three entry points (`/task`, `/onboard`, `/init-project`). Phase docs, session handoffs, and UAT are *project-shape* artifacts that no-op when absent. The evaluator, product-reviewer, safety hooks, manifest, TDD, and fail-loud conventions are the *durable core* and always apply.
5. **Stack resolution: detect-to-propose, persist-to-be-deterministic.** A resolver sniffs the repo and proposes the manifest; a human confirms or overrides; from then on the manifest is authoritative. Detection bootstraps the declaration but never replaces it.
6. **The per-project root is a thin importing template, shipped inert; behavior lives in a reusable core. — ALREADY LANDED.** The durable behavioral rules now live in `.claude/RULES.md`, and the per-project root has been rewritten as a short file that imports them via `@.claude/RULES.md`, defers all commands to the manifest, and holds only the project facts Claude can't infer. It is shipped as **`claude.template.md`, deliberately not `CLAUDE.md`**, so it never auto-loads — see the rename rationale in Execution order. A generator renders it into a real `CLAUDE.md` in a target project; `RULES.md` (imported by the template) likewise loads only once a rendered `CLAUDE.md` loads. Both files are **already in the repo** — this migration no longer creates them, it makes the rest of the system match what they promise. The governing test was the docs' pruning test — *would removing this line cause a mistake?* — under the instruction-budget constraint that a loaded `CLAUDE.md` costs context every session.

## The manifest schema (the spine of everything)

Create `.claude/project.json`. This is the single source of truth all other changes route through.

```json
{
  "$schema": "./project.schema.json",
  "name": "tmmh-storefront",
  "language": "node",
  "packageManager": "npm",
  "roots": {
    "control": ".",
    "code": "../tmmh-storefront"
  },
  "commands": {
    "test": "npm test",
    "build": "npm run build",
    "lint": "npm run lint",
    "format": "npx prettier --write",
    "dev": "npm run dev"
  },
  "scaffoldCheck": "test -f package.json",
  "formatExtensions": ["js", "jsx", "ts", "tsx", "json", "css", "scss", "md", "html", "yml", "yaml"],
  "guards": ["npm-publish"],
  "ceremony": "phased"
}
```

Field semantics the executing instance must honor:

- `roots.control` / `roots.code` — relative to cwd (the control plane). Single-repo sets both to `"."`. Code writes target `${roots.code}/…`; docs and session artifacts live under `${roots.control}/docs`.
- `commands.*` — any value may be `null`, meaning "this project has no such step." Consumers must skip cleanly on `null`, never error and never substitute a default.
- `guards` — opt-in stack-specific danger blocks layered on top of the always-on universal set. Valid values: `"gcp"`, `"npm-publish"`, `"cargo-publish"`, `"pypi-publish"`, etc. A project lists only what applies.
- `ceremony` — `"phased"` (full greenfield), `"onboard"` (existing repo, conventions inferred not scaffolded), or `"task"` (scoped, no phase docs). Controls how much project-shape machinery the commands invoke.

Also write `project.schema.json` so the manifest validates and editing it is self-documenting.

## Execution order

Each phase leaves the repo working. Do them in order; commit after each.

**Already in the repo (landed ahead of this migration):** `claude.template.md` (the thin importing root, deliberately *not* named `CLAUDE.md`) and `.claude/RULES.md` (behavioral core).

**Why the template is named `claude.template.md`.** Claude Code auto-loads `CLAUDE.md` at the start of every session. During this migration, the agent doing the work operates *in the template repo itself* — and the template's content (read the manifest, use `/task`, work the current phase) is instruction for a *consumer* project, not for the meta-work of building the template. Naming it `claude.template.md` makes it inert: it never auto-loads, so the migration agent's context is governed only by this plan, uncontaminated by consumer-project instructions. The file becomes a real `CLAUDE.md` only when `/init-project` or `/onboard` renders it into a target project.

**Forward-reference hazard — dissolved by the rename.** The template references `.claude/project.json`, `/task`, `/onboard`, `roots`, and `ceremony`, none of which exist until the phases below land. Earlier this risked dangling references being injected into the working agent. Because `claude.template.md` no longer auto-loads, that hazard is gone: the references resolve at *render time*, when a generator produces a real `CLAUDE.md` — by which point the manifest (Phase 0) and generators (Phases 6–7) all exist. Consequence, by design: `RULES.md` also does not auto-load during the migration, since nothing imports it until a rendered `CLAUDE.md` does. The migration therefore runs on this plan plus the agent's defaults. If you want the behavioral rules active for the migration work itself, name `RULES.md` in your kickoff prompt — don't rename it to `CLAUDE.md`, or you'll reintroduce the consumer-context contamination the template rename was meant to avoid.

---

### Phase 0 — Introduce the manifest (first by dependency order)

Create `.claude/project.json` and `.claude/project.schema.json` with the current Node/phased/single-repo values (`roots` both `"."`, `ceremony: "phased"`, the existing commands). It goes first because Phase 1's hooks and Phase 2's commands read from it — not because of acute pressure, since the renamed `claude.template.md` doesn't auto-load and its references resolve only at render time. Match the manifest's field names exactly to what `claude.template.md` describes (`commands.*`, `roots.control/code`, `ceremony`, `guards`, `scaffoldCheck`, `formatExtensions`) so that when a generator renders the template into a real `CLAUDE.md`, every reference lands. Commit: `feat(manifest): introduce project.json as single source of truth`.

---

### Phase 1 — Route the shell hooks through the manifest; split the guards

**`auto-format.sh`** — replace the hardcoded `npx prettier` call and the inline extension `case` with manifest reads:

- Parse `commands.format` and `formatExtensions` via `jq` (already a Dockerfile dependency).
- If `commands.format` is `null`, exit 0 silently.
- Otherwise run `${commands.format} "$FILE"` only when the extension is in `formatExtensions`.
- The hook receives the file path in `tool_input`, so it is already root-agnostic — it formats whatever path it's handed, in either repo. No path logic needed.

**`bash-guard.sh`** — split the `BLOCKED_PATTERNS` array into two:

- `UNIVERSAL_BLOCKED` (always on, the true stack-agnostic core): `rm -rf /`, `rm -rf ~`, `rm -rf .`, `mkfs.`, `dd if=`, `chmod -R 777 /`, write-to-raw-disk, `curl|sh` / `wget|sh` pipe-to-shell, `git push` (all forms — push from host after review), `git reset --hard origin`.
- `OPTIONAL_BLOCKED` keyed by guard name: `gcp` → all `gcloud … delete`, `bq rm`, `bq … --delete`; `npm-publish` → `npm publish`, `npx npm publish`; analogous publish blocks for other ecosystems.
- Read `guards` from the manifest with `jq`, union the matching optional sets onto the universal set, then run the existing match loop. A Rust CLI project carries no GCP guards it will never trigger; a GCP project opts in via `"guards": ["gcp"]`.

Commit: `refactor(hooks): drive format + guards from manifest, split universal vs stack-specific`.

---

### Phase 2 — Route the markdown commands and the evaluator through the manifest

Everywhere a literal `npm test` / `npm run build` / `npm run lint` / `package.json` check appears, replace it with an instruction to read the corresponding value from `.claude/project.json` and run it, skipping cleanly when the value is `null`.

Touchpoints to change:

- **`claude.template.md`** — **nothing to do.** The old monolith with embedded `npm` commands is gone, replaced by the landed thin template that defers all commands to the manifest. It is inert (doesn't auto-load) and isn't a command touchpoint. Phase 7 wires the generators that render it into a real `CLAUDE.md`.
- **`start-phase.md`** — Step 1's `test -f package.json && npm test` becomes `run ${scaffoldCheck}; if it passes, run ${commands.test}`. Generalize the `NO_PACKAGE_JSON` branch into `NOT_SCAFFOLDED` (see Phase 6).
- **`status.md`** — same `scaffoldCheck` + `commands.test` substitution; keep it to its 10-line budget.
- **`handoff.md`** — Step 3's `npm test` → `${commands.test}`. The UAT script templates' CLI/web/manual hierarchy is already stack-neutral; just ensure any embedded test/build invocation reads from the manifest.
- **`evaluate.md`** — its git commands move to Phase 3; its test/build/lint references read from the manifest.
- **`evaluator.md`** — replace "Read CLAUDE.md's Test Commands section to determine the correct test command" with "read `commands.test` / `commands.build` / `commands.lint` from `.claude/project.json`." Handle `null` build as "skip the build step" (the doc already anticipates Python-without-compilation — make that the manifest-driven default).

Commit: `refactor(commands): read test/build/lint from manifest across all commands and evaluator`.

---

### Phase 3 — Make git root-aware (the control-plane seam)

This is the one genuinely root-relative concern. Two of the three coupling points (auto-format reads `tool_input` paths; bash-guard inspects command strings) are already root-agnostic. Git is not.

In every command and skill that runs git against the code (start-phase, handoff, evaluate, status, the `change` skill, and the `session-management` skill):

- Replace bare `git log` / `git diff` / `git status` / `git show` with `git -C ${roots.code} …`.
- Doc-side commits (session artifacts, phase status, requirements) run against `${roots.control}`.
- The split produces two commit streams by design: product history in the code repo, doc/session history in the control plane. The handoff format already *references* commit hashes rather than sharing a commit, so it already supports this — confirm no command assumes code and docs share a working tree.
- `claude.template.md` no longer carries the old "Session Context from Git" prose (the landed thin template documents the `roots` topology instead), so there is nothing to edit there — confirm its "Where the code lives" section's git guidance matches the `git -C ${roots.code}` convention you implement here.

Because `roots.code` defaults to `"."`, `git -C . …` is a no-op for single-repo. The same code path serves both topologies.

Commit: `refactor(git): make all code-repo git operations root-aware via roots.code`.

---

### Phase 4 — Loosen permissions (settings.json)

Per the locked decision, settings.json stops being a security layer:

- Keep a minimal universal-safe **allow** set: `Read(*)`, `Bash(git:*)`, common read-only unix tools (`ls`, `cat`, `grep`, `rg`, `find`, `head`, `tail`, `wc`, `sort`, `diff`, `pwd`, `which`, `env`, `date`), and `mkdir`/`cp`/`mv`/`touch`/`chmod`.
- Drop the stack-specific allows (`npm`/`npx`/`node`/`tsc`/`jest`/`playwright`/`gcloud …`/`bq …`) — they're no longer needed as a convenience layer when running auto mode, and they're stack-coupled.
- Replace the path-scoped `Write(src/**)` / `Edit(src/**)` / framework-config globs with a broad workspace-scoped write allowance. Tight globs would actively *block* writing into `${roots.code}/src/…` across the repo boundary — loosening them is what makes cross-repo development frictionless, which is why this decision and the topology reinforce each other.
- Keep the **deny** set as a thin backstop (`sudo`, `su`, reading `.env`/secrets), but treat the firewall + bash-guard + sandbox + auto-mode classifier as the real boundary.

Commit: `refactor(permissions): loosen to convenience layer, defer enforcement to firewall + sandbox`.

---

### Phase 5 — Firewall, Docker base, and dual-root mounts

**`init-firewall.sh`** — the CORE section currently allows only npm + GitHub. Broaden CORE to cover the common registries, gated by declared `language` so a project only resolves what it needs: PyPI (`pypi.org`, `files.pythonhosted.org`), crates.io (`crates.io`, `static.crates.io`, `index.crates.io`), RubyGems, the Go module proxy, Maven Central. Keep GitHub + Anthropic always-on. The existing CORE/PROJECT/GCLOUD structure stays; this just populates CORE per language.

**`Dockerfile`** — `node:20-slim` is the one spot that resists full agnosticism. Make the base image a build arg keyed off `language` (you already template `IMAGE_NAME`/`CONTAINER_NAME` in the Makefile, so a `BASE_IMAGE` build arg fits the existing pattern). Ship a Node default and document the swap. Do **not** reach for a fat multi-runtime image unless a later need justifies the size.

**`Makefile`** — mount **both roots** into the container instead of one: bind-mount `${roots.control}` and `${roots.code}` (skip the second mount when they coincide). The firewall is unchanged; only the volume mounts grow. `make dev` currently hardcodes `npm run dev` — read `commands.dev` from the manifest, or keep `npm run dev` as the documented-overridable default since `dev` already says "override this in your project."

Commit: `feat(sandbox): per-language registries, build-arg base image, dual-root mounts`.

---

### Phase 6 — Entry points and ceremony tiers

Add two entry points alongside `/init-project`, and make the phase-shape machinery degrade gracefully when absent.

- **`/task "<description>"`** — scoped mode. No phase docs, no requirements ceremony: understand → red/green TDD the change → evaluate (both reviewers) → done. The existing `change` skill (bug-fix / quality-improvement / new-capability router) is *already* this logic — promote it from an in-phase sub-tool to a first-class entry point that runs with no phase docs present. Sets/assumes `ceremony: "task"`.
- **`/onboard`** — adopt an existing repo. Run the stack resolver (Phase 8), *infer and record the repo's existing conventions* rather than scaffolding new ones, write the manifest and a CLAUDE.md documenting what's there (from the Phase 7 template). Crucially: **do not impose phase structure** — and omit the bootstrapping section entirely, since the repo is already scaffolded. This is the path that unlocks "any size," since most real work is on code that already exists. Sets `ceremony: "onboard"`.
- **`/init-project`** — unchanged: greenfield + full phased setup. Sets `ceremony: "phased"`.

Graceful degradation (the rule that makes ceremony optional):

- Generalize start-phase's `NO_PACKAGE_JSON` handling into a single pattern: **"missing project-shape artifact" is a mode signal, not an error.** No `package.json` → not scaffolded. No phase docs → task/onboard mode, skip phase loading. No prior session → skip handoff-reading.
- handoff's UAT-generation branch and phase-completion logic **no-op** when `ceremony != "phased"` or when there's nothing to track.
- Commands read `ceremony` from the manifest to decide how much machinery to invoke.

Guard against over-application: don't make the control-plane split or the phase ceremony mandatory. A `/task` bug fix in a repo you own runs in place with `roots` both `"."` and no phase docs. Ceremony and topology both scale up only when the work warrants it.

Commit: `feat(entrypoints): add /task and /onboard, make phase ceremony optional`.

---

### Phase 7 — Wire the render step and reconcile the landed files

The durable-core / project-shell split is **already in the docs** — `claude.template.md` and `.claude/RULES.md` are in the repo. This phase retires what they superseded and, most importantly, teaches the generators to *render the inert template into a live `CLAUDE.md`*.

**Wire the render step (the core change from the rename).** `claude.template.md` is inert by design; it must be turned into a real `CLAUDE.md` for any project it governs. Update `/init-project` and `/onboard` to:

1. Read `claude.template.md`.
2. Fill its placeholders — project identity, the "Project facts Claude can't infer" section, and (for `/init-project`) the bootstrapping section; `/onboard` omits bootstrapping since the repo already exists.
3. **Write the result as `CLAUDE.md` at `${roots.control}`** (the control plane is cwd, so that's where Claude Code auto-loads it). The `@.claude/RULES.md` import and the manifest pointer carry over unchanged — the import path is unaffected by the source file's name.

The generators fill placeholders; they do not regenerate the structure. The template stays in the repo as the inert source; the rendered `CLAUDE.md` is the live artifact.

**Retire the old rules file.** `claude.example.md` (the 11/12-rule file) is superseded by `.claude/RULES.md`. Remove it, or reduce it to a one-line pointer at `RULES.md`, so there is exactly one behavioral source. Note the repo now has a clean inert/active split: `claude.template.md` and `.claude/RULES.md` are inert sources that never auto-load; a rendered `CLAUDE.md` is the only file that loads, and only in a real project.

**Update the README.** The current README tells users to "edit the four template files directly," listing `CLAUDE.md` as one. Change that reference to `claude.template.md`, and describe the new flow: `/init-project` or `/onboard` *renders* `claude.template.md` → `CLAUDE.md`; the manual alternative is to edit `claude.template.md` then render (or, for a quick start, copy it to `CLAUDE.md` and fill it in by hand). Make explicit that the template repo ships **no** `CLAUDE.md` — that's intentional, so nothing governs the meta-work of using the template.

**Do not gitignore `CLAUDE.md`.** It's tempting to ignore it so a stray rendered file doesn't get committed into the template repo, but consumers *must* commit their rendered `CLAUDE.md` (the docs are explicit: check `CLAUDE.md` into git). Ignoring it would silently break every downstream project. The template ships without a `CLAUDE.md` and relies on the `rm -rf .git && git init` step in the "Use this template" flow to keep the meta-repo clean; leave `.gitignore` alone here.

**Confirm placement is settled.** By keeping `RULES.md` at `.claude/RULES.md` and importing it via `@.claude/RULES.md`, you've chosen the per-project, version-controlled, forkable placement (option *a* from the earlier fork) — the right default for a template, since it travels with the control plane and is self-contained. If you also keep a global `~/.claude/CLAUDE.md`, both load; avoid duplicating rules across them.

**Verify the rendered references resolve.** After Phases 0 and 6 land, render `claude.template.md` once (a dry run of `/init-project` or `/onboard`) and walk the produced `CLAUDE.md` top to bottom: confirm `.claude/project.json` exists with field names matching what the template describes, `@.claude/RULES.md` resolves, `/task` and `/onboard` are defined, and the `roots`/`ceremony` semantics match the manifest. This is the step that proves the documentation-at-render-time contract holds.

Commit: `chore(claude-md): render claude.template.md → CLAUDE.md in generators, retire claude.example.md`.

---

### Phase 8 — The stack resolver

Build a small resolver invoked by `/onboard` and `/init-project` that sniffs the repo and *proposes* a manifest:

- `package.json` → node (read `packageManager` from `packageManager` field / lockfile)
- `pyproject.toml` / `requirements.txt` → python (uv / poetry / pip from lockfiles)
- `Cargo.toml` → rust
- `go.mod` → go
- `Gemfile` → ruby
- `pom.xml` / `build.gradle` → jvm
- `*.csproj` → dotnet
- `mix.exs` → elixir

It proposes `commands`, `scaffoldCheck`, `formatExtensions`, and a `language`; the human confirms or overrides; the result is written once and is authoritative thereafter. Detection bootstraps the declaration — it never *is* the declaration. When a project does something unusual, the human override in the manifest wins and stays deterministic.

Commit: `feat(resolver): detect-to-propose stack manifest for onboard and init`.

---

### Phase 9 — Cleanup of pre-existing leakage and bugs

These are independent of the migration but should land while the files are open:

- **iampatterson leakage in `evaluator.md`** — remove the `src/lib/events/schema.ts` event-pipeline reference; it's project-specific and has no place in a generic template. Keep the generic "check events fire correct data" guidance only if you keep it stack-neutral, otherwise cut it.
- **`product-reviewer.md` frontmatter copy-paste** — its `description` says "Use @evaluator or /evaluate to trigger," lifted verbatim from the evaluator. Fix to reference the product reviewer's own invocation.
- **`product-reviewer.md` hook JSON path bug** — its bash-guard hook keys on `.input.command`, while settings.json and bash-guard.sh use `.tool_input.command`. The product-reviewer's read-only hook is likely matching nothing and silently never enforcing. Align it to `.tool_input.command`.

Commit: `fix(agents): remove project leakage, fix product-reviewer frontmatter + hook path`.

---

## Touchpoint inventory (quick cross-reference)

| File | Coupling | Phase |
|---|---|---|
| `.claude/project.json` (new) | — | 0 |
| `.claude/hooks/auto-format.sh` | hardcoded prettier + extensions | 1 |
| `.claude/hooks/bash-guard.sh` | universal + stack guards mixed | 1 |
| `.claude/RULES.md` | **landed** — behavioral core (inert source) | 7 |
| `claude.template.md` | **landed** — inert thin template; rendered → `CLAUDE.md` | 7 |
| `claude.example.md` | superseded by RULES.md → remove or stub | 7 |
| `.claude/commands/start-phase.md` | npm test, package.json, git, NO_PACKAGE_JSON | 2, 3, 6 |
| `.claude/commands/status.md` | npm test, package.json, git | 2, 3 |
| `.claude/commands/handoff.md` | npm test, UAT templates, git | 2, 3 |
| `.claude/commands/evaluate.md` | npm refs, git | 2, 3 |
| `.claude/commands/init-project.md` | render `claude.template.md` → `CLAUDE.md` | 7 |
| `.claude/commands/onboard.md` (new) | render template (no bootstrapping) | 6, 7 |
| `README.md` | "edit CLAUDE.md" → `claude.template.md` + render flow | 7 |
| `.claude/agents/evaluator.md` | "Test Commands section", events leakage, git | 2, 3, 9 |
| `.claude/agents/product-reviewer.md` | frontmatter + hook path bugs, git | 3, 9 |
| `.claude/skills/change/SKILL.md` | git; promote to /task | 3, 6 |
| `.claude/skills/session-management/SKILL.md` | git | 3 |
| `.claude/settings.json` | npm/gcloud allows, Write globs | 4 |
| `sandbox/init-firewall.sh` | npm-only CORE | 5 |
| `sandbox/Dockerfile` | node:20-slim base | 5 |
| `Makefile` | single mount, npm run dev | 5 |

## What "done" looks like

The repo splits cleanly into a **durable core** (manifest + `RULES.md` behavioral rules + evaluator/reviewer + universal hooks + TDD/fail-loud conventions — never edited per project) and a **project shell** (a thin `claude.template.md` + phase docs + stack-specific guards + firewall additions + roots — rendered/generated per project). The template ships inert and never auto-loads; a generator renders it into a live `CLAUDE.md` that loads in a fraction of the old monolith's tokens and holds only can't-infer facts, so the instruction budget goes to rules that actually bite. Single-repo greenfield Node still works exactly as before because that's just the manifest's default values. A Rust CLI bug fix runs via `/task` with no phase docs, no GCP guards, and `roots` coincident. A headless storefront in a sibling repo runs control-plane-as-cwd with `roots.code` pointing across the boundary, two commit streams, and both roots mounted in the sandbox. Same core, different shell.