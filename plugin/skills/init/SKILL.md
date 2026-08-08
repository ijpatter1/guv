---
name: init
description: "Scaffold the project documentation from a PRD or spec document."
user-invocable: true
---

**Canonical name: `/guv:init`** (operator ruling §6 #1, 2026-07-20). Under a
plugin install only the namespaced form resolves, and it is the documented
canonical surface. In a source-clone install this skill's bare `/init` shadows
Claude Code's built-in `/init`; that bare surface is non-canonical by the same
ruling — the short name was deliberately not re-picked.

## Step 0 — Routing Guard

This is the **greenfield** door — it lays down phase docs and a `phased`
manifest from a spec. Before scaffolding, ask the deterministic router whether
this is the right door (the routing collapse, [8.1] — manifest + repo state
select the entry; no user disambiguation):

The router's exit code is the contract, identical across all entry doors:

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/route.sh --for init
```

- **`match=yes`** (exit 0) — this is the right door; continue. (Either
  greenfield is confirmed — a `phased` manifest with no phase docs yet — or this
  is a **pre-scaffold** repo where init is the manifest-writing door,
  see exit 4.)
- **`match=no`** (exit 0) — **wrong door: redirect, don't error.** The router
  names the correct door in `door=` — e.g. `door=next`/`door=phase` if a
  plan already exists (don't re-scaffold over it), `door=onboard` for an
  existing repo, `door=task` for scoped work. Tell the user the routed door and
  the `reason=`, and defer to it.
- **Exit 2** — the router is unavailable/misinvoked (absent, a wrong flag, or
  `jq` missing). The router is the fast path, not the only one: proceed with
  scaffolding.
- **Exit 3 (loud stop)** — an **ambiguous existing** project (unrecognized
  ceremony, or a malformed existing plan). The router emits no `door=`; surface
  the `reason=` and **stop** rather than scaffold over an undetermined state
  (rule 15). An existing-but-broken project is NOT pre-scaffold.
- **Exit 4 (pre-scaffold)** — no manifest here yet (the common greenfield case).
  This is the state init exists for: under `--for init` the
  router returns `match=yes`, so the exit-0 branch above already covers it — you
  are about to write the manifest this guard would have read. **Proceed.**

## Input

$ARGUMENTS

This should be a file path to a PRD, spec, or design document. Read the entire file before proceeding.

If no file path is provided, check the workspace for common spec file patterns: `*spec*`, `*prd*`, `*requirements*`, `*design*` in the root or `docs/` directory. If found, confirm with the user before proceeding. If nothing is found, ask for the file path.

## Process

Read the spec document thoroughly, then generate the project-specific artifacts in
sequence: analyze → **write the manifest** → the three phase docs
(`docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, `docs/PHASE_STATUS.md`) → a rendered
`CLAUDE.md` (from `CLAUDE.template.md`). Each builds on the previous one — do not
generate them in parallel.

