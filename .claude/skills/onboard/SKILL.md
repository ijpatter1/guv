---
name: onboard
description: "Adopt an existing repository — infer its stack and conventions, write the manifest, and render a live `CLAUDE.md`, without imposing greenfield phase structure."
user-invocable: true
---


Use this for code that **already exists**. Unlike `/init-project` (greenfield, full
phased plan), `/onboard` reads what's there and records it. It does not scaffold new
conventions, and it does not create phase docs. Most real work is on existing code —
this is the path that unlocks it.

## Step 0 — Routing Guard

Ask the deterministic router whether this is the right door (the routing
collapse, [8.1] — manifest + repo state select the entry; no user
disambiguation). The router's exit code is the contract, identical across all
five entry doors:

```bash
bash .claude/route.sh --for onboard
```

- **`match=yes`** (exit 0) — this is the right door; continue. (Either
  `ceremony=onboard` is confirmed, or this is a **pre-scaffold** repo where
  onboard is the manifest-writing door — see exit 4.)
- **`match=no`** (exit 0) — **wrong door: redirect, don't error.** The router
  names the correct door in `door=` — e.g. `door=task` if the repo is already
  onboarded as a scoped project, or `door=next`/`door=phase` if it
  carries a phased plan. Tell the user the routed door and the `reason=`, and
  defer to it.
- **Exit 2** — the router is unavailable/misinvoked (it is absent, a flag is
  wrong, or `jq` is missing). The router is the fast path, not the only one:
  proceed with onboarding.
- **Exit 3 (loud stop)** — an **ambiguous existing** project (unrecognized
  ceremony, or a malformed existing plan). The router emits no `door=`; surface
  the `reason=` and **stop** rather than onboard over an undetermined state
  (rule 15). A genuinely existing-but-broken project is NOT pre-scaffold.
- **Exit 4 (pre-scaffold)** — no manifest here yet (the common first-onboard
  case). Under `--for onboard` the router returns `match=yes`, so the exit-0
  branch above already covers the routing: onboard *is* the door. But onboard
  carries a **scaffold prerequisite** the router does not check — Step 3
  validates the manifest against `.claude/project.schema.json` and Step 4
  renders `CLAUDE.md` from `CLAUDE.template.md`, both laid down by the project
  shell. Running `/onboard` directly on a never-scaffolded repo (no shell on
  disk) dead-ends there. **Detect it deterministically** — the shell is absent
  when `.claude/project.schema.json` or `CLAUDE.template.md` is missing
  (`test -f` either). If absent, **route to `/scaffold` first** — it deploys
  the shell and hands back here (scaffold's Step 3 names `/onboard` as the next
  door). If present (scaffold was run, or a dogfooding control plane synced it
  from source), **proceed** — you are about to write the manifest this guard
  would have read.

> **`/onboard` supersedes Claude Code's native `/init` in guv projects.** `/init`
> inlines commands and stack facts into `CLAUDE.md`, which violates the manifest
> contract (commands live in `.claude/project.json` and are never restated). Run this
> command instead; don't run `/init` in a guv-governed repo.

## Input

$ARGUMENTS

Optionally a path to the code repo. If omitted, assume the current directory is the
code repo (single-repo), or read `roots.code` if a manifest already exists. For a
control-plane/code split, the code repo is the sibling at `roots.code`.

## Step 1 — Detect the Stack (resolver)

Run the stack resolver in `.claude/resolve-stack.sh` against the code root. It sniffs
the repo (lockfiles, manifests) and **proposes** a manifest — `language`,
`packageManager`, `commands`, `scaffoldCheck`, `formatExtensions`, suggested
`guards`, and `ceremony`. Detection only _bootstraps_ the declaration; it never
replaces it.

```bash
bash .claude/resolve-stack.sh "${CODE_ROOT:-.}"
```

Present the proposed values to the user. **Wait for confirmation or overrides** — the
human-confirmed manifest is authoritative from here on. When the project does
something unusual, the human override wins and stays deterministic.

**Already-phased redirect ([10.7]).** The resolver keys `ceremony` on the target
repo's tracker grammar, not a filename guess: if it detects a *live DAG-grammar*
`docs/PHASE_STATUS.md` it proposes **`ceremony=phased`** — the repo is already
planned, and onboarding scaffold would clobber that plan. When the proposal is
`phased`, do **not** scaffold onboard over it: confirm with the user, write the
manifest with the existing plan adopted, and hand off to the phased doors
(`/next` for open work, `/phase` at a boundary) instead of continuing the
onboard scaffold steps below. A token-free (LEGACY) tracker or no phase docs at all
stays `ceremony=onboard` — the unchanged path.

## Step 2 — Infer Existing Conventions

Read the repo to learn how it already works — do not impose a fresh style (the
"Match the codebase's conventions" rule). Look for and note:

- **Test/build/lint/format commands** — confirm the resolver's guesses against the
  actual scripts (e.g. `package.json` scripts, `Makefile` targets, CI config).
- **Directory layout and module conventions** — where source, tests, and config live.
- **Naming, error-handling, and structural patterns** the codebase already follows.
- **Repository etiquette** — branch naming, commit message style, PR conventions.
- **Non-obvious gotchas** — required env vars, setup steps, things that bite.

