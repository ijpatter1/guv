#!/bin/bash
# .claude/archive-initiative.sh
# The scriptable half of initiative archival, used by /plan
# (/guv:plan under the plugin). The judgment half — spec analysis,
# doc generation, lineage wording — stays in the command. Operates on the
# CONTROL root: run it from ${roots.control}.
#
# Lifecycle model (see the phase-docs skill): REQUIREMENTS + PHASE_STATUS
# describe WORK — they complete and freeze into docs/initiatives/NNN-<name>/.
# ARCHITECTURE describes the SYSTEM — it persists at top level and is only
# snapshot-copied into the archive. docs/sessions/ (continuous journal) and
# docs/spec/ (accumulating sources) are never archived.
#
# Usage:
#   bash .claude/archive-initiative.sh --check
#       Exit 0  status=COMPLETE  max_phase=N   — every deliverable is terminal (✅ done or ❌ descoped)
#       Exit 3  status=INCOMPLETE              — lists each incomplete line
#       Exit 4  status=NONE                    — no real initiative to archive:
#               no PHASE_STATUS.md, OR a tracker holding only the scaffold's
#               verbatim `[Deliverable N …]` placeholder stubs (an unauthored
#               fresh project — the fresh-onboard → first-/plan path)
#       Exit 5  status=MALFORMED               — tracker has no recognizable
#               deliverable bullets / phase headers; fix it by hand first
#   bash .claude/archive-initiative.sh --archive <name> [--force]
#       Moves REQUIREMENTS.md + PHASE_STATUS.md to docs/initiatives/NNN-<slug>/
#       (NNN = highest existing index + 1, so a gap in the sequence never
#       re-issues a frozen archive's index), snapshot-copies ARCHITECTURE.md
#       alongside, prints archive_dir= and
#       phase_range=. Refuses (exit 3) on incomplete deliverables unless
#       --force, which stamps an ABANDONED note into the archived tracker
#       (honest record, not deletion). Exit 5 on a malformed tracker.
set -u

TRACKER="docs/PHASE_STATUS.md"
REQS="docs/REQUIREMENTS.md"
ARCH="docs/ARCHITECTURE.md"

# Deliverable lines are status-marker bullets. OPEN work is ⬜|🔄|🔒; both ✅ (done)
# and ❌ (descoped/abandoned) are TERMINAL ([23.3]) — neither blocks completion on its
# own. This agrees with the resolver's open set (resolve-ready.sh) and replan's
# phase_completed, which both already treat ❌ as terminal, so an initiative whose
# every deliverable is ✅-or-descoped-❌ reads COMPLETE rather than forcing a --force
# archive (which would falsely stamp ABANDONED). 🔒 (human-gated, [10.1]) IS open work
# — the resolver counts it toward the open phase, so an initiative still holding a 🔒
# deliverable is not COMPLETE and archival refuses it (or stamps ABANDONED under
# --force) like any other open line. (The one exception that still blocks on a
# terminal marker is a LONE-deliverable phase whose single item is ✅/❌: it is
# open-until-SEALED — the [15.7] carve below, via unsealed_lone_phases(), not via this
# open-marker set.)
incomplete_lines() { grep -E '^\s*-\s*(⬜|🔄|🔒)' "$TRACKER"; }
done_count() { grep -cE '^\s*-\s*✅' "$TRACKER"; }
max_phase() { grep -Eo '^##+ Phase [0-9]+' "$TRACKER" | grep -Eo '[0-9]+' | sort -n | tail -1; }
min_phase() { grep -Eo '^##+ Phase [0-9]+' "$TRACKER" | grep -Eo '[0-9]+' | sort -n | head -1; }

