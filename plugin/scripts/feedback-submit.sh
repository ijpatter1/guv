#!/bin/bash
# .claude/feedback-submit.sh — feedback-transport submit mode ([10.8]).
#
# Drains open `routing: upstream` feedback entries from a guv dogfooding control
# plane into the guv SOURCE repo as issues, replacing the manual copy-paste that
# drain does today. (Its home is the dogfooding plane, where `roots.code` IS the
# harness source — see the AUDIENCE note at the tracker-resolution step; any other
# target is reached with `--repo`.) For each open upstream entry that has no upstream
# link yet it DRAFTS an issue (title + body) and writes a draft annotation back onto
# the entry, so a re-run is idempotent — deduped by entry id via that writeback
# marker (and by the real issue URL once the user pastes it back). Non-upstream,
# already-linked, and non-open entries are skipped, untouched.
#
# CRITICAL — issue FILING is user-gated (the `log-feedback` "Closing the loop"
# contract): an agent's `gh issue create` is denied as an outward publish. This is a
# project CONVENTION, not a hook that intercepts the call — so the enforcement here
# is that this transport NEVER itself calls `gh issue create`. It builds the
# draft/dedupe/writeback machinery and EMITS the exact `gh issue create` command —
# with the drafted body inline as a copy-pasteable `--body-file -` heredoc — for the
# USER to run. The user files, then pastes the resulting issue URL back into the
# entry's detail (the documented end-state; the dedupe matches that real URL too).
# Until then the DRAFTED-<id> marker keeps the re-run a no-op AND visibly reads
# "drafted, awaiting filing". The agent drafts; the person files.
#
# ACCEPTANCE REINTERPRETATION (consciously ratified, per Rule 7 — surface the
# conflict, pick the better-tested pattern, say why). REQUIREMENTS [10.8] reads:
# "a submit run files an issue per open upstream entry lacking a link and records
# the URL back on the entry." Taken literally that is an agent calling `gh issue
# create`. We deliberately DO NOT meet that wording, because it contradicts the
# older, load-bearing "Closing the loop" contract (predates this lane) that gates
# issue filing to the person. Where two patterns conflict we take the more recent /
# better-tested one and name the other (Rule 7): the user-gate wins; this transport
# DRAFTS + EMITS and the person files. So the deliverable's INTENT — close the
# manual copy-paste loop with a deduped, idempotent, URL-anchored end-state — is
# what we deliver; the literal "the agent files" verb is the part reinterpreted, and
# the reinterpretation is recorded here so it is a chosen position, not a silent gap.
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

# Single-quote-escape a string for a shell command we EMIT for the user to run.
# Wrap in single quotes and rewrite every embedded ' as '\'' so the value reaches
# their shell literally — no expansion of $, `…`, or "…", and no quote-break. The
# body uses a quoted heredoc; this is the same safety on the inline argument axis
# (--title, -R), where a summary carrying a ", $, or backtick would otherwise break
# the emitted command or run as a command substitution.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

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
# `gh repo view` reads the remote and reports nameWithOwner.
#
# AUDIENCE — this transport's home is a guv DOGFOODING control plane, where
# `roots.code` IS the harness source checkout (see maintainers/DOGFOODING.md:
# `roots.code` → ijpatter1/guv), so its GitHub repo is the right upstream tracker.
# That is the only context where the resolved default is correct. A plain plugin
# *consumer* (whose `roots.code` is their OWN product, not the guv upstream) has no
# manifest field naming the harness source — so for them the resolved default would
# be their own tracker, the wrong target. Two things keep that from being a silent
# misfire: (1) the resolved slug is ANNOUNCED ("…to draft against <REPO>") before any
# draft is emitted or written, so the operator sees the target every run; and (2)
# `--repo <owner/name>` is the explicit override to point the drain anywhere else.
# A consumer who wants the guv upstream passes `--repo` (or runs this from a plane
# whose `roots.code` is the harness).
CODE=$(jq -r '.roots.code // "."' "$MANIFEST")
{ [ -n "$CODE" ] && [ "$CODE" != "null" ]; } || CODE="."

# Resolve the slug by running `gh repo view` INSIDE the code-repo clone (it reads
# the clone's remote). gh's -R takes an OWNER/REPO slug, never a local path, so a
# `cd` into the clone is the correct way to address "the repo this clone points at".
REPO_FROM_CODE=0
if [ -z "$REPO" ]; then
  REPO=$( cd "$CODE" 2>/dev/null && "$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null )
  [ -n "$REPO" ] && REPO_FROM_CODE=1
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
# Name how the target was chosen so a wrong tracker can never go unnoticed: a slug
# resolved from roots.code is only the right upstream in a dogfooding plane — call
# it out, with the --repo override, so a consumer fork sees it before drafting.
if [ "$REPO_FROM_CODE" = "1" ]; then
  echo "[feedback-submit]   (target resolved from roots.code; pass --repo <owner/name> to drain elsewhere)"
fi

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
  BODY=$(printf 'Drained from control-plane feedback entry `%s`.\n\nArtifact: %s\nSeverity: %s\n\n%s\n\n_Cite this entry id when closing: %s_' \
    "$id" "$ARTIFACT" "$SEVERITY" "$DETAIL" "$id")

  echo ""
  echo "  • entry $id — would file: $TITLE"
  # The exact command for the USER to run (issue filing is user-gated; the agent
  # NEVER runs this). The body is delivered INLINE as a quoted-delimiter heredoc
  # piped to `--body-file -`: the whole block is one copy-pasteable unit that runs
  # VERBATIM — so it is emitted flush-left (no cosmetic indent, which a literal
  # `<<'…'` heredoc would carry into the body and which would stop the closing
  # delimiter from matching). The `'GUV-FEEDBACK-BODY'` quoting means the
  # multi-line body reaches gh literally (no shell expansion, no per-line quoting
  # hazard). So the issue the user files carries the FULL drafted body — never an
  # empty issue, never a hung stdin read.
  echo "    To file (user-gated), copy-paste this whole block:"
  echo ""
  # -R and --title are single-quote-escaped (shq) so a summary carrying a ", $, or
  # backtick reaches gh literally instead of breaking the quoting or running as a
  # command substitution — the quoted-heredoc safety the body already has, on the
  # inline-argument axis.
  echo "gh issue create -R $(shq "$REPO") --title $(shq "$TITLE") --body-file - <<'GUV-FEEDBACK-BODY'"
  printf '%s\n' "$BODY"
  echo "GUV-FEEDBACK-BODY"

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
  echo "[feedback-submit] drafted $COUNT entr$([ "$COUNT" = "1" ] && echo "y" || echo "ies"); writeback recorded."
  echo "[feedback-submit] Next: run each emitted block above to file (user-gated), then close the loop —"
  echo "[feedback-submit]   paste the issue URL gh prints back into that entry's detail"
  echo "[feedback-submit]   (e.g. ' | Issue: https://github.com/$REPO/issues/N'). The DRAFTED-<id>"
  echo "[feedback-submit]   marker means 'drafted, awaiting filing' until you do — that is how a draft"
  echo "[feedback-submit]   you never filed stays visible instead of looking linked."
fi
exit 0
