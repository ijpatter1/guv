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
set -u

usage() {
  cat >&2 <<'EOF'
usage: context-management.sh <command> <args>
  set-mode <manifest> <hard-stop|continue|unset>   record the operator's mode choice
  surface  <manifest>                              emit the population-appropriate signal (or nothing)
EOF
  exit 2
}

MODES_RE='^(hard-stop|continue|unset)$'
MARKER_NAME='.context-wall-migration-nudged'

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
        hard-stop|continue)
          : # configured — nothing unconfigured to surface ([16.4] owns advisory)
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
