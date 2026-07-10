# Changelog

Governor (guv) plugin releases. **A version bump is a release** — plugin consumers
update only when the manifest version changes, so every consumer-visible change
ships under a bump. The bump policy and release checklist live in
`maintainers/RELEASING.md`.

## 0.10.0 — 2026-07-10

Minor release (0.x): **a `--only <pattern>` suite filter on the shipped plugin-test
runner ([22.1]) — single-suite verification without the full-battery price — plus
strict argument handling on the same runner.** This is also the first release cut
from the **public** marketplace: the [8.4] go-public flip executed 2026-07-10
(a marketplace-level change, live independent of any version bump — recorded here
so the release trail carries it).

### Added

- **`--only <pattern>` suite filter on `tests/run-plugin-tests.sh`** ([22.1]) — run
  just the shipped suites whose basename matches the glob, e.g.
  `bash <plugin>/tests/run-plugin-tests.sh --only 'route*'`. The layout
  reconstruction stays FULL — the filter gates suite *execution*, never the
  rebuild — so placement probes keep their meaning under a filtered run. A pattern
  matching no suite fails loud (exit 2, naming the pattern), and an empty pattern
  is refused rather than silently degrading to a full-set run — never a vacuous
  green. Measured in the dogfood battery: the ship-suite probe wall dropped
  258s → ~103s.

### Changed

- **`run-plugin-tests.sh` refuses unknown arguments** — exit 2 naming the argument
  and the supported flag (previously any argument was silently ignored), so a
  typo'd flag can't buy a full-set run that reads as the filtered one you asked
  for.

## 0.9.0 — 2026-06-29

Minor release (0.x): **the exploration ceremony (Phase 21) — a `spike` entry door for
free-form work that has no phase DAG — plus two execution-surface additions (the fan-out
decision scaffold and a calibrated vet for generated artifacts).** The headline is the
`spike` ceremony: route/scope/close machinery for exploratory work the phased ceremony
couldn't express, closed by a findings-drain that turns a spike into a recorded finding.
All additive: a project that never runs a spike keeps its prior behavior unchanged.

### Added

- **The `spike` exploration ceremony** (Phase 21) — a fifth entry door, for free-form
  exploration that has no phase DAG to resolve:
  - the additive `ceremony: spike` schema enum value ([21.2]) — existing `task` / `onboard`
    / `phased` projects validate unchanged;
  - the `route.sh` spike arm + the `/spike` skill, short-circuiting to `door=spike` ahead of
    the resolver, with a timeboxed-budget path when no budget is set ([21.3]);
  - the four scope-knowing doors (`/next`, `/phase`, `/replan`, `/task`) made spike-aware —
    each names `/spike` and redirects free-form exploratory work to it rather than forcing it
    into a phase or a scoped task ([21.4]);
  - the findings-drain close — a spike ends by draining its findings into a recorded finding,
    with a declared-not-gated undrained-finding notice (a loud-but-non-blocking exit-0 rung)
    ([21.5]);
  - the spike-finding convention doc — the ordered seven-part finding shape (header → why →
    asymmetry → per-question Evidence→Decision → designed default + loud path → what it gates →
    watch-items), shipped as a skill-sibling the `spike` skill points at ([21.6]).
- **Fan-out decision scaffold** ([17.2]) — a scaffold for the call of when to fan work out
  across parallel agents versus keep it serial, so the decision is made deliberately rather
  than by reflex.
- **Calibrated vet for generated artifacts** ([18.2]) — generated artifacts (UAT plans, manual
  cards) route through a calibrated single-reviewer vet invoked by name, declared-not-gated and
  stamped with its verdict; an artifact whose vet cannot run degrades loudly to UNVETTED rather
  than reading as silently passed.

## 0.8.1 — 2026-06-28

Patch: a cold-path-correctness fix to a shipped script, surfaced by the Phase 23
UAT's own dual-eval (the same go-public hardening class as 0.8.0's Phase 23 batch).

### Fixed

- **`route.sh` empty-frontier reason on a descoped plane** — when an initiative
  completed *with a descoped deliverable* (a terminal `❌` from `/replan`), the
  session-start router's boundary explanation hardcoded "every deliverable is ✅",
  which is factually wrong — one was descoped, not done. The routing *decision* was
  always correct (`door=phase`, the boundary/next-decision door); only the
  human-facing `reason=` lied. It now reads "every deliverable is terminal (✅ done
  or ❌ descoped)", matching the code's own adjacent comment. The live dogfooding
  tracker already carries a descoped `❌ [20.3]`, so this would have misled at the
  next initiative close. `route.test.sh` gains a descoped-complete case (red→green).
