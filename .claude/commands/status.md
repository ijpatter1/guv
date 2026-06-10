Give a quick status overview of the project without the full session initialization.

## Gather State

1. Read `.claude/project.json`. Run its `scaffoldCheck`; if it passes, run `commands.test` and capture pass/fail counts (skip cleanly if `commands.test` is `null`). If `scaffoldCheck` fails, note the project isn't scaffolded yet.
2. Run `git -C "$(jq -r '.roots.code' .claude/project.json)" log --oneline -5` for recent code activity (if git is initialized; otherwise note "no git history"). `roots.code` is `"."` for single-repo, so this is a no-op there.
3. Read `docs/PHASE_STATUS.md` for phase completion state (only in `phased` projects; if it's absent — `task`/`onboard` mode — report the current phase as "N/A (`<ceremony>` mode)" and skip phase progress)
4. Check `git -C "$(jq -r '.roots.code' .claude/project.json)" status` for any uncommitted code changes
5. List the most recent file in `docs/sessions/` and read its **Next Steps** section (if no session files exist, note "no prior sessions")

## Report

Present a concise summary:

- **Current phase:** N — [Name] — X of Y deliverables complete
- **Tests:** X passing, Y failing
- **Last commit:** [hash] [message] [time ago]
- **Uncommitted changes:** yes/no
- **Next up:** [the recommended next feature from the last handoff]

Keep this to 10 lines or fewer. This is a quick orientation, not a deep dive.
