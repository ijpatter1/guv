#!/bin/bash
# .claude/update-readme-status.sh
# Replace the content between the README status markers with text read from stdin.
# Deterministic, in-place, and SAFE: if BOTH markers aren't present, it does nothing —
# so it never clobbers a consumer README that has no status block (important for
# /onboard, which must not rewrite an existing README). It only ever touches the lines
# between the markers; all surrounding prose is preserved.
#
# Markers in the README:
#   <!-- STATUS:START (…anything…) -->   ...replaced...   <!-- STATUS:END -->
#
# Usage:
#   printf '%s\n' "**Phase 2 — Ingestion** · 6/9 deliverables · session-2026-06-10-003" \
#     | bash .claude/update-readme-status.sh [README.md]
#
# Exit 0 always (advisory/maintenance, never blocks a session).

set -u
FILE="${1:-README.md}"
[ -f "$FILE" ] || exit 0

# Both markers required, or leave the file untouched (no-op, not an error).
grep -q 'STATUS:START' "$FILE" && grep -q 'STATUS:END' "$FILE" || exit 0

BODY=$(mktemp)
cat > "$BODY"           # new status content from stdin

TMP=$(mktemp)
# Print the START line, then the new body, then drop old content until END, print END,
# and pass everything outside the block through unchanged.
awk -v bf="$BODY" '
  /STATUS:START/ { print; print ""; while ((getline line < bf) > 0) print line; print ""; close(bf); inblock=1; next }
  /STATUS:END/   { inblock=0; print; next }
  inblock        { next }
                 { print }
' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || rm -f "$TMP"

rm -f "$BODY"
exit 0
