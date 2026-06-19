#!/bin/bash
# .claude/lane-recovery.sh — lane / subagent recovery ([14.5]).
#
# A fan-out lane is a Task subagent ([7.1]/[7.5]): it runs in its OWN context
# window with independent auto-compaction, and — the [14.1] lever-(d) finding — it
# receives NO SessionStart dispatch. So the [14.4] seamless re-injection path (which
# fires on SessionStart source=compact in the MAIN session) does not reach a lane. A
# lane that overflows its window cannot be resumed in place; recovery is
# re-spawn-from-disk, driven by the parent.
#
# This is the deterministic core of that ladder (the judgment — when a lane is at
# risk, how the parent re-seeds the fresh subagent — lives in lane-builder.md and the
# build-fanout runbook; Rule 12 keeps the routing in code):
#
#   detect                       — is this a child/lane context (CLAUDE_CODE_CHILD_SESSION=1)?
#                                  A child gets no re-injection rung, so recovery code
#                                  must know to self-checkpoint rather than wait for it.
#   checkpoint <id> [--dir D] [--note T]
#                                — the lane persists a recovery checkpoint to its own
#                                  worktree disk (the proven rung) carrying what a
#                                  fresh re-spawned subagent needs to resume.
#   assess <id> [--dir D]        — the PARENT's re-spawn decision over the lane's
#                                  returned state: land (finished) / respawn
#                                  (self-checkpointed) / fail (silent or failed).
#
# Ladder rungs (Rule 15): the PRIMARY rung is to size each lane under one window so it
# never compacts ([13.2] discipline — taught in the runbook, not enforced here); this
# script is the FALLBACK for a lane that must exceed one. DEGRADATION: each checkpoint
# field degrades independently (a non-git scratch dir still yields a checkpoint, with
# git null — never fabricated); a write/parse failure is a loud NAMED stop with a
# non-zero exit, never a silent or guessed result (Rule 10/15).
#
# Exit: 0 ok (assess: land or respawn) · 2 usage · 5 checkpoint write/parse failure
#       (loud stop) · 6 assess verdict = fail (the lane is a loud stop, not a re-spawn)
set -u

DIR="$PWD"; NOTE=""; ID=""
SCHEMA="guv.lane-recovery/1"
CKPT_NAME=".lane-checkpoint.json"
OUT_NAME=".lane-output.json"

usage() { echo "usage: bash .claude/lane-recovery.sh detect | checkpoint <id> [--dir <d>] [--note <t>] | assess <id> [--dir <d>]" >&2; exit 2; }
die5() { echo "lane-recovery: $1" >&2; exit 5; }

[ $# -ge 1 ] || usage
VERB="$1"; shift

# detect needs no jq; the JSON verbs do — without it there is no safe envelope, a
# loud stop (Rule 15). (No CLAUDE.md-survival floor here: a lane primitive that
# cannot read/write its checkpoint must report that, not paper over it — Rule 10.)
need_jq() { command -v jq >/dev/null 2>&1 || die5 "jq unavailable — cannot $1 a lane checkpoint"; }

# Parse the optional flags shared by checkpoint/assess. The first non-flag is the id.
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)  DIR="${2:-}"; shift 2 ;;
      --note) NOTE="${2:-}"; shift 2 ;;
      --) shift ;;
      -*) usage ;;
      *)  [ -z "$ID" ] && ID="$1" || usage; shift ;;
    esac
  done
  [ -n "$ID" ] || usage
}