# ── Spike-gated lone-deliverable carve ([15.7]) ──
# A sibling completion oracle must agree with the engine. replan.sh's
# phase_completed treats a phase whose *single* deliverable is ✅/❌ (no open
# ⬜/🔄/🔒) as "open until SEALED" — sealed by an explicit `phase-close [N]`
# amendment record — so a lone gating spike flipped ✅ before its gated build set
# is groomed in does NOT auto-tally complete. Without this, a lone-✅ unsealed
# phase has zero open-marker lines, so incomplete_lines() would read the whole
# initiative as COMPLETE/archivable — the precise stranding the carve prevents,
# reached through the archive door. The predicate below mirrors the engine's
# (replan.sh: phase_completed + phase_sealed) exactly: per phase, count the
# deliverable lines; if exactly one and none is open and the phase carries no
# phase-close seal record, that phase is open. LEGACY (token-free) trackers have
# no IDs to match and no phase-close records, so they read as before.
ID_PHASE_RE='\*\*\[[0-9]+\.[0-9]+\]\*\*'
DATE_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}'
phase_numbers() { grep -Eo '^##+ Phase [0-9]+' "$TRACKER" | grep -Eo '[0-9]+'; }
phase_sealed() { grep -qE "^> - $DATE_RE — phase-close \[$1\] " "$TRACKER"; }
# Emits the '## Phase N …' header of each lone-deliverable phase that is done
# (its one ✅/❌, no open ⬜|🔄|🔒 marker) yet not sealed — i.e. open by the engine's
# notion. Skips any phase whose lone deliverable carries an OPEN marker
# incomplete_lines() already reports (⬜|🔄|🔒): that phase is listed by that sibling,
# so re-emitting the header here would double-list the one blocker. A lone phase whose
# single item is ✅ OR ❌ has ZERO open-marker lines (both terminal, [23.3]) — that is
# the gap this fills: the lone-deliverable seal carve fires for either terminal marker,
# so a lone-❌ unsealed phase is caught HERE now (not by incomplete_lines, which no
# longer reports ❌), and a sealed one drops out below exactly like a sealed lone-✅.
unsealed_lone_phases() {
  local n lines nlines
  for n in $(phase_numbers); do
    lines=$(grep -E "^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*\*\*\[$n\.[0-9]+\]\*\*" "$TRACKER")
    [ -n "$lines" ] || continue                       # LEGACY / no ID'd bullets
    echo "$lines" | grep -qE '^\s*-\s*(⬜|🔄|🔒)' && continue   # already in incomplete_lines()
    nlines=$(echo "$lines" | grep -c '.')
    [ "$nlines" -eq 1 ] || continue                   # not a lone-deliverable phase
    phase_sealed "$n" && continue                     # deliberately sealed → done
    grep -E "^##+ Phase $n([^0-9]|\$)" "$TRACKER" | head -1
  done
}

# A tracker with no marker bullets at all, or no "## Phase N" headers, is not a
# tracker this script can reason about — fail loud rather than read it as done.
# Test marker_lines() (the full ✅|🔄|⬜|❌|🔒 set) directly: once ❌ left
# incomplete_lines() above, an all-❌ (fully-descoped) tracker has zero ✅ AND zero
# open-marker lines yet is perfectly valid, so the old
# `done_count==0 && incomplete_lines empty` would now misread it as MALFORMED.
# marker_lines() still counts ❌, so the no-bullets invariant is preserved exactly.
# (marker_lines() is defined below; bash resolves it at call time, via validate().)
malformed() {
  [ -z "$(marker_lines)" ] && return 0
  [ -z "$(max_phase)" ] && return 0
  return 1
}

# ── Grammar-token validation ──
# The grammar is defined ONCE in the phase-docs skill ("Tracker grammar"):
# leading bold ID **[N.M]**, trailing `[deps: …]` token, `none` mandatory where
# empty. This validates well-formedness only — dep SEMANTICS (unknown IDs,
# cycles) belong to the resolver. A token-free tracker is LEGACY and
# skips validation entirely, so old initiatives parse exactly as before.
ID_RE='\*\*\[[0-9]+\.[0-9]+\]\*\*'
DEPS_RE='`\[deps: (none|[0-9]+\.[0-9]+(, [0-9]+\.[0-9]+)*)\]`'
# 🔒 (human-gated, [10.1]) is recognized in the marker class alongside the four
# original markers — the same set the resolver parses — so a 🔒 deliverable line
# is a well-formed bullet, never read as MALFORMED nor dropped from validation.
marker_lines() { grep -E '^\s*-\s*(✅|🔄|⬜|❌|🔒)' "$TRACKER"; }

