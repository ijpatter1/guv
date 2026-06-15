# Changelog

Governor (guv) plugin releases. **A version bump is a release** — plugin consumers
update only when the manifest version changes, so every consumer-visible change
ships under a bump. The bump policy and release checklist live in
`maintainers/RELEASING.md`.

## 0.4.0 — 2026-06-15

Minor release: the **build fan-out becomes a first-class, code-repo-agnostic driver**
(Phase 10 complete). Phase 7 shipped the deterministic JOIN and the gated queue but
left the EXECUTION and GATE stages an unscripted manual job; [10.9] adds the door, and
[10.10] makes the machinery work on a code repo that is not itself a guv install (the
prior machinery only worked by self-hosting accident). Additive — existing single-repo
planes are unaffected. One behavior change in lane confinement; see migration notes.

### Added

- **`/build-fanout`** — the build-fanout GATE workflow (the build-half analog of
  `/eval-parallel`) + a runbook skill (the first-class door). Over a list of built lanes
  it assembles each lane's acceptance bundle and runs the calibrated `evaluator` +
  `reviewer` by name, carrying the lane↔join responsibility split, and returns structured
  per-lane verdicts with a convergence (all Critical/Major closed) clear-to-land flag.
- **`lane-builder` agent** — the calibrated writer subagent for a fan-out lane: red→green
  TDD confined to source, acquires the behavioral core natively (an Agent-tool subagent
  inherits `CLAUDE.md` + the `guv-*` rules) and preloads the `task` skill.
- **`provision-code-repo.sh`** — makes an arbitrary (foreign) code repo a guv lane
  target: a deploy-once `ceremony=task` manifest + the marker-idempotent guv-core
  `.gitignore`, committed so lane worktrees inherit it. Idempotent / no-clobber — an
  already-provisioned repo is left untouched.
- **Manifest `lanes.protectedProse`** — opt-in per-repo confinement of project-specific
  join-owned prose/derived trees (schema-validated array of path patterns).

### Changed

- **`guv-lane create` asserts provisioning** — it loud-stops (Rule 15, naming the
  remedy) if the code repo has no committed `.claude/project.json`, rather than silently
  creating a lane a builder can't route work in.
- **Lane confinement is control-plane-configurable.** Only the single-writer trackers
  (`docs/PHASE_STATUS.md`, `docs/REQUIREMENTS.md`) are universally protected from a direct
  lane edit; the join-owned prose set (CHANGELOG/README/`plugin/`) moves to the opt-in
  `lanes.protectedProse`. Default is none, so a consumer's own README is lane-editable.
- **`build-plugin.sh` ships + namespaces every workflow and every agent** (derived from
  the source tree) — `@`/backtick agent mentions and `skills:` preloads alike — not a
  hardcoded pair, so a new workflow or agent can't ship un-namespaced.

### Migration notes

