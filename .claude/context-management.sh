#!/bin/bash
# .claude/context-management.sh
# [16.2] — the operator's context-wall posture. Two deterministic operations:
#   set-mode  records the MODE CHOICE in the manifest's contextManagement block
#   surface   turns the manifest state into the right person-visible signal
#
# This is the carrier block + the discriminator + the surfacing ONLY. The arming
# of the chosen governor (occupancy setpoint vs auto-compaction window) is [16.4];
# the auto-compaction env carrier (CLAUDE_CODE_AUTO_COMPACT_WINDOW) is [16.3].
#
# Design authority: docs/spikes/16-1-context-wall-mode.md (Q1 no-silent-default,
# Q2 the manifest-block carrier + three population paths, and the build-time
# watch-items). The discriminator (watch-item c) makes the block's PRESENCE the
# scaffold-provenance signal: present (any mode) = scaffolded by a
# contextManagement-aware guv; absent = predates the feature. So a fresh headless
# scaffold (present, mode=unset → loud marker) and a block-less in-field project
# (absent → one-time grandfather nudge) are told apart by presence, never by
# block-absence alone.
#
# [16.4] adds a third operation, `reconcile`, which drives the sibling helpers
# (auto-compact-carrier.sh [16.3], compaction-setpoint.sh [14.2]) to arm exactly
# one governor for the chosen mode — so BASE resolves where those siblings live.
set -u

# The directory holding this script and its sibling helpers (carrier + setpoint),
# resolved so reconcile finds them regardless of the caller's CWD. Falls back to "."
# if the path can't be resolved (never aborts under set -u).
BASE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || BASE="."

usage() {
  cat >&2 <<'EOF'
usage: context-management.sh <command> <args>
  set-mode  <manifest> <hard-stop|continue|unset>            record the operator's mode choice
  surface   <manifest>                                       emit the population-appropriate signal (or nothing)
  reconcile <manifest> [--settings PATH] [--model MODEL]     reconcile the governor to the chosen mode (--model accepted but ignored)
EOF
  exit 2
}