# The scaffold seeds docs/PHASE_STATUS.md with VERBATIM placeholder deliverables —
# `- ⬜ [Deliverable N …]` stubs that /guv:init and /guv:plan overwrite
# with authored wording. A placeholder is the literal bracketed stub; a genuine
# deliverable is real prose (LEGACY) or a leading **[N.M]** ID (grammar) — never
# the stub. Match it verbatim (the bracket is required: a real prose line that
# merely contains the word "Deliverable", e.g. "- ⬜ Deliverable C not started",
# has no `[Deliverable N` and is correctly NOT a placeholder).
PLACEHOLDER_RE='^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*\[Deliverable [0-9]'
# Deliverable bullets carrying authored wording — every marker line that is not a
# verbatim scaffold placeholder. Empty ⟺ the tracker is UNAUTHORED (only stubs).
authored_lines() { marker_lines | grep -vE "$PLACEHOLDER_RE"; }

# Emits one line per violation; emits nothing for LEGACY or a clean tracker.
grammar_errors() {
  local lines bad dups
  lines=$(marker_lines)
  # LEGACY: no ID and no deps token anywhere → nothing to validate. Gate on
  # lead-position IDs and deps-shaped constructs — a bold cross-reference or a
  # stray "[deps:" substring in legacy prose must not flip a token-free
  # tracker into grammar mode.
  if ! echo "$lines" | grep -qE "^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*$ID_RE" \
     && ! echo "$lines" | grep -qE '`?\[deps:[^]]*\]`?'; then
    return 0
  fi
  # every deliverable line leads with an ID (right after the status marker)
  bad=$(echo "$lines" | grep -vE "^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*$ID_RE")
  [ -n "$bad" ] && printf 'missing or misplaced **[N.M]** ID:\n%s\n' "$bad"
  # ...and carries a well-formed deps token (`none` mandatory — a forgotten
  # annotation must fail loud, not silently read as no-deps). The deliverable's
  # own token is the LAST deps-shaped construct on the line (annotations follow
  # it but quoted examples precede it), so validate that one — a well-formed
  # example earlier in the wording must not mask a malformed real token.
  bad=$(echo "$lines" | while IFS= read -r l; do
    tok=$(printf '%s\n' "$l" | grep -oE '`?\[deps:[^]]*\]`?' | tail -1)
    printf '%s\n' "$tok" | grep -qE "^$DEPS_RE\$" || printf '%s\n' "$l"
  done)
  [ -n "$bad" ] && printf 'missing or malformed `[deps: …]` token:\n%s\n' "$bad"
  # IDs are unique across the whole tracker — count only the leading ID, so a
  # cross-reference like **[6.1]** mid-wording is not a spurious duplicate
  dups=$(echo "$lines" | grep -oE "^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*$ID_RE" | grep -oE "$ID_RE" | sort | uniq -d)
  [ -n "$dups" ] && printf 'duplicate deliverable IDs:\n%s\n' "$dups"
  return 0
}

# Shared MALFORMED gate for --check and --archive: structural shape first,
# then grammar tokens. Prints the reason to stderr and returns 5 on failure.
validate() {
  if malformed; then
    echo "status=MALFORMED — $TRACKER has no recognizable deliverable bullets / phase headers" >&2
    return 5
  fi
  local gerr
  gerr=$(grammar_errors)
  if [ -n "$gerr" ]; then
    echo "status=MALFORMED — grammar-token validation failed (grammar: phase-docs skill, 'Tracker grammar'):" >&2
    echo "$gerr" >&2
    return 5
  fi
  return 0
}

