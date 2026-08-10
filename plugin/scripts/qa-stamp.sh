#!/bin/bash
# .claude/qa-stamp.sh
# The QA verdict STAMP writer ([18.2] of the pre-beta-hardening initiative; design of
# record docs/spikes/18-1-generated-artifact-qa.md). [18.2] routes every generated UAT
# (handoff Step 8) and manual card (the manual skill) through a calibrated single-reviewer vet at
# its generation point, then RECORDS the verdict in the session record and STAMPS it on
# the artifact. This script writes that stamp.
#
# It is the MECHANICAL half (Rule 12 — deterministic, no judgment, no LLM): the VERDICT
# is the session's grade of the named reviewer's findings ([32.1]: calibrated agents
# return findings, not verdicts) — guv:reviewer findings for a UAT and for a manual
# card alike, invoked BY NAME ([32.3]: one calibrated vet) — and is passed in. This script only composes
# the canonical stamp line and places it idempotently, so both generation points stamp
# identically and a re-run never double-stamps. The stamp format is documented HERE (its
# single source of truth — no separate shape doc to drift from); nothing parses it today,
# it is a human-facing label.
#
# Stamp forms (chosen by file extension — the artifact is a script or a card):
#   *.md card  →  **QA:** <LABEL> — <body>
#   otherwise  →  # QA: <LABEL> — <body>     (a UAT/manual .sh script)
# The three verdicts (the only ones):
#   pass       →  PASS — vetted by <reviewer>            (vetted, clean)
#   needs-work →  NEEDS WORK — <reviewer> found issues   (vetted, issues to weigh)
#   unvetted   →  UNVETTED — review did not run          (the LOUD degrade: a review
#                 that could not run is VISIBLY unvetted, never a silent pass)
# pass and needs-work NAME the reviewer — so REVIEWER is REQUIRED for them (an
# unattributed verdict is exactly the unaccountable stamp [18.2] exists to prevent —
# Rule 14); unvetted names no one, so REVIEWER is ignored there.
# Two UNVETTED phrasings coexist by design, distinct on purpose: the templates ship
# "UNVETTED — not yet vetted" (the vet has not been ATTEMPTED — visibly unvetted from
# birth, by construction), while this helper's unvetted verdict writes "UNVETTED —
# review did not run" (the vet WAS attempted but the reviewer was unavailable — the
# loud degrade). Same loud signal, different cause; a reader can tell "not yet" from
# "tried and failed."
# An optional NOTE is appended as " — <note>" (e.g. "3 findings", "reviewer unavailable").
#
# Idempotent: an existing QA stamp line is REPLACED in place, wherever it sits (so the
# templates' default UNVETTED stamp is overwritten with the real verdict, and a second
# stamp never appends a duplicate). Only when no stamp exists is one inserted — after
# the shebang for a script, after the first H1 for a card. The artifact's mode is
# preserved across the rewrite (a UAT script is chmod +x'd before it is vetted).
#
# Usage: qa-stamp.sh ARTIFACT VERDICT REVIEWER [NOTE]
#   ARTIFACT  path to stamp (must exist)
#   VERDICT   pass | needs-work | unvetted   (case-insensitive)
#   REVIEWER  e.g. guv:reviewer — REQUIRED for pass|needs-work, ignored for unvetted
#   NOTE      freeform tail, optional (on needs-work, locate the findings — e.g.
#             "3 findings — see handoff Issues & Technical Debt")
set -euo pipefail

ART="${1:-}"; VERDICT="${2:-}"; REVIEWER="${3:-}"; NOTE="${4:-}"

[ -n "$ART" ] && [ -n "$VERDICT" ] || {
  echo "usage: qa-stamp.sh ARTIFACT VERDICT REVIEWER [NOTE]   (REVIEWER required for pass|needs-work)" >&2; exit 2; }
[ -f "$ART" ] || { echo "qa-stamp: artifact not found: $ART" >&2; exit 2; }

# Normalize the verdict to its canonical label + body phrasing (the deterministic
# transform). An unknown verdict is a loud stop (Rule 15) — never a silent default.
# pass/needs-work must NAME their reviewer (Rule 14 — an unattributed verdict is the
# unaccountable stamp [18.2] exists to prevent); unvetted attributes to no one.
need_reviewer() {
  [ -n "$REVIEWER" ] || {
    echo "qa-stamp: a '$VERDICT' stamp must name its reviewer (Rule 14) — usage: qa-stamp.sh ARTIFACT $VERDICT REVIEWER [NOTE]" >&2
    exit 2; }
}
v=$(printf '%s' "$VERDICT" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
case "$v" in
  pass)       need_reviewer; LABEL="PASS";       BODY="vetted by $REVIEWER" ;;
  needswork)  need_reviewer; LABEL="NEEDS WORK"; BODY="$REVIEWER found issues" ;;
  unvetted)   LABEL="UNVETTED";   BODY="review did not run" ;;
  *) echo "qa-stamp: unknown verdict '$VERDICT' (use pass|needs-work|unvetted)" >&2; exit 2 ;;
esac
[ -n "$NOTE" ] && BODY="$BODY — $NOTE"

# Stamp form by extension. MARKER is the literal line prefix used for both detection
# and in-place replacement (a literal compare — no regex escaping to get wrong).
case "$ART" in
  *.md) MARKER='**QA:**'; LINE="**QA:** $LABEL — $BODY" ;;
  *)    MARKER='# QA:';   LINE="# QA: $LABEL — $BODY" ;;
esac

# Preserve the artifact's mode across the rewrite (BSD/macOS then GNU stat).
mode=$(stat -f '%Lp' "$ART" 2>/dev/null || stat -c '%a' "$ART" 2>/dev/null || echo "")

tmp=$(mktemp)
# Detect an existing stamp with the SAME predicate the replace uses — a line whose
# PREFIX is the marker, not a marker SUBSTRING anywhere on a line (an `echo`/`grep` of
# the stamp text, common in a UAT that tests this very feature, satisfies a substring
# probe but is not a stamp). Detection scope == mutation scope, so the replace branch
# is never taken on a match the awk rewrite would then miss — no silent no-op that
# echoes a stamp and exits 0 having written nothing (the anti-pattern [18.2] kills).
if awk -v pfx="$MARKER" 'substr($0, 1, length(pfx)) == pfx { found=1; exit } END { exit !found }' "$ART"; then
  # Replace the existing stamp in place — the first line whose prefix is the marker.
  awk -v line="$LINE" -v pfx="$MARKER" '
    !done && substr($0, 1, length(pfx)) == pfx { print line; done=1; next }
    { print }
  ' "$ART" > "$tmp"
else
  # Insert: after the shebang (script) or after the first H1 (card); prepend if the
  # expected anchor is absent (a stamp at the top is still better than no stamp).
  case "$ART" in
    *.md) anchor='^# ' ;;
    *)    anchor='^#!' ;;
  esac
  if head -1 "$ART" | grep -qE "$anchor"; then
    awk -v line="$LINE" 'NR==1 { print; print line; next } { print }' "$ART" > "$tmp"
  else
    { printf '%s\n' "$LINE"; cat "$ART"; } > "$tmp"
  fi
fi

mv "$tmp" "$ART"
[ -n "$mode" ] && chmod "$mode" "$ART" 2>/dev/null || true

printf '%s\n' "$LINE"