- **Empty-frontier explanation swept to its sibling surfaces** — the same "every
  deliverable is ✅" framing also appeared, byte-identical, in the `/next` skill's
  empty-frontier bullet (user-facing — the door a person actually meets mid-phase)
  and in `archive-initiative.sh`'s header comment (which contradicted its own body
  at line 42). Both now acknowledge descoped terminals, so the explanation reads
  consistently wherever it surfaces, not only in `route.sh`'s emitted reason. A new
  maintainer suite (`empty-frontier-framing.test.sh`) pins the canonical terminal-aware
  stem across all three surfaces, so a future drift fails loud instead of surviving
  byte-identically into a doc mirror the way this one did.

## 0.8.0 — 2026-06-27

Minor release (0.x): **context-management posture (Phase 16) + a broad cold-path-correctness
hardening pass (Phases 19, 20, 23) found by dogfooding toward go-public.** The additive headline
is the context-management posture: scaffold/onboard now elicit how a project manages the context
wall and carry the chosen setpoints. The bulk is correctness — the entry doors, hooks, archival,
feedback drain, and stack detection all hardened against the off-happy-path states a real
split-topology install hit while dogfooding guv through the plugin. All additive or corrective:
a project that never elicits a context-management posture keeps its prior behavior unchanged.

### Added

- **Context-management posture** ([16.2]) — scaffold/onboard elicit the operator's context-wall
  posture and write it as an additive `contextManagement` manifest block (schema-validated):
  an interactive forced-choice prompt, a headless loud-unset path, and an existing-project
  migration nudge.
- **Auto-compaction carrier** ([16.3]) — when continue-mode is chosen, the
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is scaffolded into a gitignored `settings.local.json`.
- **Meter ↔ auto-compaction reconciliation** ([16.4]) — deterministic arm/disarm so exactly one
  threshold is authoritative (hard-stop: setpoint armed, compaction window unset; continue:
  window set, meter advisory-only), plus a one-shot warn-band approach warning; the chosen
  governor is guided into place, not auto-armed.
- **Mechanized feedback triage** ([15.4]) — a `feedback.sh` helper for log triage (list / group
  / status flips) replacing hand-edited NDJSON surgery.
- **Local-only feedback posture made legible** ([20.7]) — the opt-in/local-only stance is stated
  in the surface, and the friction log loads at session start.

### Fixed

- **Cold-path correctness — go-public blockers** (Phase 19): a placeholder-only tracker reads
  NONE rather than INCOMPLETE ([19.1]); onboard's pre-scaffold exit-4 routes to scaffold first
  ([19.2]); init-project gets a headless present-and-proceed branch with a loud stop on
  headless+no-spec ([19.3]); hook registrations anchor to `$CLAUDE_PROJECT_DIR` so the safety
  hooks fire off-root ([19.4]); hook registration dedups when the plugin is also installed
  ([19.5]); `replan` sync-check rejoins wrapped REQUIREMENTS deliverables.
- **Cold-path correctness II — dogfood-surfaced** (Phase 23): the entry-door router reaches the
  boundary doors on first entry to a freshly-planned phase and on a skeleton-scaffolded greenfield
  ([23.1]); the upstream feedback drain resolves `roots.sh` under the plugin-cache layout, not only
  the template layout ([23.2]); `archive-initiative` treats a descoped/abandoned ❌ deliverable as
  terminal, so a genuinely-complete initiative archives without `--force` ([23.3]).
- **Evaluator read-only guard anchored to command position** ([20.1]) — benign redirects and
  wrappers no longer evade the guard; residual disclosure split by direction.
- **Scaffold metering hygiene** ([20.2]) — the transient metering runtime artifact is gitignored;
  the keep/ignore split is proven against git, not a proxy.
- **Stack detection** ([20.6]) — `resolve-stack` distinguishes pyproject from requirements and
  detects the absence of ruff.
- **Battery harness** ([15.1]) — fixture-collision resolved before parallelism, a loud no-timeout
  path, and the core-test gate-integrity holes closed.
- **Lone-deliverable carve reconciliation** ([15.7]) — the three completion oracles (resolver,
  replan, archive) agree on a spike-gated lone-deliverable phase as open-until-sealed; handoff's
  inherited `confirm()` guards against a non-interactive vacuous pass.

### Changed

- **Handoff procedure slimmed** — bulky reference split out of the resident procedure ([20.5]); the
  rendered CLAUDE.md Bootstrapping section self-removes past scaffold ([20.4]).
- **Go-public criterion (b) reframed** in `RELEASING.md` (public-distribution dogfooding) with an
  explicit cold-read exclusion.

## 0.7.0 — 2026-06-19

