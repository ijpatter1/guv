#!/bin/bash
# .claude/status-line.sh
# Compose the one-line README status from resolve-ready.sh --json output. A text
# sibling of render-status.sh: both consume the resolver's JSON and ONLY that
# JSON (the A-001 one-parser decision — neither re-parses the tracker), one
# producing the HTML status view, this one the single line that lives between the
# README <!-- STATUS:START/END --> markers. Composing it deterministically is what
# lets the §3.3 render hooks refresh the README block without an agent
# hand-writing the line (which retires the status/handoff hand-invokes).
#
# The line is intentionally leaner than the old hand-composed one: the resolver's
# JSON carries the phase NUMBER and per-status counts but not the phase NAME or a
# session id, and reading those would mean re-parsing the tracker — which the
# one-parser rule forbids. Phase + completed/total is the deterministic core.
#
# Usage:
#   bash .claude/status-line.sh <status.json>     # the one-line status on stdout
#   bash .claude/resolve-ready.sh docs/PHASE_STATUS.md --json | bash .claude/status-line.sh -
#
# Exit 0 with the line on stdout; exit 2 on usage / missing input / missing jq;
# exit 5 if the input is not resolver JSON. "-" reads stdin.
set -u

usage() { echo "usage: status-line.sh <status.json|->" >&2; exit 2; }
[ $# -eq 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "status-line: jq not found" >&2; exit 2; }

SRC="$1"
if [ "$SRC" = "-" ]; then
  JSON="$(cat)"
else
  [ -f "$SRC" ] || { echo "status-line: no such file: $SRC" >&2; exit 2; }
  JSON="$(cat "$SRC")"
fi

# This is the one shape status-line consumes — fail loud, never compose a line
# off something that isn't the resolver's JSON.
printf '%s' "$JSON" | jq -e 'type=="object" and has("mode") and has("deliverables") and has("frontier")' \
  >/dev/null 2>&1 || { echo "status-line: input is not resolve-ready --json output" >&2; exit 5; }

printf '%s' "$JSON" | jq -r '
  (.deliverables | length) as $total
  | ([.deliverables[] | select(.status == "done")] | length) as $done
  | if .mode == "LEGACY" then
      "_Active (LEGACY tracker) · \($done)/\($total) items done_"
    elif (.phase == null) then
      "**All phases complete** · \($done)/\($total) deliverables"
    else
      "**Phase \(.phase)** · \($done)/\($total) deliverables"
    end
'
exit 0
