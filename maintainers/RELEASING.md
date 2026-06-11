# Releasing Governor (guv)

Maintainer-side mechanics: what a release is, when to bump which version
component, and the release half of the feedback drain. The consumer-side
capture/triage process lives in the `log-feedback` skill.

## What a release is

The marketplace (`.claude-plugin/marketplace.json`, relative source `./plugin`)
serves whatever `plugin/` contains on the default branch. **The plugin manifest
version is the release**: consumers update only on a version bump, so a change
that ships without a bump reaches no one. A release is therefore:

1. the version bumped in `maintainers/plugin-src/plugin.json`,
2. `plugin/` rebuilt (`bash maintainers/build-plugin.sh`) so the committed tree
   carries the bump,
3. a `CHANGELOG.md` entry whose topmost heading matches that version
   (`release.test.sh` enforces the coherence),
4. an annotated git tag `v<version>` on the commit that ships it.

## Bump policy (semver)

- **patch** — fixes and doc corrections to already-shipped assets: a hook or
  script bug, a skill-text correction, a rules clarification. No new surface.
- **minor** — additive surface: a new skill, agent, or shipped asset; additive
  manifest-schema fields; new scaffold output. Existing projects keep working
  untouched.
- **major** — anything that breaks the rendered-project contract: manifest
  schema changes that are not additive, renamed/removed skills or agents,
  scaffold output that existing projects must migrate to.

While the version is 0.x, the format-survival period is running and minor may
carry what would later be major — 0.x is the documented signal that the
contract is still settling.

## Going public

The marketplace stays personal until both criteria hold:

- **(a)** the plugin format has survived a Claude Code minor version without
  breaking, and
- **(b)** at least one external project has installed it.

Both were set as pre-resolved decisions in the native-alignment spec
(2026-06-10); don't reopen them, check them off.

## Release checklist

1. All bash suites green with **empty stderr** — enforced, not eyeballed: the
   control plane's runner and CI both capture per-suite stderr and fail the
   run on any output there (a green summary above a parse error is how a
   vacuous guard once slipped two review gates).
2. `claude plugin validate --strict plugin` and
   `claude plugin validate --strict .claude-plugin/marketplace.json` pass.
3. Version bumped in `maintainers/plugin-src/plugin.json`; `plugin/` rebuilt;
   the drift guard (`plugin.test.sh`) passes.
4. `CHANGELOG.md` entry written — topmost version matches the manifest.
5. **Merge to the default branch.** The marketplace serves `plugin/` from the
   default branch — a release is unreachable until the shipping commit is on
   it. The tag and every public side effect that names the release
   (graduations, issue closures) come only after this step.
6. Tag `v<version>` and push it.
7. **Drain step:** for every `routing: upstream` feedback entry whose fix ships
   in this release, flip its status to `graduated` in the control plane's
   `.claude/feedback/feedback.ndjson` and close the linked issue naming the
   release. This is what makes `graduated` real — skip it and the drain is
   dead again.

## The feedback drain, release half

The full lifecycle of an upstream entry:

```
open (routing: upstream)
  → issue/PR against this repo, citing the entry id
  → fix lands on a branch, commit references the issue
  → release ships the fix (version bump + tag)
  → entry flips to `graduated` on the release that ships the fix; issue closed
```

`graduated` is distinct from `resolved`: `resolved` marks friction fixed before
any release existed (no release to graduate on — e.g. the .DS_Store sync fix,
entry `2026-06-10T20:25:26Z-970732268`), while `graduated` names the release
that carried the fix to consumers. `routing: local` entries never enter this
flow — they are project-side adaptations, handled in the consumer's control
plane (see the `log-feedback` skill).

One class of upstream fix has **no release vehicle**: files the plugin
never ships (maintainer tooling under `maintainers/`, repo-only docs). A bump
would carry nothing to plugin consumers; the audience for these files tracks
the repo itself. Delivery is therefore the **merge to the default branch** —
the entry graduates on that merge, and the issue closes naming the
merge commit instead of a version. (First of this class: the runner-sync fix for
entry `2026-06-11T23:17:51Z-15612590`.)

## Worked example (the drain's first full pass)

Entry `2026-06-10T23:11:39Z-199208882` — "citation checker flags all-decimal
feedback-entry id suffixes as unresolvable commit hashes" (minor, upstream,
logged session-2026-06-10-002):

1. **Issue:** [#7](https://github.com/ijpatter1/claude-code-sandbox/issues/7),
   filed 2026-06-11 from the entry's summary/detail, citing the entry id.
2. **Fix:** `4c7032e` — all-decimal tokens excluded from hash candidates in
   `check-citations.sh`, commit message referencing #7; red test first
   (`check-citations.test.sh` T7, with a same-file positive control).
3. **Release:** v0.1.0 ships the fix.
4. **Graduation:** entry status flipped `open` → `graduated` in the control
   plane's feedback log; #7 closed naming v0.1.0.

**Honest postscript — the inaugural pass deviated from steps 5–6, which it
produced.** The v0.1.0 tag, the graduation, and #7's closure all happened while
the shipping branch was still an open PR (#8): checklist step 5
(merge-before-tag) was added in the review wave that followed, in direct
response. v0.1.0 was never served from the default branch and a shipped file
changed after its tag, so 0.1.1 — to be tagged on the merge commit once #8
lands — will be the first release consumers can actually install (see the
CHANGELOG's release-integrity note). The flow above is the contract; this
postscript is what its first execution taught.
