---
name: status
description: "Give a quick status overview of the project without the full session initialization."
user-invocable: true
---


## Gather State

1. Read `.claude/project.json`. Run its `scaffoldCheck`. If it fails, note the project isn't scaffolded yet. If it passes, also run `readyCheck` (when present): if `readyCheck` **fails** the project is **NOT_INSTALLED** — report "scaffolded, deps not installed (run `commands.install`)" and **do not** run the tests (they'd fail spuriously). Only when scaffolded and ready (or no `readyCheck`) run `commands.test` and capture pass/fail counts (skip cleanly if `commands.test` is `null`).
2. Run `bash .claude/guv-git.sh log --oneline -5` for recent code activity (if git is initialized; otherwise note "no git history"). The helper targets the code repo (`roots.code`, `"."` for single-repo, so this is a no-op there).
3. Read `docs/PHASE_STATUS.md` for phase completion state (only in `phased` projects; if it's absent — `task`/`onboard` mode — report the current phase as "N/A (`<ceremony>` mode)" and skip phase progress). In phased projects, also read the **lineage header** at the top of `docs/REQUIREMENTS.md` (if present) for the current initiative's name/spec and phase range.
4. Check `bash .claude/guv-git.sh status` for any uncommitted code changes
5. List the most recent file in `docs/sessions/` and read its **Next Steps** section (if no session files exist, note "no prior sessions")
6. Run `bash "${CLAUDE_SKILL_DIR}/scripts/check-citations.sh"` — an advisory check that flags session-handoff citations whose commit hashes no longer resolve in the code repo. It self-limits to a control-plane split (`roots.code != roots.control`) and is silent otherwise. Capture its output.
7. Count open harness-feedback entries: `f=.claude/feedback/feedback.ndjson; [ -f "$f" ] && jq -s '[.[] | select(.status=="open")] | length' "$f" || echo 0`.
8. **README status block — no hand-invoke needed.** In `phased` projects the block is refreshed automatically by the §3.3 render hooks — the native PostToolUse hook when a tracker edit lands, and the control plane's git post-commit hook on every tracker commit — both deriving the line from the resolver (`status-line.sh`, never a second source of truth). `/status` only reads state here; there is nothing to write. (In `task`/`onboard` mode there is no tracker to derive from, and a consumer README normally carries no STATUS markers, so there is nothing to refresh.)

## Report

Present a concise summary:

- **Current phase:** N — [Name] — X of Y deliverables complete
- **Initiative:** _include this line only if a lineage header exists_ — [name/governing spec] · Phases A–B
- **Tests:** X passing, Y failing
- **Last commit:** [hash] [message] [time ago]
- **Uncommitted changes:** yes/no
- **Human-gated:** _include this line only if any deliverable carries the 🔒 marker_ — "N awaiting manual work (see `docs/manual/`)". The 🔒 marker is **human-gated / awaiting-manual** (a deliverable blocked on out-of-sandbox human or manual work, the kind `/manual` writes to `docs/manual/`); count it as its **own** category — never fold it into the ❌ blocked tally and never count it as ✅ complete. The X-of-Y "complete" count is ✅ only; 🔒 items are open work, reported here.
- **Next up:** [the recommended next feature from the last handoff]
- **Citation warnings:** _include this line only if `check-citations.sh` printed something_ — list the flagged artifact(s)/hash(es) it reported. If the script was silent, omit this line entirely.
- **Open harness feedback:** _include this line only if the count from step 7 is > 0_ — "N open (triage with the `feedback` skill)". If 0, omit entirely.

Keep this to 10 lines or fewer. This is a quick orientation, not a deep dive. The citation check is silent in the common case, so it costs no budget unless there's something to report.