Minor release (0.x): **Phase 14 — autonomous context management.** A session now holds its
working context across compactions with no human driving `/compact` or `/clear`: a calibrated
setpoint fires proactive compaction before the model's hard limit, a PreCompact hook
checkpoints the in-flight state, and a SessionStart(compact) hook re-injects it so the model
resumes the active deliverable in place — with a CLAUDE.md-survival floor under the loop and a
loud-stop fallback ladder. Lane recovery extends the same continuity to build-fanout workers.
All additive: a plane with no deployed setpoint keeps its prior behavior unchanged.

### Added

- **Compaction setpoint** ([14.2]) — `compaction-setpoint.sh` deploys a human-authored
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (read by Claude Code at launch — a hook cannot set it), and
  its `check` verb reports the deployed posture; proactive compaction fires at the calibrated
  window, well before the model's hard limit.
- **PreCompact checkpoint** ([14.3]) — `continuation-checkpoint.sh` persists the continuation
  state (active deliverable, code-repo git HEAD + dirty paths, transcript pointer) to
  `.claude/continuation-checkpoint.json` before compaction proceeds. Schema
  `guv.continuation-checkpoint/1`.
- **SessionStart re-injection** ([14.4]) — `continuation-resume.sh` reads the checkpoint on
  `source=compact` and re-injects the continuation map via
  `hookSpecificOutput.additionalContext`, so the continuing model resumes in place with no
  human re-priming.
- **Lane recovery** ([14.5]) — `lane-recovery.sh` (`detect` / `assess` / `respawn`) recovers a
  build-fanout lane interrupted by a compaction, with a loud-stop verdict for an unrecoverable
  lane.
- **The autonomous setpoint loop** ([14.6]) — the four pieces wired into one self-sustaining
  loop (compact-at-setpoint → checkpoint → re-inject → continue). The checkpoint reconciles the
  in-flight deliverable against the resolver pick and measures git on `roots.code` (the
  deliverable repo), carrying `code_root` as an additive schema field for split topologies; the
  resume surfaces the setpoint posture. Single-repo planes fall to the unchanged wording.
- **PreCompact + SessionStart(compact) hook registrations** in the scaffolded `settings.json`.

## 0.6.0 — 2026-06-18

Minor release (0.x): **Phase 13 — the meter operationalized and calibrated, on a
throughput-native projection.** Cost is denominated in throughput (not occupancy); each
deliverable's burn is a bounded per-session slice rather than the cumulative transcript;
the structural rate is modeled (occupancy × turns) not floored; the projection auto-banks
across the lifecycle and grades at close; the budget-gate tensions the forecast, not just
the burn; and plan-time estimates are sized to a context budget via a dual-form sidecar.

### Added

- **Plan-time context-sizing** ([13.2]) — `estimate.sh` dual-form sidecar (legacy integer OR
  sized `{sessions,fraction,size}`) + `set-sized`, ratifying against a light/medium/heavy
  rubric keyed to a fraction of the session budget; a >1-session deliverable is a balloon to
  SPLIT, not estimate as N. `/plan` and `/replan` teach the rubric.
- **Per-deliverable cost metering** ([13.6]) — burn recorded as a bounded transcript slice
  across the compaction cycles a deliverable spans, each entry self-describing its slice basis.
- **Projection auto-banking** ([13.4]) — forecasts bank at `/plan` + each phase boundary and
  grade at close; idempotent, append-only.
- **Subagent-reviewer burn capture** ([13.1]) in the meter harvest.

### Changed

- **Throughput-native projection** ([12.1]) — throughput is the unit; occupancy retired to
  an informational reference.
- **Modeled structural rate** ([13.3]) — n=0 rate = `occupancy_budget × expected_turns`, a
  real central estimate superseding the doc-overhead floor.
- **Budget-gate reads the projection** ([13.5]) — tensions cost-to-complete vs the plan-time
  budget; a breach can be FORESEEN and declared, not only detected after the burn.

### Fixed

- **Projection band coherence** ([9.7]) — blend the range edges, not just the centre.

## 0.5.0 — 2026-06-16

Minor release (0.x): **Phase 9 (the meter) and Phase 11 (multi-repo topology) complete.**
guv meters its own cost at every session/queue boundary and projects cost-to-complete
from the project's own plan + observed history; and a control plane can orchestrate N
code repos through a named-map `roots.code`, with split proposed by default for
standalone/publishable products. Single-repo planes are unaffected — a string
`roots.code` is the unchanged shorthand. Manifest contract version 1 → 2.

### Added

- **The meter** — `meter.sh` / `meter-queue` (session + queue-boundary cost capture,
  harvested not agent-reported, append-only), `emit-metrics.sh` (the one-parser
  `guv.metrics.v1` aggregate), the occupancy meter + calibration, and `estimate.sh`
  (per-deliverable session-estimate sidecar).
