#!/bin/bash
# .claude/guv-cmd.sh — run a manifest command with null-skip, once ([7.1]).
#
# The manifest-command read (jq -r '.commands.<name>' + the null check) used
# to be inlined at every call site; this helper is that read, once. A defined
# command runs via sh -c with cwd = the project root; its exit code
# propagates. null or absent means skip — loudly, with exit 0 (null-means-skip
# is the manifest's design principle; the message keeps the skip visible).
#
# Usage: bash .claude/guv-cmd.sh <name>
#   e.g. bash .claude/guv-cmd.sh test
#        bash .claude/guv-cmd.sh install
# Exit: the command's code · 0 on null-skip · 2 usage · 4 no manifest
# (a missing manifest is a caller bug, not a null).
set -u

[ $# -eq 1 ] || { echo "usage: bash .claude/guv-cmd.sh <command-name>" >&2; exit 2; }
NAME="$1"
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || { echo "guv-cmd: no manifest at $MANIFEST (cwd must be the project root)" >&2; exit 4; }

CMD=$(jq -r --arg n "$NAME" '.commands[$n] // empty' "$MANIFEST" 2>/dev/null)
if [ -z "$CMD" ]; then
  echo "[guv-cmd] commands.$NAME is null — skipping"
  exit 0
fi
sh -c "$CMD"