**Write the manifest BEFORE the docs (Step 2), not after.** The template ships
`.claude/project.json` defaulted to node/npm with Prettier formatting `.md` files. The
auto-format hook reads that manifest on every write — so if you generate the markdown
docs while the stale default manifest is still live, Prettier will reformat them
mid-generation (e.g. `*x*` → `_x_`), which silently breaks the verbatim
REQUIREMENTS↔PHASE_STATUS deliverable sync this command depends on. Writing the real
manifest first means the correct formatter (or none, for a not-yet-scaffolded project
whose formatter isn't installed) governs doc generation.

### Step 1 — Analyze the Spec

Before writing any files, extract and present a summary for the user to confirm:

**Project identity:**

- Name
- One-sentence description
- Target deployment (web app, CLI, API, library, etc.)

**Tech stack** (infer from the spec, or ask if not specified):

- Language and framework
- Test runner and libraries
- Package manager
- Hosting / deployment target
- Key dependencies and external services

**Phases** (extract from the spec's roadmap/phases, or propose a phasing if the spec doesn't have one):

- Phase name and goal (one sentence each)
- Number of deliverables per phase
- Key dependencies between phases

**Repo topology** (decide explicitly — don't default silently to single-repo):

- **Single-repo** (`roots` both `"."`) — the framework files, docs, and product code share one tree and one history. The proposal for an **internal app** where the sandbox/Makefile/`.claude/` riding along is harmless.
- **Control-plane split** (`roots.code` = a sibling, the named map `{ <product>: { path: "../<product>" } }` with `codePrimary`) — the product lives in its own repo; this control plane holds docs + `.claude/` + the sandbox. **This is the default — proactively propose the split whenever the spec describes a publishable or standalone artifact** ([11.5]; a library, a public CLI, anything that gets its own GitHub repo): otherwise the product's Makefile collides with the sandbox Makefile and the framework files pollute the product's public history. The proposal is mechanical given the product class — `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-stack.sh --greenfield <product> --class publishable` emits exactly this split manifest (`--class internal` emits single-repo), and `bash "${CLAUDE_PLUGIN_ROOT}"/scripts/scaffold-split.sh <code-repo>` lays the split layout down (sibling `<product>-guv` control plane + the code repo provisioned via `provision-code-repo.sh`). Confirm the class with the user and record the topology in `roots`.

**Spec provenance** — if you copy the spec into the repo, follow the "Spec provenance" convention in the `phase-docs` skill (`docs/spec/<original-name>.md` + provenance header), and reference it from the rendered `CLAUDE.md`'s "Project facts" section.

**In interactive mode, wait for the user to confirm or adjust this summary**
(identity, stack, phases, topology) before proceeding to file generation — do not
generate any files until it is confirmed.

**In headless/bypass mode** (an autonomous or piped run with no human to confirm),
present the summary, then **proceed** to generation: the summary is logged in the
session transcript for post-hoc review, and a spec named in the prompt is
**pre-approved scope** (the spec path is the confirmation), so generate from it
rather than blocking on a confirmation no one is present to give — the Rule-15
designed path for an offline operator. This pre-approval needs a spec: in headless
mode with **no spec named** (none in `$ARGUMENTS`, none auto-discovered), there is
nothing pre-approved to build from — take the designed **loud stop** (surface that
no spec was named and halt). Do **not** scaffold a whole project from auto-discovered
guesses, and do **not** fall through to the Input section's "ask for the file path"
gate — no human is present to answer it, and that fall-through is the dead-end this
branch exists to remove. Carry the Step-1 topology proposal forward
as the decision; do not silently re-default to single-repo (the explicit-topology
rule still binds when no human is in the loop).

### Step 2 — Write the Manifest (before any docs)

Write `.claude/project.json` now, before generating the markdown docs (see the Process
note above for why ordering matters). If the workspace already has stack files (e.g. a
`package.json` from prior scaffolding), bootstrap the proposal with the resolver, then
confirm/override its values:

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-stack.sh .   # proposes a manifest from detected stack files
```

If nothing is detectable yet (typical for greenfield before scaffolding), write the
manifest from the Step 1 analysis instead. Either way, validate against
`.claude/project.schema.json` and set: `name`, `language`, `packageManager`, the
`commands` (`null` for any step the stack lacks, including `commands.install` — the
declared remediation run when `readyCheck` fails), `scaffoldCheck` ("does a project
exist" — point at the project manifest file), `readyCheck` ("are the tools installed"
— e.g. `test -d node_modules`, or `null` if tools are global), `formatExtensions`,
`guards` (only what applies), `roots` (per the topology decided in Step 1), and — since
this is greenfield — **`ceremony: "phased"`** (the resolver proposes `"onboard"`;
override it).

Verify the resolver's `readyCheck`/`commands.install` guesses actually match how this
project installs tools — they're heuristics. In particular the Python guess
(`readyCheck: "test -d .venv"`) is wrong for global/conda/system-Python setups; set
`readyCheck` to `null` there. A `readyCheck` with no matching `commands.install` leaves
the not-installed state with no declared fix, so set them together or both to `null`.

After this step the auto-format hook uses _this_ manifest, so the docs generated below
are formatted by the project's own formatter (or left alone if its formatter isn't
installed yet) — not by the stale template default.

### Step 2b — Elicit the context-wall posture ([16.2])

Record the operator's **context-wall mode** in the manifest's `contextManagement` block —
guv's occupancy meter and auto-compaction otherwise conflict at the context wall, so the
mode is **chosen, never silently defaulted** (S1 finding
`docs/spikes/16-1-context-wall-mode.md`). Every fresh scaffold writes the block (its
**presence** is the scaffold-provenance signal), so the project never later masquerades as
a pre-feature one that the migration nudge would grandfather.

- **Interactive — force the choice** (wait for the operator; do not guess a mode):
  `hard-stop` (the meter stops at the setpoint for a clean stop and handoff; auto-compaction
  stood down — full control, no surprise context loss) **or** `continue` (auto-compaction
  compacts and continues across the wall; the meter advisory-only — unattended / long-haul
  runs). Then record it:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}"/scripts/context-management.sh set-mode .claude/project.json <hard-stop|continue>
  ```

- **Headless / bypass — the loud-unset path** (no human to choose): write the explicit
  sentinel rather than guessing a mode. Neither governor is armed and a loud
  `context-wall mode UNSET` marker surfaces at session-open and in the status report until a
  mode is chosen:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}"/scripts/context-management.sh set-mode .claude/project.json unset
  ```

The occupancy meter arms itself from the mode; the auto-compaction window (CLAUDE_CODE_AUTO_COMPACT_WINDOW) is operator-authored in the settings env block — guv never places or strips it ([32.2]).

### Step 3 — Generate docs/REQUIREMENTS.md

Write `docs/REQUIREMENTS.md` following the structure and rules in the **`phase-docs`
skill** (plugin-shipped — shared with `/guv:plan`; the
templates live there, once). This is greenfield: omit the lineage header, number phases
from 1.

### Step 4 — Generate docs/ARCHITECTURE.md

Write `docs/ARCHITECTURE.md` per the phase-docs skill: Phase 1 detailed, later phases
stubbed. Greenfield is a blank slate — skip the skill's initiatives-only
current-state/target-state framing.

### Step 5 — Generate docs/PHASE_STATUS.md

Write `docs/PHASE_STATUS.md` per the phase-docs skill, copying every deliverable
**verbatim** from the REQUIREMENTS.md you just generated, all ⬜.

### Step 5b — Bank the opening forecast ([13.4])

With the tracker written and the manifest `phased`, bank the **opening forecast** —
the cost-to-complete projection for the whole new project, made at project open (n=0
structural, no landings yet). It is the greenfield analog of `/guv:plan`'s opening
forecast and is banked at the same `plan` boundary, so the lineage starts at the
opening forecast and a future initiative-close `grade` settles it ("how good was the
plan?"):

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/projection.sh bank --at plan
```

Idempotent — re-running this door does not double-bank. Greenfield init does not yet
ratify per-deliverable sizing (the [13.2] rubric step `/guv:plan` runs), so this takeoff
leans on the **default** estimate (1 per deliverable) and **discloses** it in
`spine.quantity.default_estimate_ids` — an honest opening forecast, sharpened as
estimates are ratified and landings accrue. (Ratifying sizing here is a [13.2]
follow-up, out of [13.4]'s scope.)

### Step 6 — Render CLAUDE.md

The manifest was already written in Step 2. Now **render the inert template into a live
`CLAUDE.md`** — the template ships as `CLAUDE.template.md` and deliberately does _not_
auto-load; rendering is what makes it govern this project:

1. Read `CLAUDE.template.md`.
2. Fill its placeholders:
   - **Project identity** (top line) — from the Step 1 analysis.
   - **"Project facts Claude can't infer"** — the non-obvious, can't-read-from-code
     facts: required env vars, gotchas, project-specific architectural decisions,
     repository etiquette. Apply the pruning test to each line (_would removing it
     cause a mistake?_); cut anything that doesn't pass.
   - **"Bootstrapping"** — keep this section (this is greenfield): specify the exact
     tools/libraries to install during scaffolding, based on the tech stack.
3. Leave the `.claude/project.json` pointers as-is — commands, behavioral rules
   (loaded natively from `.claude/rules/`), and stack facts are NOT restated in `CLAUDE.md`.
4. Strip the leading `<!-- TEMPLATE … -->` comment block.
5. Write the result to `${roots.control}/CLAUDE.md` (cwd — where Claude Code auto-loads it).

Rules:

- The generator _fills placeholders_; it does not regenerate the template's structure.
- Behavior, TDD discipline, commit conventions → stay in `.claude/rules/`, not `CLAUDE.md`.
- Commands → stay in `.claude/project.json`, never restated in `CLAUDE.md`.
- Add the original spec document to the "Project facts" section as a reference.

### Step 7 — Render the project README

The template ships a guv-facing `README.md` (about guv itself). Replace it
with a **project** README rendered from `README.template.md`:

1. Read `README.template.md`.
2. Fill the `[bracketed]` placeholders from the Step 1 analysis: project name +
   one-liner, the quick-start commands (resolved from `commands.install`/`test`/`dev`),
   and the "Where things live" paths (`roots`). Trim the "Contributing" footer for a
   public artifact if appropriate.
3. **Keep the `<!-- STATUS:START/END -->` markers verbatim** — do not hand-write phase
   numbers between them.
4. Strip the leading `<!-- TEMPLATE … -->` comment block.
5. Write the result to `${roots.control}/README.md` (overwriting the guv README).
6. Populate the initial status block — derive it with the same composer the §3.3
   render hooks use, so the seed matches the line they will regenerate (phase +
   completed/total; the resolver carries no phase name, so the line is leaner than a
   hand-written one — that is the one-parser tradeoff):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-ready.sh docs/PHASE_STATUS.md --json \
     | bash "${CLAUDE_PLUGIN_ROOT}"/scripts/status-line.sh - \
     | bash "${CLAUDE_PLUGIN_ROOT}"/scripts/update-readme-status.sh README.md
   ```

Thereafter the §3.3 render hooks keep that block current — the native PostToolUse hook
regenerates it when a tracker edit lands (e.g. `/guv:handoff` Step 7 marking a deliverable
✅), and a dogfooding control plane's git post-commit hook refreshes it on every tracker
commit. Never hand-edit between the markers.

## After Generation

Present a summary of what was generated:

- **docs/REQUIREMENTS.md** — N phases, N total deliverables
- **docs/ARCHITECTURE.md** — Phase 1 detailed, N phases stubbed
- **docs/PHASE_STATUS.md** — N deliverables tracked
- **.claude/project.json** — manifest for [language/package-manager], `ceremony: phased`
- **CLAUDE.md** — rendered from `CLAUDE.template.md` for [tech stack summary]
- **README.md** — rendered from `README.template.md` (project-facing, with a hook-maintained status block)

Suggest the user review each file, then:

```
git add docs/ .claude/project.json CLAUDE.md README.md
git commit -m "docs: scaffold project from spec"
git checkout -b phase/1-[phase-name]
```

Then they can start their first session with `/guv:phase 1`.