- **`projection.sh`** — cost-to-complete: a structural spine (quantity × the session
  envelope) blended with this plane's own observed rate, a basis claim
  (structural / blended, n=…) and a scope claim, banked forecasts, and close-time
  grading into two separable errors (quantity vs rate). Reads only the local plane —
  never foreign history.
- **`budget-gate`** — budget setpoints with a silent-within / loud-on-breach tension
  gate at the session boundaries; never self-raising.
- **Named-map `roots.code`** (+ `roots.codePrimary`) — a control plane names N code
  repos, each with its own `commands`. `guv-cmd <name> [<repo>]` self-locates into the
  named repo; lane/dispatch/queue repo-namespace their worktrees
  (`.worktrees/<repo>/lane-<id>/`); a misrouted repo fails loud.
- **`scaffold-split.sh`** — the consumer-facing split scaffold: lays down a sibling
  control plane + provisions the code repo, for a standalone/publishable product.

### Changed

- **Split is the default proposal for standalone/publishable products** (single-repo
  stays the default for internal apps). `resolve-stack.sh --greenfield … --class …`
  proactively proposes the split; the README/templates flip "recommended" → "default".
  `resolve-stack` also detects an existing control-plane/code split structurally.
- **Manifest contract version 1 → 2** — `roots.code` accepts a named map; a string is
  the single-repo shorthand and a no-op for every root-aware operation (back-compat).

### Fixed

- **Consumer-scaffolded splits are now detected** — split-detection generalized to a
  universal control-plane signal (the manifest's `roots.code` resolving to a sibling),
  no longer keyed solely on the maintainer-only `run-core-tests.sh` marker.
- **`resolve-stack` reads the code repo's stack in a split** — node/python/rust splits
  now emit a proposal instead of detecting-then-exiting (the per-language reads hit the
  detected code repo, not the stackless control plane).

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
- **resolve-stack split detection ([11.4])** — `resolve-stack.sh` now recognizes a control-plane/code split: pointed at a stackless `.claude/` control plane (identified by the `run-core-tests.sh` marker `setup-control-plane.sh` writes), it resolves the stack from the sole stack-bearing sibling and proposes `roots.code` pointing at it with commands resolved from it, instead of exiting 2 at the control root or proposing `roots.code='.'`. Detection is structural, not name-based (the manifest stays the sole machine pointer); ambiguous topologies fall through to the exit-2 loud stop. Single-repo planes are unaffected.
### Added
- **Budget setpoints and the escalation path ([9.3]).** Optional budgets in `project.json` at initiative and session granularity, schema-validated; **absent means unlimited** (a governor with no setpoint spins free — choosing is the person's first act). The tension gate (`.claude/budget-gate.sh`) is wired into both session boundaries — the SessionStart hook fires it at entry (surfacing a breach as session-open context without ever blocking the session), and the handoff session-close path fires it at exit — sums burn from the [9.1] metering log, and raises a decision gate *on tension only* — within budget it is silent (no green banner, no per-session recap). A breach pauses and escalates with work preserved, surfacing the burn profile and the person's choices (extend / harvest / kill); the machinery never raises a setpoint, so a headless breach stays paused, loud, state intact. Budgets have no storage outside `project.json` — budget edits are commits, and the manifest's git history is the provenance (no approval flow, no side channel).
- **Core-test gate integrity** ([15.1]) — the core-test battery can no longer report green over a suite that did not pass. Each suite now runs under a per-suite `timeout` so a hang fails LOUD with a named timeout (never a silent stall); where no timeout binary exists the runner degrades to an announced unbounded run, and that announcement is now asserted to FIRE at runtime (not just present in the heredoc) so the loud-stop is proven even on a timeout-less box. Suites run under a bounded parallel pool with a deterministic aggregation pass that enforces the identical exit-0-AND-0-stderr gate, so wall-clock drops toward the slowest suite. A hermeticity audit (`maintainers/BATTERY-HERMETICITY.md`) found that NOT every suite is hermetic: `plugin.test.sh` plants throwaway fixtures into the live `.claude/` source tree and `ship-suite.test.sh` builds the plugin reading that same source — run concurrently they corrupt each other's build. Those two suites are carved into a SERIAL pass (the rest stay parallel), resolving the fixture-collision hazard before parallelism. The exit-masking / stdout-only-failure-blindness hole is also closed: the gate fails a suite whose failure shows only on stdout (a ✗ line or a nonzero `Results:` failed-count) even at exit 0, and each runner's final statement is its own exit so a trailing post-runner command can no longer mask the verdict. Applied to all three copies of the run loop — `run-core-tests.sh` (generated by `setup-control-plane.sh`), `run-plugin-tests.sh` (generated by `build-plugin.sh`), and the CI inline loop (serial-by-design, which subsumes the carve).
