#!/bin/bash
# .claude/auto-compact-carrier.sh
# [16.3] The auto-compaction CARRIER — the writer primitive that deploys (or
# withdraws) CLAUDE_CODE_AUTO_COMPACT_WINDOW in the gitignored local settings,
# GATED on the operator's chosen context-wall mode (the [16.2] manifest block).
#
# WHY a carrier. [16.2] records the mode (hard-stop|continue|unset) in the
# manifest's contextManagement block. compaction-setpoint.sh ([14.2]) already
# DERIVES a window band (`recommend`) and VERIFIES a deployed value (`check`) — but
# nothing WRITES the value into settings.local.json; deploy was a manual human edit.
# This is that missing writer, and it is mode-gated (the S1 finding's Q3,
# docs/spikes/16-1-context-wall-mode.md):
#   continue  → the window is PRESENT  (auto-compaction armed across the wall)
#   hard-stop → the window is ABSENT   (the occupancy setpoint owns the wall; the
#               window must never linger and pre-empt it — "exactly one
#               authoritative threshold")
#   unset / no contextManagement block → NO-OP. No mode was chosen, so there is
#               nothing to carry; and a block-LESS in-field project is grandfathered
#               (format-survival), so the carrier must NOT strip a window it never
#               deployed — a pre-feature project may carry a HAND-deployed setpoint
#               (guv-guv's own live 250000 is exactly this) and the carrier leaves it
#               untouched. The loud-unset MARKER is [16.2]'s surface, not the
#               carrier's job; the full meter↔compaction arm/disarm is [16.4]'s.
#
# BOUNDARY (Rule 4 — surgical). This script PLACES a window value; it never INVENTS
# one (the [14.2] doctrine: the setpoint is human-authored, the mechanism just
# places it — compaction-setpoint.sh ships the band, never a default value). So
# `apply` under `continue` REQUIRES --window N (a loud refusal otherwise — Rule 15,
# no guessed value). It does not band-check the value (that is compaction-setpoint.sh
# `check`'s lane) beyond "a malformed value is not a window". The model-aware window
# derivation, the meter demotion, and the warn-band warning are [16.4]; this is only
# the carrier [16.4] will call.
#
# SHAPE. The value is written as a STRING under the settings `env` block — the exact
# shape compaction-setpoint.sh proved fires and reads back:
#   {"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"<value>"}}
# Every write MERGES: it sets or deletes ONLY this one key, preserving all other
# settings (other env vars, permissions, …). settings.local.json is gitignored (the
# scaffold .gitignore covers it), so the carried window never surfaces as untracked.
#
# WIRING ([14.1] finding e). The settings file defaults to settings.local.json beside
# the manifest; --settings overrides it. Ships in the plugin like the other
# .claude/*.sh scripts (build-plugin rewrites the path).
set -u

VAR='CLAUDE_CODE_AUTO_COMPACT_WINDOW'

die() { local code="$1"; shift; printf 'auto-compact-carrier: %s\n' "$*" >&2; exit "$code"; }
# A window is a POSITIVE integer with no leading zero: 0 is never a valid window, and
# a leading zero ('0250000') is both ambiguous and risks an octal misread downstream.
is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0*) return 1 ;; *) return 0 ;; esac; }

[ $# -ge 1 ] || die 2 "usage: bash .claude/auto-compact-carrier.sh apply <manifest> [--settings PATH] [--window N]"
VERB="$1"; shift
case "$VERB" in apply) ;; *) die 2 "unknown verb '$VERB' (only: apply)" ;; esac

[ $# -ge 1 ] || die 2 "apply requires a manifest path: apply <manifest> [--settings PATH] [--window N]"
case "$1" in --*) die 2 "apply requires a manifest path before any options" ;; esac
MAN="$1"; shift

SETTINGS=""; WINDOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    # A flag with no following value must REFUSE loudly, never spin: `shift 2` on a
    # one-element list does not consume the flag, so an unguarded loop hangs forever
    # on a trailing `--window` — and a hang is the one outcome Rule 15 forbids.
    --settings) [ $# -ge 2 ] || die 2 "--settings requires a path argument"; SETTINGS="$2"; shift 2 ;;
    --window)   [ $# -ge 2 ] || die 2 "--window requires a value (a positive integer)"; WINDOW="$2"; shift 2 ;;
    *) die 2 "unknown option '$1'" ;;
  esac