case "$VERB" in
  detect)
    # The clean discriminator from [14.1]: a Task subagent carries
    # CLAUDE_CODE_CHILD_SESSION=1. A child has no SessionStart re-injection rung; the
    # main session does (the [14.4] hook). Emit a one-line, greppable verdict.
    if [ "${CLAUDE_CODE_CHILD_SESSION:-}" = "1" ]; then
      echo "child=1 reinjection=none note=lane/subagent — recover by re-spawn-from-disk"
    else
      echo "child=0 reinjection=session-start note=main session — [14.4] re-injection available"
    fi
    exit 0
    ;;

  checkpoint)
    parse_args "$@"
    need_jq checkpoint

    # git HEAD + a dirty-tree signal, captured from the worktree (deterministic). git
    # HEAD alone is the last COMMIT; a re-spawned subagent also needs to know there is
    # uncommitted work to read ([14.3] resume-sufficiency). A clean repo is 0; a
    # non-repo degrades to null (distinct states — Rule 15, never fabricated).
    GIT_HEAD=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)
    GIT_DIRTY=""
    if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
      GIT_DIRTY=$(git -C "$DIR" status --porcelain 2>/dev/null | grep -c .)
    fi
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    CHILD=0; [ "${CLAUDE_CODE_CHILD_SESSION:-}" = "1" ] && CHILD=1

    CKPT_JSON=$(jq -n \
      --arg now "$NOW" \
      --arg deliv "$ID" \
      --arg ghead "$GIT_HEAD" \
      --arg gdirty "$GIT_DIRTY" \
      --arg note "$NOTE" \
      --argjson child "$CHILD" \
      '{
        schema: "guv.lane-recovery/1",
        deliverable: (if $deliv=="" then null else $deliv end),
        checkpoint_at: (if $now=="" then null else $now end),
        git_head: (if $ghead=="" then null else $ghead end),
        git_dirty_paths: (if $gdirty=="" then null else ($gdirty|tonumber) end),
        note: (if $note=="" then null else $note end),
        child: $child
      }' 2>/dev/null)

    [ -n "$CKPT_JSON" ] || die5 "could not assemble the lane checkpoint envelope — nothing written"

    # Write at the worktree root, beside .lane-output.json. A write failure is a loud
    # NAMED stop with a non-zero exit, so the lane learns its checkpoint did not
    # persist and can fail loud in its own sidecar (Rule 10) — never silently dropped.
    OUT="$DIR/$CKPT_NAME"
    if ! { [ -d "$DIR" ] && printf '%s\n' "$CKPT_JSON" > "$OUT" 2>/dev/null; }; then
      die5 "cannot write lane checkpoint to $OUT — NOT written (the re-spawn cannot be seeded)"
    fi
    echo "lane=$ID checkpoint=$OUT git_head=${GIT_HEAD:-null} dirty=${GIT_DIRTY:-null}"
    exit 0
    ;;

  assess)
    parse_args "$@"
    need_jq assess
    OUTF="$DIR/$OUT_NAME"; CKF="$DIR/$CKPT_NAME"

    # (1) A FINISHED lane LANDS — proceed to the gate, no re-spawn. status=ok wins
    # over any leftover checkpoint (a completed lane is done regardless).
    STATUS=""
    if [ -f "$OUTF" ]; then STATUS=$(jq -r '.status // empty' "$OUTF" 2>/dev/null); fi
    if [ "$STATUS" = "ok" ]; then
      echo "recovery=land deliverable=$ID note=lane build complete — proceed to the gate"
      exit 0
    fi

    # (2) A self-checkpointed lane RE-SPAWNS — it hit its window and persisted a
    # checkpoint; the parent re-dispatches a FRESH subagent seeded from it (re-spawn,
    # not in-place continue). A checkpoint that is present but unparseable / wrong
    # schema is a loud NAMED stop — never a guessed verdict (Rule 15).
    if [ -f "$CKF" ]; then
      jq -e . "$CKF" >/dev/null 2>&1 || die5 "lane $ID checkpoint at $CKF is not valid JSON — cannot assess (no guessed verdict)"
      SC=$(jq -r '.schema // empty' "$CKF" 2>/dev/null)
      [ "$SC" = "$SCHEMA" ] || die5 "lane $ID checkpoint schema '$SC' != $SCHEMA — cannot assess (version skew)"
      N=$(jq -r '.note // "no note recorded"' "$CKF" 2>/dev/null)
      echo "recovery=respawn deliverable=$ID note=$N"
      exit 0
    fi

    # (3) A FAILED or SILENT lane is a loud STOP (designed path, Rule 15), never a
    # re-spawn and never a silent skip (Rule 10).
    if [ "$STATUS" = "failed" ]; then
      echo "recovery=fail deliverable=$ID reason=lane reported status=failed — loud stop, fix conversationally"
    else
      echo "recovery=fail deliverable=$ID reason=no lane output and no checkpoint — the lane returned nothing"
    fi
    exit 6
    ;;

  *) usage ;;
esac
