#!/bin/bash
# .claude/hooks/render-on-status-edit.sh
# PostToolUse hook ([8.3] §3.3) — when an Edit/Write/MultiEdit touches
# docs/PHASE_STATUS.md, regenerate the derived status views in the working tree:
# status.html (render-status.sh) and the README status block (status-line.sh |
# update-readme-status.sh). This is the NATIVE, SHIPPED render path — it covers
# direct tool-edits of the tracker and consumer installs that have no git hook.
#
# RENDER-ONLY: it never commits. Auto-committing the derived status.html (and
# catching the /replan-engine path, which mutates the tracker via a Bash script
# rather than the Edit tool, so this PostToolUse matcher never sees it) stays the
# control plane's git post-commit render hook's job. The two are complementary,
# not redundant: this fires on tool-edits during a session; the post-commit hook
# fires on every tracker commit.
#
# Convenience, never a dependency; ALWAYS exits 0. PostToolUse fires AFTER the
# tool already ran — there is nothing to block, and a render failure must never
# surface as a tool error. Every rung degrades to a clean exit 0; "stale beats
# broken" — a failed render leaves the previous status.html in place.
set -u

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || exit 0
if [ -f "$DIR/render-status.sh" ]; then BASE="$DIR"; else BASE="$DIR/.."; fi

INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"

# Fire only on the tracker — the single file every status view derives from.
# Match the basename so an absolute or a repo-relative path both trigger.
case "$FP" in
  */PHASE_STATUS.md|PHASE_STATUS.md) ;;
  *) exit 0 ;;
esac

TRACKER="docs/PHASE_STATUS.md"
[ -f "$TRACKER" ] || exit 0   # not at the project root, or no tracker — stand aside

TMP_JSON="$(mktemp)" || exit 0
if bash "$BASE/resolve-ready.sh" "$TRACKER" --json > "$TMP_JSON" 2>/dev/null; then
  # status.html — render to a temp and swap on success only (stale beats broken).
  TMP_HTML="$(mktemp)"
  if bash "$BASE/render-status.sh" "$TMP_JSON" > "$TMP_HTML" 2>/dev/null; then
    mv "$TMP_HTML" status.html 2>/dev/null || rm -f "$TMP_HTML"
  else
    rm -f "$TMP_HTML"
  fi
  # README status block — update-readme-status.sh no-ops safely without markers.
  bash "$BASE/status-line.sh" "$TMP_JSON" 2>/dev/null \
    | bash "$BASE/update-readme-status.sh" README.md 2>/dev/null
fi
rm -f "$TMP_JSON"
exit 0
