#!/bin/bash
# Tests for [19.4] — hook registrations anchor to $CLAUDE_PROJECT_DIR, not a bare
# relative path. The cold-path bug: every hook in .claude/settings.json was wired
# as `bash .claude/hooks/X.sh` — a path resolved relative to the session CWD. When
# the session runs with cwd OFF the project root (a multi-repo split, a subdir
# launch), `.claude/hooks/X.sh` does not exist there, so Claude Code cannot even
# LOCATE the script to execute it: the hook never starts and fails SILENTLY. The
# safety hooks (bash-guard, single-writer, stop-check) are the ones that matter —
# their guarantees evaporate off-root with no error. (The scripts already resolve
# their own ROOT from ${CLAUDE_PROJECT_DIR:-$PWD} internally — finding (e) — but
# that is moot if the registration can't find the script to RUN it.)
#
# The fix anchors each registration to ${CLAUDE_PROJECT_DIR:-$PWD} (the env var
# Claude Code exports for exactly this; the :-$PWD fallback preserves today's
# cwd-relative behavior if the var is ever unset — Rule 15 designed degradation).
#
# The coupled half is the plugin DERIVE (build-plugin.sh): hooks.json is generated
# FROM settings.json by rewriting the project path (.claude/hooks/X.sh) to the
# plugin-root path. The derive must strip the WHOLE project-mode prefix, or it
# emits a broken double-prefix (`"$CLAUDE_PROJECT_DIR"/"${CLAUDE_PLUGIN_ROOT}"/…`).
# So this suite also pins that the project anchor never LEAKS into the plugin —
# the cross-surface invariant that makes this deliverable non-trivial.
#
# What this suite pins (asserting the CORE settings.json — the source of truth;
# the plugin mirror is regenerated and byte-compared by plugin.test.sh's drift
# guard, but the no-leak invariant is pinned here directly):
#   - NO hook command is a bare relative `bash .claude/hooks/…` (the off-root bug)
#   - the three NAMED safety hooks (bash-guard, single-writer, stop-check) each
#     anchor to $CLAUDE_PROJECT_DIR — the deliverable's headline requirement
#   - EVERY .claude/hooks/ registration is anchored (no bare one slipped through)
#   - the plugin derive does NOT leak $CLAUDE_PROJECT_DIR into hooks.json, and
#     keeps every command ${CLAUDE_PLUGIN_ROOT}-anchored (the derive stays correct)
# Pure bash + jq (jq is a hard guv dependency — manifest parsing). No test runner.
# Run: bash .claude/tests/hook-registration-anchoring.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETTINGS="${SETTINGS:-$ROOT/.claude/settings.json}"
PLUGIN_HOOKS="${PLUGIN_HOOKS:-$ROOT/plugin/hooks/hooks.json}"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SETTINGS" ]; then
  no "settings.json missing — .claude/settings.json must exist"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
ok "settings.json exists (.claude/settings.json)"

# All hook command strings, extracted structurally (robust to formatting).
CMDS=$(jq -r '.hooks | .. | objects | select(has("command")) | .command' "$SETTINGS")

# The bug: a bare relative `bash .claude/hooks/…` — the path that fails to resolve
# off-root. `bash ` immediately followed by `.claude/hooks/` (no anchor between).
if printf '%s\n' "$CMDS" | grep -qE 'bash[[:space:]]+\.claude/hooks/'; then
  no "a hook is wired bare-relative (bash .claude/hooks/…) — fails silently off-root"
else
  ok "no hook command is bare-relative (none resolves against the session CWD)"
fi

# The fix, on the NAMED safety hooks the deliverable calls out: each must anchor
# to $CLAUDE_PROJECT_DIR so it fires regardless of cwd.
for h in bash-guard single-writer stop-check; do
  line=$(printf '%s\n' "$CMDS" | grep "hooks/$h\.sh")
  if [ -n "$line" ] && printf '%s\n' "$line" | grep -q 'CLAUDE_PROJECT_DIR'; then
    ok "safety hook $h.sh is \$CLAUDE_PROJECT_DIR-anchored (fires off-root)"
  else
    no "safety hook $h.sh must anchor to \$CLAUDE_PROJECT_DIR (it is the off-root guard)"
  fi
done

# Completeness: every .claude/hooks/ registration is anchored — not just the three
# named ones. A bare one that slipped through is the same latent off-root failure.
total=$(printf '%s\n' "$CMDS" | grep -c '\.claude/hooks/')
anchored=$(printf '%s\n' "$CMDS" | grep '\.claude/hooks/' | grep -c 'CLAUDE_PROJECT_DIR')
if [ "$total" -gt 0 ] && [ "$total" -eq "$anchored" ]; then
  ok "all $total .claude/hooks/ registrations are \$CLAUDE_PROJECT_DIR-anchored"
else
  no "only $anchored of $total .claude/hooks/ registrations are anchored (the rest fail off-root)"
fi

# Cross-surface derive integrity: the plugin install path (hooks.json) re-roots
# every hook to ${CLAUDE_PLUGIN_ROOT}. The project anchor must NOT leak through the
# derive (a broken derive would emit "$CLAUDE_PROJECT_DIR"/"${CLAUDE_PLUGIN_ROOT}"/…).
if [ ! -f "$PLUGIN_HOOKS" ]; then
  no "plugin hooks.json missing — $PLUGIN_HOOKS (build-plugin.sh derives it)"
else
  PCMDS=$(jq -r '.hooks | .. | objects | select(has("command")) | .command' "$PLUGIN_HOOKS")
  if printf '%s\n' "$PCMDS" | grep -q 'CLAUDE_PROJECT_DIR'; then
    no "plugin hooks.json LEAKS \$CLAUDE_PROJECT_DIR — the derive double-prefixed (broken)"
  elif printf '%s\n' "$PCMDS" | grep -q 'CLAUDE_PLUGIN_ROOT'; then
    ok "plugin derive re-roots to \${CLAUDE_PLUGIN_ROOT} with no \$CLAUDE_PROJECT_DIR leak"
  else
    no "plugin hooks.json has no \${CLAUDE_PLUGIN_ROOT}-anchored commands — derive misfired"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
