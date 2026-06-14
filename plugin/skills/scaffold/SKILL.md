---
description: "Scaffold the guv project shell into the current directory — templates, manifest schema, settings, rules, .gitignore, optional Docker tier — replacing the template-clone step. Use on a fresh or existing repo before /guv:init-project, /guv:onboard, or /guv:plan; safe to re-run after a plugin update to refresh core-owned files."
---

# Scaffold — Project Shell from the Plugin

Deploy everything a guv-governed project needs on disk. The plugin carries
the durable core (skills, agents, hooks, scripts) in its own directory; this
skill lays down the **project shell** — the files that must live in the
project: doc templates, the manifest schema, permission settings, the rules
files, `.gitignore`, and (opt-in) the Docker isolation tier.

## Step 0 — Preconditions

- If the directory is not a git repository, ask whether to `git init` first
  (recommended) or proceed without.
- If `.claude/project.json` already exists, this project is already
  scaffolded: say so, and note that re-running is still useful — it refreshes
  the core-owned files (templates, schema, rules) after a plugin update
  while leaving everything consumer-owned untouched. Skip Step 2 (the manifest
  exists; don't propose a new one).

## Step 1 — Deploy the shell

Ask the user whether they want the **Docker tier** (full environment
reproducibility, `--dangerously-skip-permissions` autonomy, or platforms
without native sandbox support — the opt-in isolation tier; the default tier
is the native sandbox, which needs no extra files). Then run:

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/scaffold-shell.sh            # default tier
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/scaffold-shell.sh --docker   # + Docker tier
```

The script reports created / refreshed / kept files — relay that summary.
Ownership is enforced by the script: core-owned files refresh on re-run;
`.claude/settings.json`, `.gitignore` content, and Docker-tier files are
consumer-owned after first deploy; the manifest, `CLAUDE.md`, and `docs/` are
never written by it.

## Step 2 — Manifest via the resolver

Propose the manifest from the detected stack:

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-stack.sh .
```

Two outcomes:

- **The resolver proposes a manifest** (it detected a known stack): present
  the proposal to the user, confirm or adjust (it is a PROPOSAL — never write
  it unconfirmed), then write the result to `.claude/project.json` following
  `.claude/project.schema.json`.
- **The resolver exits 2 — "Could not detect a known stack"** (empty
  greenfield directory, or an unrecognized stack): write **no manifest**.
  Null means skip, never guess. For greenfield, `/guv:init-project` declares
  identity, topology, and ceremony from the spec and writes the manifest
  itself; for an unrecognized existing stack, `/guv:onboard` walks the schema
  with the user by hand.

## Step 3 — Hand off

The entry commands work unchanged on top of the deployed shell:

- **Greenfield with a spec:** `/guv:init-project <spec>` — identity questions,
  phase docs, rendered `CLAUDE.md` (from the deployed `CLAUDE.template.md`)
- **Existing codebase:** `/guv:onboard` — infers conventions, finalizes the
  manifest, renders `CLAUDE.md` without imposing phase structure
- **New initiative on an existing project:** `/guv:plan <spec>`

Tell the user which applies to their situation and stop — scaffolding ends
here; project setup belongs to those commands.
