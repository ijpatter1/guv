#!/bin/bash
# .claude/context-management.sh
# [16.2] — the operator's context-wall posture. Two deterministic operations:
#   set-mode  records the MODE CHOICE in the manifest's contextManagement block
#   surface   turns the manifest state into the right person-visible signal
#
# This is the manifest block + the discriminator + the surfacing ONLY. The
# occupancy meter arms itself from the mode (occupancy-meter.sh); the
# auto-compaction window (CLAUDE_CODE_AUTO_COMPACT_WINDOW) is operator-authored
# in the settings env block — guv never places or strips it ([32.2]).
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
# ([16.4]'s `reconcile` verb is gone: its auto-compaction half was the [16.3]
# carrier, deleted at [32.2] with the continuation machinery, and a verb that
# provably does nothing earns no wiring. surface's hard-stop arm carries the
# one disclosure that half still owes: a lingering operator-authored window.)
set -u

usage() {
  cat >&2 <<'EOF'
usage: context-management.sh <command> <args>
  set-mode  <manifest> <hard-stop|continue|unset>            record the operator's mode choice
  surface   <manifest>                                       emit the population-appropriate signal (or nothing)
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
          # The meter owns the wall — but guv no longer withdraws a lingering
          # auto-compaction window ([32.2] deleted the [16.3] carrier), so an
          # operator-authored window here means BOTH governors are armed and
          # auto-compaction can pre-empt the meter's clean stop. Surface the
          # conflict EVERY session until the operator clears it: a warning,
          # never an edit (guide, don't act). settings.local.json wins over
          # settings.json, matching the runtime's own precedence.
          HCUR=$(jq -r '.env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] // empty' "$(dirname "$MAN")/settings.local.json" 2>/dev/null)
          [ -n "$HCUR" ] || HCUR=$(jq -r '.env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] // empty' "$(dirname "$MAN")/settings.json" 2>/dev/null)
          if [ -n "$HCUR" ]; then
            printf '%s\n' "guv context-wall: hard-stop mode is chosen, but CLAUDE_CODE_AUTO_COMPACT_WINDOW=$HCUR is authored in the settings env block — auto-compaction can pre-empt the meter's clean stop and handoff. guv never edits your settings: remove the env entry to give the meter the wall, or switch to continue mode."
          fi
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

  ""|-h|--help) usage ;;
  *) echo "[context-management] unknown command: $cmd" >&2; usage ;;
esac
