#!/bin/bash
# Tests the coupling between the router's door vocabulary and the skills that
# invoke it. `.claude/route.sh` declares KNOWN_DOORS once and refuses anything
# outside it with exit 2; each entry-door skill opens with a Step-0 guard that
# calls `route.sh --for <token>`. Those two halves live in different files and
# nothing checked that they agree — so renaming a door, or writing a plausible
# synonym into a skill, produced a Step-0 guard that exits 2 on every session
# entry into that door. The failure is silent in the worst way: exit 2 is the
# router's "misinvoked" rung, so the skill reads it as "the router is
# unavailable" and falls through to its own fallback, taking the exact
# hand-read path the routing collapse exists to delete.
#
# What this suite pins:
#   - every `route.sh --for <token>` call site in a skill names a KNOWN door
#   - the walk is NON-VACUOUS: it finds the doors that actually carry guards,
#     so a suite that stops locating call sites reds instead of passing on zero
#   - the vocabulary is ENFORCED, not decorative: an off-list token is refused
#
# Deliberately NOT pinned: that every KNOWN door has a guarding skill. `task` is
# content-driven by design ([8.1]'s routing note) — it processes the change it
# was handed in any ceremony, so it carries no Step-0 guard while remaining a
# door the router emits. The implication runs one way only, and asserting the
# converse would red on a correct tree.
#
# MAINTAINER-ONLY, and deliberately so. This suite reads skill sources — e.g.
# skills/next/SKILL.md — and build-plugin.sh's MAINTAINER_ONLY filter partitions
# on exactly that literal, because run-plugin-tests.sh reconstructs a .claude/
# tree from scripts/, hooks/, rules/ and tests/ but NOT skills/*/SKILL.md. A
# skill-prose suite that reached the shipped partition would walk an empty set
# and pass on nothing; the non-vacuity assertion below turns that into a red
# instead, which is how this placement was found. Do not rewrite the reference
# above into a glob to "tidy" it — that is what ships the suite. That instruction
# is not the only guard: this basename is named in the by-name must-not-ship lists
# in plugin.test.sh (T18) and ship-suite.test.sh (T3b), so a tidy-up reds there
# rather than shipping quietly and passing on an empty set.
# Pure bash, no runner required.
# Run: bash .claude/tests/door-vocabulary.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROUTE="$CLAUDE_DIR/route.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# ── the vocabulary, read from its single declaration ──────────────────────────
# Read, never restated: a copy of the door list in this file would be the same
# two-halves-drifting bug one level up.
KNOWN=$(sed -n 's/^KNOWN_DOORS="\(.*\)"$/\1/p' "$ROUTE" | head -1)
[ -n "$KNOWN" ] \
  && ok "route.sh declares KNOWN_DOORS in one readable place ($KNOWN)" \
  || no "could not read KNOWN_DOORS from $ROUTE — the vocabulary must stay declared in one place this suite can read"

# ── the call sites, as the skills actually spell them ─────────────────────────
# Matched on the invocation itself (`route.sh … --for <token>`), not on a bare
# --for, so a --for in unrelated prose is not mistaken for a call site.
SITES=$(grep -rhoE 'route\.sh[^|]*--for [a-z][a-z-]*' "$CLAUDE_DIR"/skills/*/SKILL.md 2>/dev/null \
        | sed -E 's/.*--for //' | LC_ALL=C sort -u)
SITE_COUNT=$(printf '%s\n' "$SITES" | grep -c '[a-z]')

# Non-vacuity first: every assertion below is a loop over $SITES, so an empty
# walk would report a clean pass over nothing. The floor is the doors that
# carry a Step-0 guard today; it is a floor, not an equality, so adding a
# guarded door does not red this line.
[ "$SITE_COUNT" -ge 5 ] \
  && ok "the skill walk found $SITE_COUNT --for call sites (non-vacuous)" \
  || no "found only $SITE_COUNT --for call sites in $CLAUDE_DIR/skills/*/SKILL.md — the walk located nothing to check, so every assertion below would pass on an empty set"

# ── each call site names a door the router knows ──────────────────────────────
BAD=""
for tok in $SITES; do
  case " $KNOWN " in
    *" $tok "*) ;;
    *) BAD="$BAD $tok" ;;
  esac
done
[ -z "$BAD" ] \
  && ok "every skill's route.sh --for token is a KNOWN door (checked:$(printf ' %s' $SITES))" \
  || no "skill Step-0 guards name door(s) the router refuses:$BAD — known doors are: $KNOWN. Each one exits 2 at session entry and the skill falls through to its hand-read fallback"

# ── and the vocabulary is enforced, not decorative ────────────────────────────
# Without this, KNOWN_DOORS could be an unused string and the assertion above
# would be checking membership in a list nothing consults. Uses a token that is
# not a door under any spelling, so this stays true through a door rename.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude"
ln -s "$ROUTE" "$WORK/.claude/route.sh"
ln -s "$CLAUDE_DIR/resolve-ready.sh" "$WORK/.claude/resolve-ready.sh"
OUT=$(cd "$WORK" && bash "$WORK/.claude/route.sh" --for zznotadoor 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'unknown door' \
  && ok "an off-vocabulary --for token is refused (exit 2, names the known doors)" \
  || no "route.sh must refuse a door outside KNOWN_DOORS — otherwise the list this suite checks against governs nothing (rc=$RC out='$OUT')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