# Everything that blocks initiative-COMPLETE: open-marker lines PLUS lone-
# deliverable phases that are done but not yet sealed (the [15.7] carve — see
# unsealed_lone_phases). One list so --check names every blocker and --archive
# refuses on any of them.
incomplete_all() {
  local inc lone
  inc=$(incomplete_lines)
  lone=$(unsealed_lone_phases)
  printf '%s' "$inc"
  [ -n "$inc" ] && [ -n "$lone" ] && printf '\n'
  printf '%s' "$lone"
}

check() {
  if [ ! -f "$TRACKER" ]; then
    echo "status=NONE"
    return 4
  fi
  validate || return 5
  # A tracker carrying ONLY verbatim scaffold placeholders is UNAUTHORED — there
  # is no real initiative to complete or archive. Read it as NONE (exit 4),
  # exactly like an absent tracker, so /guv:plan Step 1 maps it to "nothing to
  # archive, number from 1" — the right signal on the fresh-onboard → first-plan
  # path. Without this the placeholder ⬜s read as INCOMPLETE and /plan refuses a
  # first-time user's first initiative ([19.1]). A genuine deliverable (LEGACY
  # prose or grammar) is never a placeholder, so a real tracker is unaffected; a
  # tracker mixing real grammar with stray stubs trips grammar validation above
  # (the stub lacks an ID) and fails MALFORMED, loud — never silently NONE.
  if [ -z "$(authored_lines)" ]; then
    echo "status=NONE — $TRACKER holds only unauthored scaffold placeholders"
    return 4
  fi
  local inc
  inc=$(incomplete_all)
  if [ -n "$inc" ]; then
    echo "status=INCOMPLETE"
    echo "$inc"
    return 3
  fi
  echo "status=COMPLETE"
  echo "max_phase=$(max_phase)"
  return 0
}

archive() {
  local name="$1" force="${2:-}"
  if [ ! -f "$TRACKER" ] || [ ! -f "$REQS" ]; then
    echo "status=NONE — nothing to archive (no $TRACKER / $REQS)" >&2
    return 4
  fi
  validate || return 5
  local inc
  inc=$(incomplete_all)
  if [ -n "$inc" ] && [ "$force" != "--force" ]; then
    echo "status=INCOMPLETE — refusing to archive. Finish these (an unsealed lone-deliverable phase needs phase-close) or re-run with --force to abandon:" >&2
    echo "$inc" >&2
    return 3
  fi

  # kebab-case slug; NNN = highest existing index + 1 (count-based numbering
  # would re-issue an index after a gap and could merge into a frozen archive).
  local slug max nnn dir
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
  if [ -z "$slug" ]; then
    echo "usage: --archive <name> — name must contain at least one alphanumeric character" >&2
    return 2
  fi
  max=$(ls -d docs/initiatives/[0-9][0-9][0-9]-* 2>/dev/null | sed 's|.*/\([0-9]\{3\}\)-.*|\1|' | sort -n | tail -1)
  nnn=$(printf '%03d' $(( 10#${max:-0} + 1 )))   # 10#: don't octal-parse "008"
  dir="docs/initiatives/$nnn-$slug"
  mkdir -p "$dir"

  local range="$(min_phase)-$(max_phase)"
  if [ -n "$inc" ]; then
    printf '\n> **ABANDONED %s** — archived with incomplete deliverables (see unchecked items above).\n' \
      "$(date +%Y-%m-%d)" >> "$TRACKER"
  fi
  mv "$REQS" "$dir/REQUIREMENTS.md"
  mv "$TRACKER" "$dir/PHASE_STATUS.md"
  [ -f "$ARCH" ] && cp "$ARCH" "$dir/ARCHITECTURE.md"   # snapshot; original persists

  echo "archive_dir=$dir"
  echo "phase_range=$range"
  return 0
}

case "${1:-}" in
  --check)   check; exit $? ;;
  --archive) [ -n "${2:-}" ] || { echo "usage: --archive <name> [--force]" >&2; exit 2; }
             archive "$2" "${3:-}"; exit $? ;;
  *)         echo "usage: bash .claude/archive-initiative.sh --check | --archive <name> [--force]" >&2
             exit 2 ;;
esac
