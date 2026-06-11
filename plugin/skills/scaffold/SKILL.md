---
description: "Scaffold the harness project shell into the current directory — templates, manifest schema, settings, rules, .gitignore, optional Docker tier — replacing the template-clone step. Use on a fresh or existing repo before /guv:init-project, /guv:onboard, or /guv:plan-initiative; safe to re-run after a plugin update to refresh harness-owned files."
---

# Scaffold — Project Shell from the Plugin

Deploy everything a harness-governed project needs on disk. The plugin carries
the durable core (skills, agents, hooks, scripts) in its own directory; this
skill lays down the **project shell** — the files that must live in the
project: doc templates, the manifest schema, permission settings, the rules
files, `.gitignore`, and (opt-in) the Docker isolation tier.

## Step 0 — Preconditions

- If the directory is not a git repository, ask whether to `git init` first
  (recommended) or proceed without.
- If `.claude/project.json` already exists, this project is already
  scaffolded: say so, and note that re-running is still useful — it refreshes
  the harness-owned files (templates, schema, rules) after a plugin update
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
Ownership is enforced by the script: harness-owned files refresh on re-run;
`.claude/settings.json`, `.gitignore` content, and Docker-tier files are
consumer-owned after first deploy; the manifest, `CLAUDE.md`, and `docs/` are
never written by it.

## Step 2 — Manifest via the resolver

Propose the manifest from the detected stack:

```
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/resolve-stack.sh .
```

Present the proposal to the user, confirm or adjust (it is a PROPOSAL — never
write it unconfirmed), then write the result to `.claude/project.json`
following `.claude/project.schema.json`. For an empty greenfield directory the
resolver will propose mostly nulls — that's correct; `/guv:init-project` will
refine identity, topology, and ceremony from the spec (null means skip, never
guess).

## Step 3 — Hand off

The entry commands work unchanged on top of the deployed shell:

- **Greenfield with a spec:** `/guv:init-project <spec>` — identity questions,
  phase docs, rendered `CLAUDE.md` (from the deployed `CLAUDE.template.md`)
- **Existing codebase:** `/guv:onboard` — infers conventions, finalizes the
  manifest, renders `CLAUDE.md` without imposing phase structure
- **New initiative on an existing project:** `/guv:plan-initiative <spec>`

Tell the user which applies to their situation and stop — scaffolding ends
here; project setup belongs to those commands.