done

# A writer that round-trips JSON cannot proceed without jq — a NAMED loud stop,
# never a guessed or skipped write.
command -v jq >/dev/null 2>&1 || die 3 "jq is required to read the manifest and write the settings JSON (not found on PATH)"

# The manifest must exist and parse — the mode is read from it.
[ -f "$MAN" ] || die 2 "manifest not found: $MAN"
jq empty "$MAN" >/dev/null 2>&1 || die 2 "manifest is not valid JSON: $MAN"

# Default the carrier file to settings.local.json beside the manifest's project.
[ -n "$SETTINGS" ] || SETTINGS="$(dirname "$MAN")/settings.local.json"

# A present-but-empty block, or an absent block, both read as "unset" here — the
# carrier treats them identically (no window to carry). The [16.2] discriminator
# (telling headless-unset from grandfather) is a SURFACING concern, not the
# carrier's: either way there is no chosen mode, so no window is deployed.
MODE=$(jq -r '.contextManagement.mode // "unset"' "$MAN" 2>/dev/null)

# An existing settings file must be SHAPE-COMPATIBLE before we merge into it — refuse
# to clobber hand-edited content, and refuse to attempt a merge jq cannot complete
# (Rule 15: look before you overwrite; a named loud stop, never a cryptic jq error).
# Valid JSON is not enough: the root must be an object, and `.env` must be an object
# or absent — otherwise `.env = ((.env // {}) + {…})` / `del(.env[…])` would error.
require_mergeable_settings() {
  [ -f "$SETTINGS" ] || return 0
  jq empty "$SETTINGS" >/dev/null 2>&1 \
    || die 4 "existing $SETTINGS is not valid JSON — refusing to clobber it; fix or remove it first (Rule 15)"
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || die 4 "existing $SETTINGS is not a JSON object — refusing to merge a settings env block into it (Rule 15)"
  jq -e '(.env == null) or (.env | type == "object")' "$SETTINGS" >/dev/null 2>&1 \
    || die 4 "existing $SETTINGS has a non-object .env — refusing to merge into it (Rule 15)"
}

case "$MODE" in
  continue)
    is_pos_int "$WINDOW" || die 2 "apply under 'continue' requires --window N (a positive integer, no leading zero) — the carrier PLACES an operator-authored setpoint, it never guesses one (run 'bash .claude/compaction-setpoint.sh recommend' to derive an in-band window)"
    require_mergeable_settings
    tmp="$(mktemp)"
    if [ -f "$SETTINGS" ]; then
      jq --arg k "$VAR" --arg w "$WINDOW" '.env = ((.env // {}) + {($k): $w})' "$SETTINGS" > "$tmp" \
        && mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die 4 "failed to write the carrier into $SETTINGS"; }
    else
      mkdir -p "$(dirname "$SETTINGS")"
      jq -n --arg k "$VAR" --arg w "$WINDOW" '{env: {($k): $w}}' > "$tmp" \
        && mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die 4 "failed to create the carrier at $SETTINGS"; }
    fi
    printf '[auto-compact-carrier] mode=continue %s=%s deployed to %s\n' "$VAR" "$WINDOW" "$SETTINGS"
    ;;
  hard-stop)
    # The window must be ABSENT. Strip ONLY this key from an existing file; never
    # create a file just to express absence (absence is the default state).
    [ -f "$SETTINGS" ] || exit 0
    require_mergeable_settings
    if [ -n "$(jq -r ".env.$VAR // empty" "$SETTINGS" 2>/dev/null)" ]; then
      tmp="$(mktemp)"
      jq --arg k "$VAR" 'del(.env[$k])' "$SETTINGS" > "$tmp" \
        && mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die 4 "failed to strip the carrier from $SETTINGS"; }
      printf '[auto-compact-carrier] mode=hard-stop %s withdrawn from %s\n' "$VAR" "$SETTINGS"
    fi
    ;;
  unset)
    # No mode chosen (or a block-less in-field project): the carrier has nothing to
    # deploy and must not touch a setpoint it never placed. Clean no-op.
    :
    ;;
  *)
    die 5 "unknown context-management mode '$MODE' in $MAN — the carrier handles only continue|hard-stop|unset (set via 'bash .claude/context-management.sh set-mode')"
    ;;
esac
exit 0
