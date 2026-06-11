---
name: log-feedback
description: "Record harness friction — broken commands, inapplicable settings, doc drift, manifest gaps, misfiring hooks — to the project feedback log, and list/triage open entries. Use whenever a harness command/skill/hook/setting/doc doesn't fit the task at hand, when the user reports such friction, or at session handoff. Agent-callable mid-session and user-invocable."
user-invocable: true
---

# Log Feedback — Harness Friction Capture

Capture friction with the **harness itself** so it can be triaged later into upstream
fixes versus local adaptations. This is the evidence base for improving the harness.

**It is data, not behavior.** Logging an entry changes nothing about how the session
runs — it is an append-only record. So log freely and early; there is no cost.

**What belongs here vs. not:**

- **Here:** anything about the _harness_ that didn't fit — a command step that errored,
  a setting that didn't apply, a manifest field that couldn't express your project, a
  doc that described something that isn't true, a hook that misfired, awkward ergonomics.
- **Not here — project code bugs** → route through `/task` (they're about the product,
  not the harness).
- **Not here — per-agent learning** (evaluator/reviewer observations) → that's
  `.claude/agent-memory/`, a different artifact with a different lifecycle.

## Where it lives

`.claude/feedback/feedback.ndjson` — one JSON object per line (NDJSON), so concurrent
sessions append without merge conflicts and the log is `jq`-queryable. This file is
**consumer-owned**: commit it (it's shared team knowledge), and note that a harness
update never touches it — it sits outside the upstream-owned core.

## Input

$ARGUMENTS

A short description of the friction.

- **Agent invoking mid-session:** fill the fields from what just happened — don't
  interrupt the user for them.
- **Human invoking with no/short input:** don't dump the whole field table on them. Ask
  in order, inferring the rest: (1) what didn't fit (→ `summary`), (2) which command/file
  (→ `artifact`, optional), (3) blocker / major / minor (→ `severity`), (4) is this a core
  bug or a this-project misfit (→ `routing`: upstream / local / unsure). Derive `id`,
  `ts`, `session`, `category`, `status` yourself.

## Mode 1 — Log an entry (default)

Fill these fields (\* = required):

| Field        | Req | Values / meaning                                                                                                                                                                                                                                                                                                                                             |
| ------------ | --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `id`\*       | ✓   | Auto-generated unique key — `${ts}-${RANDOM}${RANDOM}`. The **stable handle for triage** (`ts` alone collides at second resolution when several entries land in one session; the doubled `$RANDOM` makes a same-second collision ~1-in-a-billion).                                                                                                           |
| `ts`\*       | ✓   | ISO-8601 UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)                                                                                                                                                                                                                                                                                                       |
| `session`    |     | Latest `docs/sessions/` handoff name, or `n/a`                                                                                                                                                                                                                                                                                                               |
| `category`\* | ✓   | `broken-command` · `inapplicable-setting` · `doc-drift` · `manifest-gap` · `hook-misfire` · `friction` · `other`                                                                                                                                                                                                                                             |
| `artifact`   |     | The implicated file+line or command, e.g. `.claude/rules/guv-verification.md:7` or `/start-phase` (omit if not file-specific)                                                                                                                                                                                                                                      |
| `summary`\*  | ✓   | One line: what didn't fit                                                                                                                                                                                                                                                                                                                                    |
| `detail`     |     | Optional longer context — repro, what you expected, what you did instead                                                                                                                                                                                                                                                                                     |
| `severity`\* | ✓   | `blocker` · `major` · `minor`                                                                                                                                                                                                                                                                                                                                |
| `routing`\*  | ✓   | `upstream` (a core bug — fix in the template) · `local` (a this-project misfit — belongs in a local adaptation) · `unsure`                                                                                                                                                                                                                                   |
| `status`\*   | ✓   | `open` on creation. Terminal states, set only by triage: `resolved` (the friction is fixed), `wontfix` (deliberately not acting), `graduated` (it became an upstream fix or a local adaptation). Until Half B / a distribution channel exists, the realistic terminal action is `wontfix` or holding `open` as a tracked candidate — see "Closing the loop". |

Append the entry (substitute the `--arg` values; this creates the dir/file on first use):