- **Lane confinement default changed.** A consumer that ran build fan-outs and relied on
  the previously-hardcoded protection of `CHANGELOG`/`README`/`plugin/` should set
  `lanes.protectedProse` in the control-plane manifest to keep refusing direct lane edits
  to those surfaces (guv's own control plane does). Single-repo / non-fan-out planes are
  unaffected.

## 0.3.0 — 2026-06-14

Minor release: the **[8.3] plan-as-data restructure** — the verb grammar ratified
at [8.2] is applied across the surface. Breaking-while-0.x, so a minor bump per
`maintainers/RELEASING.md`. Seven commands/skills/agents are renamed, `commands/`
is flattened into `skills/`, three single-owner scripts are bundled into the skills
that own them, three status/session surfaces become native hooks, and the legacy
noun "harness" is retired in favor of `guv` (the product) and `core` (the installed
machinery). `--sync` migrates already-synced consumers automatically where it can;
the rest is in the migration notes below.

### Changed

- **Renames (the [8.2] verb grammar):** `/start-phase`→`/phase`,
  `/plan-initiative`→`/plan`, `/resume`→`/next` (the provisional name retired),
  `/evaluate`→`/eval`, `/log-feedback`→`/feedback`,
  `/evaluate-parallel`→`/eval-parallel`, and the `product-reviewer` agent→`reviewer`
  (`guv:product-reviewer`→`guv:reviewer`).
- **Flatten:** the `.claude/commands/` tree is gone — every command is now a skill
  under `.claude/skills/`. `--sync` prunes a consumer's stale `commands/`.
- **Bundle:** `extract-eval-report.sh`, `feedback-submit.sh`, and
  `check-citations.sh` move from top-level `.claude/` into the `scripts/` dir of the
  owning skill (eval, feedback, status). `--sync` prunes the old top-level copies.
- **Hooks:** session-open route/frontier surfacing and status-view regeneration
  (status.html + the README status block) are now native SessionStart / PostToolUse
  / post-commit hooks instead of hand-invoked steps.
- **Noun retirement:** "harness" is retired across the surface — `guv` for the
  product, `core` for the installed machinery — with the ratified Vocabulary block
  placed in the README.

### Migration notes for existing template-clone projects

- **Skill/agent renames:** the old names (`/guv:start-phase`, `/guv:plan-initiative`,
  `/guv:resume`, `/guv:evaluate`, `/guv:log-feedback`, `/guv:evaluate-parallel`,
  `guv:product-reviewer`) no longer resolve — use the new names above. Update any
  hand-written reference to an old skill or agent.
- **`run-harness-tests.sh`→`run-core-tests.sh`:** the generated test runner is
  renamed. `--sync` regenerates it under the new name, but a hand-written
  `commands.test` in `.claude/project.json` that still names `run-harness-tests.sh`
  breaks — point it at `run-core-tests.sh`.
- **Post-commit hook marker `Harness-owned`→`Core-owned`:** migrated automatically —
  `--sync` accepts the old marker and rewrites it. No action needed.
- **`.gitignore` marker `guv-harness-gitignore`→`guv-gitignore`:** recognized
  automatically — a re-scaffold/sync no longer duplicates the core block. No action
  needed.
- **CI job `harness-tests`→`core-tests`:** the maintainer workflow's job id is
  renamed. A branch-protection required-status-check named `harness-tests` must be
  updated in the repo's GitHub settings — a renamed check reads as a new,
  unsatisfied one.

## 0.2.0 — 2026-06-14

Minor release: the harness-hardening wave — eight additive capabilities groomed
from the open feedback backlog and built as a single Phase-10 fan-out (built →
calibrated dual-review → fix-loop → joined through the gated merge queue, full battery green,
stderr-clean). The `v0.2.0` tag lands on the default-branch release
commit, merge-before-tag.

### Added

- [10.1] Phase-docs grammar surface: the skill now quotes the canonical `DEPS_RE` deps-token regex verbatim (naming resolve-ready.sh / replan.sh / archive-initiative.sh as its source of truth, guarded byte-identical by a new suite), the marker set gains a fifth `🔒` human-gated / awaiting-manual marker (tracked in `docs/manual/`) that the `status` and `handoff` counters report as its own category, and the published contract surface (tracker grammar + status.json shape) carries a `contract_version` marker emitted by `resolve-ready.sh --json`.
- [10.2] Manifest language truthfulness: `project.schema.json`'s `language` enum gains `shell` (bash/jq/git projects) mapped to the plain `debian:bookworm-slim` base image with no language-specific firewall registry; guv's own manifest and the one `setup-control-plane.sh` generates now read `shell` not `node`, and guv's `commands.test` is the first-class `for t in .claude/tests/*.test.sh` bash runner instead of the inherited `npm test`.
- [10.3] build-plugin.sh now ships the consumer-meaningful test suites into plugin/tests/ with a layout-reconstructing runner (run-plugin-tests.sh) that rebuilds a .claude/-shaped tree from the flattened scripts/, so the location-relative suites run unmodified in a plugin install; plugin.test.sh asserts the shipped suite runs green in plugin layout.
- [10.5] Tooling ergonomics: `extract-eval-report.sh` decodes the evaluate-parallel workflow's nested on-disk output and surfaces the full combined report untruncated (feedback 447210968); `/task` Step 1 gains a Chore/Maintenance classification routing control-plane doc-format/migration changes to approve-then-write with no TDD test.
- [10.7] /onboard detects a live DAG-grammar `docs/PHASE_STATUS.md` in the target repo and proposes `ceremony=phased` (adopting the existing plan) instead of hardcoding `onboard`; a token-free (LEGACY) tracker or no phase docs stays `onboard` unchanged. Detection keys on the tracker grammar via resolve-ready.sh, not a filename guess.
- [10.8] `/log-feedback` gains a `submit` mode (`.claude/feedback-submit.sh`) that drains open `routing: upstream` feedback entries into the guv source repo as issue drafts — deduped by entry id, with a draft marker written back so a re-run is a no-op. Issue filing stays user-gated (the agent drafts and emits `gh issue create`; the user files); `--dry-run` lists without writing, and the transport degrades loudly if the tracker is unreachable.

### Changed

- [10.4] /handoff references /evaluate's dual-review procedure by pointer instead of inlining its steps (killing the restatement drift class), and the session-close review is skipped — with the skip disclosed — when every session commit was already dual-reviewed in-band via /task + /evaluate; an un-reviewed commit still runs the review.
- [10.6] Occupancy meter default is now context-window aware: derived from the model the transcript reports (3/4 of its window — 750000 for a 1M-window model, 150000 for the standard 200000 window), with a documented 150000 fallback when no model signal is visible, so a large-context model no longer meters every turn. Explicit `occupancy.threshold` still overrides; silent-below-threshold unchanged.

## 0.1.2 — 2026-06-13

Patch release: a backlog-clearing wave of fixes to already-shipped assets, drawn
from dogfooding/UAT friction not addressed by planned work. No new surface and no
contract change. The `v0.1.2` tag lands on the default-branch merge commit (PR #19),
per the merge-before-tag step.

### Fixed

- **bash-guard**: the root-deletion guard was an unanchored substring match that
  blocked *any* absolute-path `rm -rf` (e.g. a lane agent cleaning a scratch dir
  under `/private/tmp`). Re-anchored to the filesystem root, a system-directory
  denylist, and the whole-directory form of scratch-bearing roots (`/home`,
  `/var`, `/mnt`, `/media`); absolute scratch subpaths are no longer blocked while
  every catastrophic root stays blocked.
- **merge-queue**: `lane_state` called `die` inside a command substitution, so an
  unknown lane id limped on with raw git errors instead of stopping loud; it now
  returns and the caller stops in the main shell.
- **lane-dispatch**: `dispatch` now destroys each successfully-landed lane (the
  lifecycle ends at destroy, no more accumulating worktrees/branches), and
  `harvest` emits a non-fatal advisory when a lane diff carries build artifacts.
- **scaffold**: a split project's control-plane `.gitignore` now ignores the
  fan-out scratch (`.lane-reports/`) on both create and `--sync`; the manifest
  `commands` schema documents that commands run from the control plane (a split
  `commands.test` must resolve `roots.code` itself).
- **test suites**: removed `echo | grep -q` SIGPIPE races that could trip the
  strict empty-stderr gate, and made the plugin drift-guard fixtures self-heal a
  leftover instead of failing the battery.

### Changed

- The `evaluator` and `product-reviewer` agents now mandate returning the full
  report as their final message (not a memory pointer).
- `RELEASING.md` and the `log-feedback` skill document that issue filing is
  user-gated (the agent drafts, the user files).
- `/start-phase` and `/replan` name the headless draft-and-defer path; `/replan`
  documents how to create a new phase header (the one tracker mutation the engine
  does not own).

## 0.1.1 — 2026-06-11

Patch release: review-wave fixes to already-shipped assets. **This is the first
release actually served to consumers** — see the 0.1.0 note below. Its `v0.1.1`
tag lands on the default-branch merge commit once PR #8 merges, per the release
checklist's merge-before-tag step (added in this same wave after the 0.1.0
ordering deviation).

### Fixed

- Scaffold-deployed `Makefile`: the GCP service-account example no longer
  carries the pre-rename `claude-code-sandbox` name.
- Maintainer CI is rename-safe: the repo-pinned workflow accepts both the old
  and new slugs until the rename lands (then collapse to `ijpatter1/guv`).
- Suite hygiene: the empty-stderr gate is enforced by the test runner and CI
  (any suite stderr fails the run); consumer forks that delete `plugin/`,
  `.claude-plugin/`, or `maintainers/` get clean suite skips, not failures.

### Release-integrity note

- Tag `v0.1.0` was created before the merge-before-tag checklist step existed
  and points at a pre-merge commit that was never served from the default
  branch; a consumer-shipped file changed after that tag without a bump. v0.1.0
  was therefore never installable and is superseded by 0.1.1 wholesale. Issue
  #7's closing comment names v0.1.0; the fix it references reaches consumers
  in 0.1.1.

## 0.1.0 — 2026-06-11

First versioned release: the durable core packaged as the **Governor (`guv`)
plugin**, installable from this repo's personal marketplace. Template-clone
remains supported as the fallback path.

### Added

- The guv plugin (`plugin/`, generated by `maintainers/build-plugin.sh`):
  every harness command and skill as `/guv:`-namespaced skills (`/guv:status`,
  `/guv:handoff`, `/guv:start-phase`, …), both calibrated reviewer agents
  (resolving as `guv:evaluator` / `guv:product-reviewer`), the three hooks with
  the reviewer read-only guard relocated to `hooks/hooks.json`, the `guv-*`
  rules files and helper scripts as plugin assets, the `/guv:evaluate-parallel`
  workflow (skill-fronted, `${CLAUDE_PLUGIN_ROOT}` launch), and the
  `/guv:zen` easter egg.
- `/guv:scaffold` — deploys the project shell (manifest via the resolver, docs
  skeletons, gitignore block, optional Docker tier) without cloning the
  template repo.
- Personal marketplace at `.claude-plugin/marketplace.json` (install:
  `claude plugin marketplace add ijpatter1/guv`, then install the `guv` plugin).
- The feedback drain is live: `routing: upstream` entries become issues/PRs and
  flip to `graduated` on the release that ships the fix (`maintainers/RELEASING.md`).

### Fixed

- `check-citations.sh` no longer flags all-decimal tokens (feedback-entry id
  suffixes) as unresolvable commit hashes (#7). Drains feedback entry
  `2026-06-10T23:11:39Z-199208882` — the worked feedback-drain example.

### Migration notes for existing template-clone projects

- **Phase 2 (rules migration):** rendered `CLAUDE.md` files in existing projects
  may still carry the dead `@.claude/RULES.md` import line — delete it. Rules
  now load natively from `.claude/rules/`; the import target no longer exists
  after a sync.
- **Phase 3 (sandbox repositioning):** rendered `CLAUDE.md` Enforcement bullets
  predate the tier split — rewrite them to the tier-neutral wording from
  `CLAUDE.template.md`: the isolation tier (native sandbox or Docker) is the
  spatial boundary; the hooks are the semantic layer within it.
