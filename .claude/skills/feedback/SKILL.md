---
name: feedback
description: "Record harness friction — broken commands, inapplicable settings, doc drift, manifest gaps, misfiring hooks — to the project feedback log, and list/triage open entries. Use whenever a harness command/skill/hook/setting/doc doesn't fit the task at hand, when the user reports such friction, or at session handoff. Agent-callable mid-session and user-invocable."
user-invocable: true
---

# Feedback — Harness Friction Capture

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
| `artifact`   |     | The implicated file+line or command, e.g. `.claude/rules/guv-verification.md:7` or `/phase` (omit if not file-specific)                                                                                                                                                                                                                                      |
| `summary`\*  | ✓   | One line: what didn't fit                                                                                                                                                                                                                                                                                                                                    |
| `detail`     |     | Optional longer context — repro, what you expected, what you did instead                                                                                                                                                                                                                                                                                     |
| `severity`\* | ✓   | `blocker` · `major` · `minor`                                                                                                                                                                                                                                                                                                                                |
| `routing`\*  | ✓   | `upstream` (a core bug — fix in the template) · `local` (a this-project misfit — belongs in a local adaptation) · `unsure`                                                                                                                                                                                                                                   |
| `status`\*   | ✓   | `open` on creation. Terminal states, set only by triage: `resolved` (fixed before any release existed), `wontfix` (deliberately not acting), `graduated` (the fix reached this consumer by its delivery mechanism — a release, a `--sync`, or a landed local adaptation; see "Closing the loop") — the full lifecycle is in "Closing the loop". |

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
`ts`, which can collide), set a terminal status (`resolved`, `wontfix`, or `graduated`),
and — when graduating — append a provenance note to `detail` naming **what** resolved it,
so the close is auditable. `NOTE` is optional: leave it `""` for a bare status flip (e.g.
`wontfix`); supply it when graduating (this is the form `/handoff`'s drain step uses):

```bash
ID="2026-06-10T12:34:56Z-1234"; NEW="graduated"
NOTE="GRADUATED $(date -u +%Y-%m-%d) (session-…): resolved by <deliverable or commit>"   # "" to skip
f=.claude/feedback/feedback.ndjson
tmp=$(mktemp) && jq -c --arg id "$ID" --arg s "$NEW" --arg note "$NOTE" \
  'if .id==$id then .status=$s | (if $note=="" then . else .detail=(.detail + " | " + $note) end) else . end' \
  "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
```

## Mode 3 — Submit (drain `upstream` entries to the source tracker)

`submit` mode replaces the manual copy-paste a consumer does today: it drains the
open `routing: upstream` entries into the guv **source** repo as issues. For each
open upstream entry that has **no upstream link yet** it drafts an issue (title +
body), emits the exact `gh issue create` command — **with the drafted body inline as
a copy-pasteable heredoc** — for **you** to run, and writes a draft marker back onto
the entry so a re-run is a no-op — deduped by entry `id`. Non-upstream,
already-linked, and non-open entries are skipped, untouched.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/feedback-submit.sh" submit            # draft + write back the markers
bash "${CLAUDE_SKILL_DIR}/scripts/feedback-submit.sh" submit --dry-run  # list what would be filed; write nothing
```

What it is and isn't:

- **Issue filing is user-gated** (see "Closing the loop" below) — the permission
  classifier denies an agent's `gh issue create` *as an enforced convention* (it is
  the project's user-gated contract, not a hook that intercepts the call). So
  `submit` **never files**: it builds the draft/dedupe/writeback machinery and prints
  the complete `gh issue create … --body-file - <<'GUV-FEEDBACK-BODY' … ` block —
  body and all — for you to run as one copy-paste. You file; the agent drafts.
- **Close the loop after you file — paste the real URL back.** The draft marker
  (`DRAFTED-<id>`) means "drafted, awaiting filing", *not* "filed". After you run the
  emitted block and `gh` prints the new issue URL, **paste that URL into the entry's
  `detail`** (e.g. append ` | Issue: https://github.com/<owner>/<repo>/issues/N`).
  That is the documented end-state the acceptance bar names — the entry now carries
  the *real* upstream link, and `submit` keeps skipping it on the right basis (the
  dedupe matches the live issue URL too, not only the draft marker). An entry that was
  drafted but **never filed** still reads `DRAFTED-<id>` with no issue URL, so you can
  see at a glance which drafts are still owed a filing.
- **Idempotent.** Re-running drafts nothing for entries already linked (a real issue
  URL in `detail`) or already drafted (the `DRAFTED-<id>` marker), matched by `id` —
  a second run is a no-op.
- **Degrades loudly.** The tracker reachability is probed first (a single `gh repo
  view` against `roots.code`'s repo); if it's unreachable the run exits non-zero
  with a message and writes **nothing** — no entry is dropped silently (Rule 15).
- **`--dry-run`** lists the drainable entries and their drafts without touching the
  log; it still probes the tracker, so a dry run can't claim success offline.

## Closing the loop

The drain is live: the distribution channel is the versioned guv plugin, and entries
close through its release flow (maintainer-side mechanics — see the maintainer note at
the end of this section; a consumer fork that deleted `maintainers/` needs none of it).

- **`upstream`** entries → an issue or PR against the guv repo, citing the entry
  id. The entry stays `open` while the fix is in flight and flips to `graduated`
  **on the release that ships the fix** — the release checklist's drain step does
  the flip and closes the issue naming the release. Use `resolved` only for friction
  fixed before any release existed (nothing to graduate on). **Issue filing is
  user-gated:** the permission classifier denies an agent's `gh issue create` (and
  the issue close) as an outward publish while allowing `gh pr create` — so the agent
  **drafts** the issue (and records its triage as an annotation on the entry) and the
  **user files** it. The PR half is agent-executable; the issue half is not.
- **`local`** entries → a this-project adaptation, not an upstream fix: an unprefixed
  rules file, a project-owned skill or hook, a manifest tweak. They never enter the
  release flow — when the adaptation lands, mark the entry `graduated`; if the
  friction isn't worth adapting around, `wontfix`.
- **`unsure`** → review and reclassify at triage; routing decides which drain applies.

**Dogfooding / `--sync` consumers.** A control plane that *develops* the harness
consumes it via `setup-control-plane.sh --sync` from the code repo, not via versioned
plugin releases — so an `upstream` fix reaches it the moment the fix lands in the
harness **source** and is synced in, with no release event to graduate on. For such a
consumer the entry **graduates when its fix lands in source and reaches the plane via
`--sync`**, the triage note naming the resolving deliverable or commit. This is the
developer-side close trigger, distinct from the external-consumer release drain above:
the general rule is **graduate on the landing event by which this consumer actually
receives the fix** — a plugin release for a release consumer, a `--sync` (or a merge to
the default branch) for a developer one — not a release in every case. Without it, fixes
that ship the way the dogfooding control plane actually consumes the harness never close,
and the log rots. `/handoff` Step 10 runs this drain every session. (Maintainers: the
release-side mechanics and the no-release-vehicle path are in `maintainers/RELEASING.md`.)

`/handoff` **drains** open entries at session end — Step 10 proposes graduating the
ones the session resolved (the close paths above), not merely counting them — and
`/status` shows the open count, so the pile stays visible rather than forgotten. Triage
periodically; mark entries `graduated`/`resolved`/`wontfix` rather than deleting them,
so the history of what bit and what was done stays intact.