MODES_RE='^(hard-stop|continue|unset)$'
MARKER_NAME='.context-wall-migration-nudged'
GUIDE_MARKER_NAME='.context-wall-continue-guided'   # [16.4] continue-mode guidance: once, not every session

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  set-mode)
    MAN="${1:-}"; MODE="${2:-}"
    [ -n "$MAN" ] && [ -n "$MODE" ] || usage
    # Refuse an unknown mode LOUDLY. A silent fallback to a real mode here is the
    # config-layer form of the exact defect Q1 rejects — no silent default.
    if ! printf '%s' "$MODE" | grep -Eq "$MODES_RE"; then
      echo "[context-management] unknown mode '$MODE' — expected hard-stop | continue | unset" >&2
      exit 1
    fi
    # The manifest must exist and parse; the write was requested, so a missing or
    # garbage manifest is a loud failure, never a silent no-op (Rule 15).
    if [ ! -f "$MAN" ] || ! jq -e . "$MAN" >/dev/null 2>&1; then
      echo "[context-management] manifest missing or unparseable: $MAN" >&2
      exit 1
    fi
    tmp=$(mktemp) || exit 1
    if jq --arg m "$MODE" '.contextManagement.mode = $m' "$MAN" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$MAN"
      echo "[context-management] mode=$MODE"
    else
      rm -f "$tmp"
      echo "[context-management] failed to write mode into $MAN" >&2
      exit 1
    fi
    ;;

  surface)
    MAN="${1:-}"
    [ -n "$MAN" ] || usage
    # Read-mostly and never-blocking: surface is consumed by the session-start
    # hook, so absent jq or a missing/unparseable manifest degrades to silence at
    # exit 0 (Rule 15 — a surfacing helper never denies the session its start).
    command -v jq >/dev/null 2>&1 || exit 0
    { [ -f "$MAN" ] && jq -e . "$MAN" >/dev/null 2>&1; } || exit 0

    # Block PRESENCE is the scaffold-provenance signal (watch-item c).
    HAS=$(jq -r 'if has("contextManagement") then "yes" else "no" end' "$MAN" 2>/dev/null)
    if [ "$HAS" = "yes" ]; then
      MODE=$(jq -r '.contextManagement.mode // "unset"' "$MAN" 2>/dev/null)
      case "$MODE" in
        hard-stop)
          : # configured — the occupancy meter owns the wall; nothing unconfigured to surface
          ;;
        continue)
          # continue is armed: auto-compaction owns the wall, the meter demotes to advisory.
          # guv NEVER arms the compaction window on the operator's behalf — not even the
          # blessed value, not even on a [1m] run (the ratified [16.4] continue-arm decision:
          # GUIDE, don't auto-arm; the [14.2] operator-authored doctrine). If no window is
          # operator-authored, GUIDE them to author one — ONCE (a fine resting state otherwise:
          # auto-compaction falls back to the model's native default, so this nudges, not shouts).
          # Suppressed the moment a window is authored, and after the one-shot marker is set.
          GSET="$(dirname "$MAN")/settings.local.json"
          GCUR=$(jq -r '.env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] // empty' "$GSET" 2>/dev/null)
          GMARKER="$(dirname "$MAN")/$GUIDE_MARKER_NAME"
          if [ -z "$GCUR" ] && [ ! -f "$GMARKER" ]; then
            printf '%s\n' "guv context-wall: continue mode is armed — auto-compaction will compact across the wall using the model's native default. To set an explicit compaction point, author CLAUDE_CODE_AUTO_COMPACT_WINDOW in .claude/settings.local.json; guv leaves that choice to you and never arms it on your behalf. (Shown once.)"
            : > "$GMARKER" 2>/dev/null || true   # best-effort; a failed write re-guides (safe), never crashes
          fi
          ;;
        *)
          # mode=unset (or a present block with no/blank/unknown mode) → loud-unset.
          # 'loud' means VISIBLE (watch-item a): this reaches session-open context.
          printf '%s\n' "guv context-wall mode UNSET — this project was scaffolded without choosing a context-management posture, so neither the occupancy hard-stop nor auto-compaction is armed. Choose a mode by setting contextManagement.mode to hard-stop (a clean stop and handoff at the wall) or continue (auto-compact across it) in .claude/project.json."
          ;;
      esac
    else
      # Block ABSENT → an in-field project predating the feature. Grandfather to
      # today's behavior and nudge ONCE, non-blocking — gated on a durable
      # did-fire marker so it fires once, not every session (watch-item b).
      MARKER="$(dirname "$MAN")/$MARKER_NAME"
      if [ ! -f "$MARKER" ]; then
        printf '%s\n' "guv context-wall mode is now available — you can choose how guv handles the context wall (hard-stop: a clean stop and handoff; continue: auto-compact across it). This project predates the feature and continues with today's behavior until you opt in by setting contextManagement.mode in .claude/project.json. (Shown once.)"
        : > "$MARKER" 2>/dev/null || true   # best-effort; a failed write re-nudges (safe), never crashes
      fi
    fi
    ;;

  reconcile)
    # [16.4] — arm/disarm so EXACTLY ONE threshold is authoritative for the chosen
    # mode (spike Q3). The occupancy meter reads the same mode and stands down or
    # arms itself (occupancy-meter.sh); this is the auto-compaction HALF — it drives
    # the [16.3] carrier to deploy or withdraw CLAUDE_CODE_AUTO_COMPACT_WINDOW to
    # match. Wired into session-start so the two governors re-reconcile every session.
    MAN="${1:-}"; shift 2>/dev/null || true
    [ -n "$MAN" ] || usage
    SETTINGS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --settings) [ $# -ge 2 ] || { echo "[context-management] --settings requires a path" >&2; exit 2; }; SETTINGS="$2"; shift 2 ;;
        # --model is still ACCEPTED (callers and the R1/R1c/R5 tests pass it) but the value
        # is intentionally DISCARDED — under guide-don't-auto-arm there is no value reconcile
        # would deploy, so it is consumed for compatibility, not stored.
        --model)    [ $# -ge 2 ] || { echo "[context-management] --model requires a value" >&2; exit 2; }; shift 2 ;;
        *) echo "[context-management] unknown reconcile option '$1'" >&2; exit 2 ;;
      esac
    done

    # Never-blocking, like surface: this runs at session start. No jq, or a missing/
    # unparseable manifest, or no carrier present (a partial install) → clean no-op
    # exit 0 (Rule 15 — reconcile never denies the session its start).
    command -v jq >/dev/null 2>&1 || exit 0
    { [ -f "$MAN" ] && jq -e . "$MAN" >/dev/null 2>&1; } || exit 0
    CARRIER="$BASE/auto-compact-carrier.sh"
    [ -f "$CARRIER" ] || exit 0
    SET="${SETTINGS:-$(dirname "$MAN")/settings.local.json}"
    MODE=$(jq -r '.contextManagement.mode // "absent"' "$MAN" 2>/dev/null)

    # Both branches below invoke the carrier with its stdout suppressed (the success
    # banner would clutter session start) but its STDERR let through. That is deliberate:
    # the carrier's Rule-15 `die 4` refusal over a malformed settings.local.json (a
    # non-object root or .env) is a DESIGNED loud stop — reconcile must not swallow it, or
    # a direct caller never learns their settings are unmergeable. The `|| exit 0` governs
    # reconcile's own EXIT CODE only: it never propagates the carrier's failure as a
    # session block (the carrier already protected the file by REFUSING to clobber — it
    # touched nothing). The never-block silence is the session-start caller's to apply at
    # its own boundary (`reconcile … 2>&1 || true`), not reconcile's to bury here.
    case "$MODE" in
      continue)
        # continue = auto-compaction owns the wall; the meter demotes to advisory. guv
        # NEVER arms the compaction window on the operator's behalf — not the blessed
        # validated_reference, not even on a [1m] --model run (the ratified [16.4]
        # continue-arm decision: GUIDE, don't auto-arm — the [14.2] operator-authored
        # doctrine taken to its conclusion). So reconcile places NOTHING here: an
        # operator-authored window survives because this branch touches nothing (a
        # literal no-op — the carrier is not even invoked in continue mode), and absent
        # one the window stays UNSET so the model's native auto-compaction default
        # governs. `surface` GUIDES the operator to author a window if they want an
        # explicit point. --model is accepted (callers pass it) but deliberately NOT
        # consulted — there is no value reconcile would deploy.
        : # no-op — never arm; the authored window (if any) is preserved untouched
        ;;
      *)
        # hard-stop → the carrier WITHDRAWS the window (the meter owns the wall, so a
        # lingering window must never pre-empt it). unset / absent → the carrier is a
        # no-op (it never strips a window it did not place — a hand-deployed setpoint
        # like guv-guv's own live 250000 survives). The carrier reads the SAME mode and
        # does the right thing; reconcile just invokes it value-free.
        bash "$CARRIER" apply "$MAN" --settings "$SET" >/dev/null || exit 0
        ;;
    esac
    exit 0
    ;;

  ""|-h|--help) usage ;;
  *) echo "[context-management] unknown command: $cmd" >&2; usage ;;
esac
