Adopt an existing repository — infer its stack and conventions, write the manifest, and render a live `CLAUDE.md`, without imposing greenfield phase structure.

Use this for code that **already exists**. Unlike `/init-project` (greenfield, full
phased plan), `/onboard` reads what's there and records it. It does not scaffold new
conventions, and it does not create phase docs. Most real work is on existing code —
this is the path that unlocks it.

## Input

$ARGUMENTS

Optionally a path to the code repo. If omitted, assume the current directory is the
code repo (single-repo), or read `roots.code` if a manifest already exists. For a
control-plane/code split, the code repo is the sibling at `roots.code`.

## Step 1 — Detect the Stack (resolver)

Run the stack resolver in `.claude/resolve-stack.sh` against the code root. It sniffs
the repo (lockfiles, manifests) and **proposes** a manifest — `language`,
`packageManager`, `commands`, `scaffoldCheck`, `formatExtensions`, and suggested
`guards`. Detection only _bootstraps_ the declaration; it never replaces it.

```bash
bash .claude/resolve-stack.sh "${CODE_ROOT:-.}"
```

Present the proposed values to the user. **Wait for confirmation or overrides** — the
human-confirmed manifest is authoritative from here on. When the project does
something unusual, the human override wins and stays deterministic.

## Step 2 — Infer Existing Conventions

Read the repo to learn how it already works — do not impose a fresh style (RULES.md
rule 6). Look for and note:

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
- `ceremony` — **`"onboard"`**.
- `guards` — only what applies to this stack (e.g. `["npm-publish"]` for a published
  npm package; omit `gcp` unless the project uses GCP).

## Step 4 — Render CLAUDE.md (no bootstrapping)

Render the inert template into a live `CLAUDE.md` at `${roots.control}` (cwd, where
Claude Code auto-loads it):

1. Read `CLAUDE.template.md`.
2. Fill its placeholders: project identity (top line) and the "Project facts Claude
   can't infer" section from Step 2.
3. **Omit the "Bootstrapping" section entirely** — the repo is already scaffolded, so
   there is nothing to bootstrap.
4. Leave the `@.claude/RULES.md` import and the `.claude/project.json` pointers as-is.
5. Strip the leading `<!-- TEMPLATE … -->` comment block.
6. Write the result to `${roots.control}/CLAUDE.md`.

## Step 5 — Reconcile the README (do NOT clobber an existing one)

An existing repo almost always has its own `README.md` — that is the project's, and it
must be respected (RULES rule 6). Decide by what's present:

- **The repo's README is the harness template README** (e.g. it still says "Claude Code
  Development Environment" — common when someone copied this template without rendering):
  render `README.template.md` → `README.md` as `/init-project` does, describing what's
  already there. (The one greenfield line, `_Status: not yet scaffolded._`, is replaced
  by the status block update in the next step anyway.)
- **The repo has its own real project README:** leave its prose alone. Only ensure a
  maintained status block exists — if it has the `<!-- STATUS:START/END -->` markers,
  the next step updates them; if not, offer to insert the marker block (with a one-line
  "developed with the Claude Code harness" note) near the top, but only with the user's
  ok. Never overwrite the file.
- **No README at all:** render `README.template.md` → `README.md` in full.

In all cases, never hand-edit between the STATUS markers; `update-readme-status.sh`
owns that region and no-ops safely when the markers are absent.

## Step 6 — Do NOT Impose Phase Structure

Crucially: **do not create `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, or
`docs/PHASE_STATUS.md`.** Onboard mode has no phase ceremony. From here, scoped work
runs through `/task`; `/start-phase` and the phased machinery stay dormant (they
no-op when `ceremony != "phased"`).

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