```bash
mkdir -p .claude/feedback
SESSION=$(ls -t docs/sessions/session-*.md 2>/dev/null | head -1 | xargs -r basename | sed 's/\.md$//')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn \
  --arg id "${TS}-${RANDOM}${RANDOM}" \
  --arg ts "$TS" \
  --arg session "${SESSION:-n/a}" \
  --arg category "friction" \
  --arg artifact ".claude/rules/guv-verification.md:7" \
  --arg summary "one line: what didn't fit" \
  --arg detail "optional longer context" \
  --arg severity "minor" \
  --arg routing "upstream" \
  '{id:$id, ts:$ts, session:$session, category:$category, artifact:$artifact,
    summary:$summary, detail:$detail, severity:$severity, routing:$routing, status:"open"}' \
  >> .claude/feedback/feedback.ndjson
```

Rules:

- One entry per distinct issue. Don't batch unrelated friction into one line.
- Keep `summary` to a single line; put repro/context in `detail`.
- Choose `routing` honestly — `unsure` is a valid answer, not a cop-out. The triage step
  reclassifies later.
- Confirm the append succeeded by echoing the last line: `tail -1 .claude/feedback/feedback.ndjson | jq .`

## Mode 2 — List / triage

List open entries as a readable table (id · severity · routing · summary) — scan this to
pick an `id` to triage, rather than eyeballing raw JSON. The tab-separated jq output is
the portable core; pipe through `column` to align it _if that tool is installed_ (it may
not be in a slim container):

```bash
jq -r 'select(.status=="open") | "\(.id)\t\(.severity)\t\(.routing)\t\(.summary)"' \
  .claude/feedback/feedback.ndjson | { column -t -s "$(printf '\t')" 2>/dev/null || cat; }
```

Raw open entries (full fields), or show one by id:

```bash
jq -c 'select(.status=="open")' .claude/feedback/feedback.ndjson
jq -c --arg id "<id>" 'select(.id==$id)' .claude/feedback/feedback.ndjson
```

Count open (used by `/status` and `/handoff`). Guard the file's existence first — a
missing slurp file makes `jq -s` both print `0` _and_ exit non-zero, so a `|| echo 0`
fallback double-counts:

```bash
f=.claude/feedback/feedback.ndjson
[ -f "$f" ] && jq -s '[.[] | select(.status=="open")] | length' "$f" || echo 0
```

Group by routing (what to send upstream vs. adapt locally):

```bash
jq -s 'group_by(.routing) | map({routing: .[0].routing, open: [.[]|select(.status=="open")]|length})' .claude/feedback/feedback.ndjson
```

Triage an entry — NDJSON is rewritten whole (it's small). Match on the unique `id` (not
`ts`, which can collide) and set a terminal status (`resolved`, `wontfix`, or `graduated`
once it has been fixed upstream / turned into a local adaptation):

```bash
ID="2026-06-10T12:34:56Z-1234"; NEW="resolved"; f=.claude/feedback/feedback.ndjson
tmp=$(mktemp) && jq -c --arg id "$ID" --arg s "$NEW" 'if .id==$id then .status=$s else . end' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
```

## Closing the loop

**Honest scope:** this is "Half A" — capture. The two drains that would let an entry
truly _close_ are not built yet:

- **`upstream`** entries → issues / PRs against the harness core — _once a
  distribution/versioning channel exists_ (see `DISTRIBUTION_OPTIONS.md`).
- **`local`** entries → a local overlay adaptation — _deferred "Half B" work_.
- **`unsure`** → review and reclassify.

So today the log is a **curated evidence pile, not a worklist that drains.** Triage means
_reclassifying_ (`open` → `wontfix`, or holding `open` as a tracked candidate); the
`resolved`/`graduated` terminal states only become real once those drains land. That's
fine and intended — the value of Half A is that the evidence is captured, structured, and
pre-routed, so when a distribution channel is chosen the backlog is ready to act on. Don't
over-claim closure before then. `/status` and `/handoff` surface the open count so the
pile stays visible rather than forgotten.

`/handoff` surfaces open entries at session end; `/status` shows the open count. Triage
periodically; mark entries `graduated`/`resolved`/`wontfix` rather than deleting them, so
the history of what bit and what was done stays intact.
