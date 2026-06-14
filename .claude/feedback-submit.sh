#!/bin/bash
# .claude/feedback-submit.sh — feedback-transport submit mode ([10.8]).
#
# Drains open `routing: upstream` feedback entries from this control plane into the
# guv SOURCE repo as issues, replacing the manual copy-paste a consumer does today.
# For each open upstream entry that has no upstream link yet it DRAFTS an issue
# (title + body) and writes a draft annotation back onto the entry, so a re-run is
# idempotent — deduped by entry id via that writeback marker. Non-upstream,
# already-linked, and non-open entries are skipped, untouched.
#
# CRITICAL — issue FILING is user-gated (the `log-feedback` "Closing the loop"
# contract): the permission classifier denies an agent's `gh issue create` as an
# outward publish. So this transport NEVER calls `gh issue create`. It builds the
# draft/dedupe/writeback machinery and EMITS the exact `gh issue create` command for
# the USER to run; the user files, and pastes the resulting URL back (or the draft
# marker already makes the re-run a no-op). The agent drafts; the person files.
#
# The only tracker call this script makes is `gh repo view` against the guv source
# repo — for reachability and slug resolution. If the tracker is unreachable it
# degrades LOUDLY (non-zero exit + message) and writes NOTHING (no half-writeback
# against an unverified tracker) — never a silent drop (Rule 15).
#
# Usage:
#   bash .claude/feedback-submit.sh submit [--dry-run] [--log <path>] [--repo <slug>]
#
#   --dry-run   list what would be filed (the drainable entries + their drafts)
#               WITHOUT mutating the log. Still probes the tracker — a dry run that
#               claims success against an unreachable tracker would be a lie.
#   --log       override the feedback-log path (tests; default is control-plane
#               relative: .claude/feedback/feedback.ndjson).
#   --repo      override the tracker slug (owner/name) instead of resolving it from
#               the code repo's remote (tests / explicit targeting).
#
# The `gh` binary is resolved through the GUV_GH seam (default: `gh`), so a test can
# inject a hermetic stub and the suite never touches the network.
#
# cwd must be the project root (where .claude/project.json lives) — the same
# contract every sibling helper carries.
#
# Exit: 0 ok (drained / nothing to drain / dry-run) · 2 usage ·
#       3 issue tracker unreachable (loud degrade) · 4 no/corrupt manifest.
set -u

GH="${GUV_GH:-gh}"

err() { echo "feedback-submit: $1" >&2; }
die() { err "$2"; exit "$1"; }

[ $# -ge 1 ] || die 2 "usage: bash .claude/feedback-submit.sh submit [--dry-run] [--log path] [--repo slug]"
SUB="$1"; shift
[ "$SUB" = "submit" ] || die 2 "unknown subcommand '$SUB' (only: submit)"

DRY_RUN=0
LOG=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --log)     LOG="${2:-}"; shift 2 ;;
    --repo)    REPO="${2:-}"; shift 2 ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

# --- project root + log path (control-plane relative, the sibling convention) -
MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || die 4 "no manifest at $MANIFEST (cwd must be the project root)"
jq -e . "$MANIFEST" >/dev/null 2>&1 \
  || die 4 "$MANIFEST exists but is not valid JSON — fix the manifest"
[ -n "$LOG" ] || LOG=".claude/feedback/feedback.ndjson"

