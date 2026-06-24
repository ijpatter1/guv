#!/bin/bash
# .claude/strip-bootstrap.sh
# Remove the rendered CLAUDE.md "Bootstrapping" section once a project is past
# scaffold ([20.4]). That section is first-session-only template text ("Remove
# this section once the project is scaffolded"); left in place it rots into a
# live project's identity doc. /handoff Step 9 (`/guv:handoff` under the plugin)
# documents the removal but only ever PROPOSES it — this is the deterministic
# hand that performs it (Rule 12: a mechanical text transform is code, not a
# judgment call for the model).
#
# GATED on scaffold STATE, not on the section's mere presence: the strip fires
# ONLY when the manifest's scaffoldCheck affirmatively passes. Before scaffold
# (the first session, when the section is still load-bearing), and whenever the
# state can't be confirmed (no manifest, no scaffoldCheck, jq absent), it is a
# no-op — the conservative degradation keeps the section rather than wrongly
# stripping it (Rule 15). Idempotent: with the section already gone it no-ops.
#
# Removal is BOUNDED — the Bootstrapping section runs from its `## ` heading to
# the next `## ` heading (or EOF), so only that section goes, never the rest of
# the file. The blank line the section left behind is trimmed.
#
# Usage (cwd = the project root, where .claude/project.json and CLAUDE.md live):
#   bash .claude/strip-bootstrap.sh [CLAUDE.md]
#
# Exit 0 always (advisory/maintenance, never blocks a session).

set -u
FILE="${1:-CLAUDE.md}"
[ -f "$FILE" ] || exit 0

# Scaffold-state gate: strip only once the project is affirmatively scaffolded.
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || exit 0                       # no manifest → can't tell → keep
CHECK=$(jq -r '.scaffoldCheck // empty' "$MANIFEST" 2>/dev/null)
[ -n "$CHECK" ] || exit 0                          # no scaffoldCheck → can't tell → keep
sh -c "$CHECK" >/dev/null 2>&1 || exit 0           # not yet scaffolded → keep (first session)

# Already stripped (or never present) → true no-op, don't rewrite the file.
grep -q '^## Bootstrapping' "$FILE" || exit 0

TMP=$(mktemp)
# Drop the Bootstrapping section (heading → next `## ` heading or EOF), pass every
# other line through, and trim trailing blank lines the removal left behind.
awk '
  /^## Bootstrapping/ { skip=1; next }
  skip && /^## /      { skip=0 }
  skip                { next }
  { buf[++n]=$0; if (NF) last=n }
  END { for (i = 1; i <= last; i++) print buf[i] }
' "$FILE" > "$TMP" && mv "$TMP" "$FILE" || rm -f "$TMP"

exit 0