These become the "Project facts Claude can't infer" section of the rendered `CLAUDE.md`.

## Step 3 — Write the Manifest

Write `.claude/project.json` from the confirmed values, validating against
`.claude/project.schema.json`. Set:

- `roots` — `control` is `"."` (cwd). `code` is `"."` for single-repo, or the sibling
  path for a control-plane split.
- `ceremony` — the resolver's proposal: **`"onboard"`** for a repo with no live plan
  (the common case), or **`"phased"`** when it detected a live DAG-grammar tracker
  ([10.7] — adopt the existing plan; the phased-redirect note in Step 1 applies).
- `guards` — only what applies to this stack (e.g. `["npm-publish"]` for a published
  npm package; omit `gcp` unless the project uses GCP).

### Step 3b — Elicit the context-wall posture ([16.2])

Record the operator's **context-wall mode** in the manifest's `contextManagement` block —
guv's occupancy meter and auto-compaction otherwise conflict at the context wall, so the
mode is **chosen, never silently defaulted** (S1 finding
`docs/spikes/16-1-context-wall-mode.md`). Writing the block on adoption (its **presence**
is the scaffold-provenance signal) keeps the adopted project from later reading as a
pre-feature one that the migration nudge would grandfather.

- **Interactive — force the choice** (wait for the operator; do not guess a mode):
  `hard-stop` (the meter stops at the setpoint for a clean stop and handoff; auto-compaction
  stood down — full control, no surprise context loss) **or** `continue` (auto-compaction
  compacts and continues across the wall; the meter advisory-only — unattended / long-haul
  runs). Then record it:

  ```bash
  bash .claude/context-management.sh set-mode .claude/project.json <hard-stop|continue>
  ```

- **Headless / bypass — the loud-unset path** (no human to choose): write the explicit
  sentinel rather than guessing a mode. Neither governor is armed and a loud
  `context-wall mode UNSET` marker surfaces at session-open and in the status report until a
  mode is chosen:

  ```bash
  bash .claude/context-management.sh set-mode .claude/project.json unset
  ```

Arming the chosen governor is [16.4]; the auto-compaction env carrier is [16.3].

## Step 4 — Render CLAUDE.md (no bootstrapping)

Render the inert template into a live `CLAUDE.md` at `${roots.control}` (cwd, where
Claude Code auto-loads it):

1. Read `CLAUDE.template.md`.
2. Fill its placeholders: project identity (top line) and the "Project facts Claude
   can't infer" section from Step 2.
3. **Omit the "Bootstrapping" section entirely** — the repo is already scaffolded, so
   there is nothing to bootstrap.
4. Leave the `.claude/project.json` pointers as-is (rules load natively from `.claude/rules/`).
5. Strip the leading `<!-- TEMPLATE … -->` comment block.
6. Write the result to `${roots.control}/CLAUDE.md`.

## Step 5 — Reconcile the README (do NOT clobber an existing one)

An existing repo almost always has its own `README.md` — that is the project's, and it
must be respected (the "Match the codebase's conventions" rule). Decide by what's present:

- **The repo's README is the guv template README** (e.g. it still says "Claude Code
  Development Environment" — common when someone copied this template without rendering):
  render `README.template.md` → `README.md` as `/init-project` does, describing what's
  already there, and replace the greenfield line with a one-time status note (below).
- **The repo has its own real project README:** leave its prose alone. Optionally, with
  the user's ok, insert the `<!-- STATUS:START/END -->` marker block near the top (with a
  one-line "developed with guv" note). Never overwrite the file.
- **No README at all:** render `README.template.md` → `README.md` in full.

In an onboarded repo the status block is a **one-time snapshot, not a live view**:
onboard ceremony imposes no phase tracker (Step 6), so the §3.3 render hooks — which
derive the block from `docs/PHASE_STATUS.md` — never fire here, and nothing keeps it
current. If you write the block, populate it once and leave it:

```bash
printf '%s\n' "_Adopted with guv._" \
  | bash .claude/update-readme-status.sh README.md
```

Never edit between the STATUS markers by hand; `update-readme-status.sh` owns that region
and no-ops safely when the markers are absent.

## Step 6 — Do NOT Impose Phase Structure

Crucially: **do not create `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, or
`docs/PHASE_STATUS.md`.** Onboard mode has no phase ceremony. From here, scoped work
runs through `/task`; `/phase` and the phased machinery stay dormant (they
no-op when `ceremony != "phased"`). If the project later needs a multi-phase
initiative, the sanctioned route is `/plan <spec>` — it generates the
phase docs and flips ceremony deliberately, which is different from onboard imposing
them.

## After Onboarding

Present a short summary:

- **Stack:** language + package manager + commands detected and confirmed
- **Conventions recorded:** the key facts written into `CLAUDE.md`
- **Topology:** single-repo, or control-plane + code split with `roots.code` set
- **Next:** "Make scoped changes with `/task \"<description>\"`."

Then commit: the manifest and rendered `CLAUDE.md` are doc/control-plane artifacts, so
commit them in the control plane (`git -C "$(jq -r '.roots.control' .claude/project.json)"`):

```
git add .claude/project.json CLAUDE.md
git commit -m "chore: onboard project — manifest + CLAUDE.md from existing repo"
```