# --- resolve the tracker slug (owner/name) -----------------------------------
# Explicit --repo wins. Otherwise resolve from the code repo's clone (roots.code):
# `gh repo view` reads the remote and reports nameWithOwner. The code repo is the
# local guv source checkout; its GitHub repo is the issue tracker. A missing
# roots.code means single-repo — the code repo IS this repo.
CODE=$(jq -r '.roots.code // "."' "$MANIFEST")
{ [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."

# Resolve the slug by running `gh repo view` INSIDE the code-repo clone (it reads
# the clone's remote). gh's -R takes an OWNER/REPO slug, never a local path, so a
# `cd` into the clone is the correct way to address "the repo this clone points at".
if [ -z "$REPO" ]; then
  REPO=$( cd "$CODE" 2>/dev/null && "$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null )
fi

# --- tracker reachability probe (loud degrade on failure) --------------------
# A single `gh repo view` against the tracker. Unreachable -> exit 3, write
# nothing. This runs in BOTH submit and dry-run modes: a dry run that announces
# drafts against a tracker it never reached would be a silent-failure lie.
if [ -n "$REPO" ]; then
  "$GH" repo view "$REPO" >/dev/null 2>&1 \
    || die 3 "issue tracker '$REPO' is unreachable — refusing to drain (no entry dropped, log untouched)"
else
  # No --repo and no resolvable remote: probe the code-repo clone directly so an
  # offline tracker still degrades loud rather than silently draining nowhere.
  ( cd "$CODE" 2>/dev/null && "$GH" repo view >/dev/null 2>&1 ) \
    || die 3 "could not reach an issue tracker for roots.code ('$CODE') — refusing to drain"
fi

# --- nothing to drain when the log is absent (clean no-op, not an error) ------
if [ ! -f "$LOG" ]; then
  echo "[feedback-submit] no feedback log at $LOG — nothing to draft (0 entries)"
  exit 0
fi

# --- select the drainable entries --------------------------------------------
# Drainable = status open AND routing upstream AND no existing upstream link.
# "No upstream link yet" matches today's manual convention: the link is recorded
# as an issue URL inside `detail` (e.g. "Issue: https://github.com/<repo>/issues/N")
# and, once this transport runs, a DRAFTED-<id> marker. Either means linked ->
# skip, which is what makes a re-run a no-op (dedupe by id). The match is on the
# tracker's issues URL so a stray github.com link elsewhere doesn't falsely skip.
DRAIN_IDS=$(jq -r --arg repo "$REPO" '
    select(.status == "open" and .routing == "upstream")
    | . as $e
    | select(($e.detail // "") | (
        contains("github.com/" + $repo + "/issues/") or
        contains("DRAFTED-" + $e.id)
      ) | not)
    | .id
  ' "$LOG")

if [ -z "$DRAIN_IDS" ]; then
  echo "[feedback-submit] 0 entries to draft — nothing open upstream and unlinked (no-op)"
  exit 0
fi

COUNT=$(printf '%s\n' "$DRAIN_IDS" | grep -c .)
MODE_LABEL="submit"; [ "$DRY_RUN" = "1" ] && MODE_LABEL="DRY-RUN"
echo "[feedback-submit] $MODE_LABEL: $COUNT upstream entr$([ "$COUNT" = "1" ] && echo "y" || echo "ies") to draft against $REPO"

DATE=$(date -u +%Y-%m-%d)

# --- per-entry: build the draft, emit the user's filing command, write back ---
# We rewrite the NDJSON whole (it is small, the same discipline the triage step
# uses). On a dry run we list the drafts and the filing commands but never write.
tmp=""
if [ "$DRY_RUN" != "1" ]; then
  tmp=$(mktemp) || die 4 "could not create a temp file for the writeback"
  cp "$LOG" "$tmp"
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  ENTRY=$(jq -c --arg id "$id" 'select(.id==$id)' "$LOG")
  SUMMARY=$(printf '%s' "$ENTRY" | jq -r '.summary')
  DETAIL=$(printf '%s'  "$ENTRY" | jq -r '.detail // ""')
  ARTIFACT=$(printf '%s' "$ENTRY" | jq -r '.artifact // ""')
  SEVERITY=$(printf '%s' "$ENTRY" | jq -r '.severity // ""')

  # Issue draft: title from the summary; body carries the entry id (so the filed
  # issue cites it, per the drain contract), the artifact, severity, and detail.
  TITLE="[feedback] $SUMMARY"
  BODY=$(printf 'Drained from control-plane feedback entry \`%s\`.\n\nArtifact: %s\nSeverity: %s\n\n%s\n\n_Cite this entry id when closing: %s_' \
    "$id" "$ARTIFACT" "$SEVERITY" "$DETAIL" "$id")

  echo ""
  echo "  • entry $id — would file: $TITLE"
  # The exact command for the USER to run (issue filing is user-gated; the agent
  # NEVER runs this). Body is passed via stdin to avoid shell-quoting hazards.
  echo "    To file (user-gated): gh issue create -R \"$REPO\" --title \"$TITLE\" --body-file -"

  if [ "$DRY_RUN" != "1" ]; then
    # Writeback: append a DRAFTED marker to detail so a re-run skips this entry
    # (idempotency by id). The original detail is preserved (append, not replace),
    # matching the provenance-note convention (" | " separator) the triage step uses.
    NOTE="DRAFTED-$id ($DATE): issue drafted for $REPO by /log-feedback submit — user-gated filing pending"
    wb=$(mktemp) || die 4 "could not create a temp file for the writeback"
    jq -c --arg id "$id" --arg note "$NOTE" \
      'if .id==$id then .detail = ((.detail // "") + " | " + $note) else . end' \
      "$tmp" > "$wb" && mv "$wb" "$tmp" || { rm -f "$wb"; die 4 "writeback failed for entry $id"; }
  fi
done <<< "$DRAIN_IDS"

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "[feedback-submit] DRY-RUN complete: $COUNT would be drafted; nothing filed, log untouched."
else
  mv "$tmp" "$LOG"
  echo "[feedback-submit] drafted $COUNT entr$([ "$COUNT" = "1" ] && echo "y" || echo "ies"); writeback recorded. Run the emitted 'gh issue create' commands to file (user-gated)."
fi
exit 0
