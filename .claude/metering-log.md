# Metering Log — NDJSON shape ([9.1], [9.4])

The metering log is the meter's **raw evidence**: append-only NDJSON, one line per
metering event. It lives in the control plane at `.claude/metering/metering.ndjson`
(resolved relative to the project root the way every guv script resolves state —
never a hardcoded path). Two boundaries write to the SAME log, each a distinct
sibling shape:

- the **session boundary** ([9.1]) — `.claude/meter.sh` writes one
  `guv.meter.v1` line per session-close.
- the **queue boundary** ([9.4]) — `.claude/meter-queue.sh` writes one
  `guv.meter.queue.v1` line per merge-queue landing. Split off the session boundary
  so metering as a whole never serializes behind the merge queue: the queue lands
  one lane at a time and emits its own line at the moment it lands.

The two shapes are distinguished by their `schema` field so the downstream emitter
can read one log and tell a landing entry from a session entry.

This shape joins the tracker grammar, the manifest schema, and `status.json` as
**published contract surface**. The downstream consumer is the [9.5] cost-and-
performance emitter, which aggregates this log; every other reader reads the
emitter, never the raw log. **The raw log stays raw** — no totals, rates, or
cost-per-X fields appear here (those are *meaning*, computed downstream).

## Invariants

- **Append-only.** No code path ever rewrites, truncates, or in-place-edits the
  log. The only write primitive against it is `>>` (append). A second capture
  appends a line and leaves every prior line byte-identical. The suite
  grep-asserts this on the writer and across the `.claude` tree.
- **No agent I/O — every field is guv- or git-derived.** There is no flag to
  set token counts, dollars, the operation wall-clock, the suite runtime, or any
  value. Tokens are harvested from the runtime transcript; the op wall-clock is
  measured by the writer; the suite runtime is measured by the writer (`--run-suite`)
  or read from the guv-written artifact `.claude/metering/.last-suite-runtime`,
  never a CLI argument; the timestamp and session id are derived. "Measure exhaust,
  never steam."
- **Raw evidence only.** No derived/aggregate field appears. Aggregation is the
  [9.5] emitter's job.

## Session-boundary fields (`guv.meter.v1`)

One JSON object per line. Every field is present on every entry (degraded values
are explicit nulls, never omissions).

| field             | type            | source / meaning                                                                                 |
|-------------------|-----------------|--------------------------------------------------------------------------------------------------|
| `schema`          | string          | shape version — `guv.meter.v1`. Bumped if the shape changes (grammar-version discipline).         |
| `ts`              | string          | ISO-8601 UTC instant of the capture (`date -u`). guv-derived.                                |
| `session`         | string          | session id, `session-YYYY-MM-DD-NNN`, derived from the newest `docs/sessions/session-*.md`. |
| `session_derived` | bool            | `true` when `session` came from a real session artifact; `false` on the date-fallback degradation. |
| `runtime_session` | string \| null  | the Claude Code runtime session id (`CLAUDE_CODE_SESSION_ID`) — the transcript harvest key; null if absent. |
| `deliverable_ids` | array<string>   | the deliverable ID(s) this session served, e.g. `["9.1"]` or `["9.1","9.4"]`; `["session-scalar"]` when no single ID applies. |
| `model`           | string \| null  | model identifier, harvested from the transcript's last assistant message; null when unharvestable.  |
| `tokens`          | object \| null  | token counts **by class** — `{input, output, cache_read, cache_creation}` — summed from the per-message `usage` objects across the main transcript **and the subagent transcripts the session spawned** (see [13.1] below). `null` when the transcript is unreachable. |
| `dollars`         | null            | **always null** on the current rung — token-only, no guessed price table (pricing tables drift; the spec forbids a guessed conversion). |
| `spike_c_rung`    | string          | the harvest rung this entry achieved (see below): `"B"` when tokens were harvested, `"degraded"` when not. |
| `perf`            | object          | mechanical performance fields the boundary affords (see below).                                  |
| `perf.op_wallclock_s` | number      | wall-clock seconds of the writer's own **deterministic session-close operations** — harvest + assemble + append. The genuinely mechanical perf field, **measured by the script**, never an agent value. |
| `perf.suite_runtime_s` | number \| null | test-suite wall-clock — **mechanical only**, never an agent value. Either the writer times the suite itself (`--run-suite`), or it READS the guv artifact `.claude/metering/.last-suite-runtime` (a number the session-close path writes mechanically when it runs the suite in handoff Step 3). No CLI flag or agent input can set it. `null` when neither source is present (artifact absent/unreadable/non-numeric — the designed degradation). Never an agent estimate. |

## Spike C — harvestability (the rung taken)

Spike C asked whether per-session usage/cost is **mechanically** harvestable
without agent I/O. Probe result: **yes for tokens, no for dollars.**

- The Claude Code runtime writes a per-session transcript at
  `~/.claude/projects/<cwd-slug>/<CLAUDE_CODE_SESSION_ID>.jsonl`, where
  `<cwd-slug>` is the absolute working directory with `/` replaced by `-`. Each
  assistant message carries a `usage` object with `input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens`.
  The writer sums these by class — **rung B**: session-scalar token attribution.
- **Dollars are not mechanically present** (no price field on the transcript;
  pricing tables drift). Per Spike C's ladder, the dollar axis sits at **rung C**
  — token-only, `dollars: null`, no guessed conversion.

### [13.1] — subagent-token completeness (the eval/fix spike)

**Finding: the harvested token total INCLUDES subagent-reviewer burn.** The
subagents a session spawns — the `evaluator`/`reviewer` of the eval/fix loop, lane
builders, workflow agents — do **not** write into the main `<session>.jsonl`. Each
writes its own transcript under the **sibling `<session>/` directory tree**
(`<session>/subagents/agent-*.jsonl`, `<session>/workflows/…`), carrying the
identical per-message `usage` object. A harvest that read only the main transcript
would systematically **undercount** real burn — and the missing burn is precisely
the eval/fix review loop, the dominant turn-variance the projection ([13.3]) must
predict. Measured on a review-heavy session, the main transcript alone captured
only **~71%** of true `cache_read` burn; the subagent transcripts added a further
**~1.4×**.

So the harvest sums the main transcript **plus every `*.jsonl` under the sibling
`<session>/` tree** (`.meta.json` sidecars excluded; no sidechain double-count —
this runtime externalizes subagents to their own files rather than inlining them).
This is a **captured** boundary, not a disclosed exclusion: the meter sees the
subagent burn. The **`model`** field, by contrast, is read from the **main
transcript only** — it names the session's model, never a subagent's. The same
harvest is used by both the session meter (`meter.sh`) and the queue-boundary meter
(`meter-queue.sh`), kept in lockstep. *(Research-preview surface — re-verify the
sibling-tree layout if the runtime's transcript shape shifts; the `find`-recursive
harvest also picks up `workflows/` transcripts as they appear.)*

So: attribution rung **B**, denomination **C** (token-only). The fields the
attribution affords — `tokens` by class and `model` — are harvested; `dollars`
stays null by design.

**Designed degradation (Rule 15).** The transcript is a research-preview surface.
If `CLAUDE_CODE_SESSION_ID` is unset, the file is absent, or jq cannot sum it,
the writer takes the documented fallback rung: it emits the fields that *are*
mechanical (`ts`, `session`, `deliverable_ids`, `model` if any, and the
**always-present** `perf.op_wallclock_s`), sets `tokens: null`, and marks
`spike_c_rung: "degraded"`. The log existing never depends on Spike C — a "no"
degrades the meter's resolution, never blocks the line.

## Example entry

```json
{"schema":"guv.meter.v1","ts":"2026-06-13T21:40:12Z","session":"session-2026-06-13-004","session_derived":true,"runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","deliverable_ids":["9.1"],"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.041,"suite_runtime_s":1.232}}
```

## Wiring

`.claude/skills/handoff/SKILL.md` invokes the writer at session-close (after the
handoff artifact is generated and the suite has run), passing the deliverable
ID(s) the session served — or none, to record `session-scalar`. That is the only
production caller; the writer is otherwise standalone and testable.

The suite runtime is wired mechanically: handoff **Step 3** times its existing
suite run and writes the measured seconds to `.claude/metering/.last-suite-runtime`
(a guv write, no agent number), and **Step 6b**'s `meter.sh capture` READS
that artifact to populate `perf.suite_runtime_s`. Step 6b reports no numbers to
the writer; the artifact, like every other field, is guv-measured or null.

---

# Queue-boundary entry (`guv.meter.queue.v1`, [9.4])

A merge-queue **landing** appends one `guv.meter.queue.v1` line to the same log,
written by `.claude/meter-queue.sh`. It is the **per-deliverable** sibling of the
session-scalar entry: where the session boundary records what a *session* spent,
the queue boundary records what *landing one deliverable* cost — emitted at the
moment the queue lands (or refuses) it, so metering never waits for session-close.

The same three invariants hold (append-only; no agent I/O for cost — tokens are
harvested exactly as the session meter harvests them, dollars stay null; raw
evidence only). The footprint and the landing wall-clock are **flags**, but only
because they are **mechanical inputs the queue measured upstream**: the diff
footprint is the number the GATE already computed (`merge-queue.sh footprint`,
surfaced at `precheck`/`gate-input`) and is **reused verbatim, never recomputed**;
the wall-clock is what the queue measured while it landed the lane. tokens and
dollars are never settable by a caller.

## Queue-boundary fields

| field              | type            | source / meaning                                                                                       |
|--------------------|-----------------|--------------------------------------------------------------------------------------------------------|
| `schema`           | string          | `guv.meter.queue.v1` — the queue-boundary shape, distinct from `guv.meter.v1`.                          |
| `ts`               | string          | ISO-8601 UTC instant of the landing (`date -u`). guv-derived.                                           |
| `deliverable_id`   | string          | the landed (or refused) deliverable ID this entry is attributed to. ONE per entry — the queue lands one lane at a time. |
| `dispatch_outcome` | string          | the outcome the queue produced: `landed` · `harvest-refused` · `conflict-routed`. An unknown value is a loud usage error. |
| `runtime_session`  | string \| null  | the Claude Code runtime session id (`CLAUDE_CODE_SESSION_ID`) — the transcript harvest key; null if absent. |
| `footprint`        | object          | the diff footprint the GATE computed — `{files, insertions, deletions}`. **Reused, not recomputed.**    |
| `model`            | string \| null  | model id, harvested from the transcript's last assistant message; null when unharvestable.              |
| `tokens`           | object \| null  | token counts by class — `{input, output, cache_read, cache_creation}` — harvested from the transcript **and the session's subagent transcripts**, exactly as the session meter ([13.1]); `null` when unreachable (same Spike C rung B). |
| `dollars`          | null            | **always null** — token-only rung, no guessed price table.                                              |
| `spike_c_rung`     | string          | `"B"` when tokens were harvested, `"degraded"` when not.                                                |
| `perf`             | object          | mechanical performance fields the boundary affords.                                                     |
| `perf.landing_wallclock_s` | number  | the landing's wall-clock seconds, **measured by the queue** while it landed the lane — never an agent value. |

## Subcommands

- `capture …` — **appends** the entry to the log. A real landing is owed a log line.
- `emit …` — builds the **same** entry and **prints** it to stdout **without
  appending**. The [7.5] failure report embeds this as a refused lane's **burn
  profile** (diagnostic input to the retry). A refused lane never landed, so no log
  line is owed — `emit` keeps the report's burn profile out of the append-only log.

## Wiring

The merge-queue land path ([7.4]) writes a `capture` entry per landing, passing the
footprint it already computed. The lane-dispatch failure path ([7.5],
`lane-dispatch.sh capture_report`) embeds an `emit` entry — attributed to the
refused lane with `dispatch_outcome: harvest-refused` — as the **burn profile** in
the durable failure report, so a retry carries the cost-and-performance evidence
of the rejected attempt.

## Example entry

```json
{"schema":"guv.meter.queue.v1","ts":"2026-06-14T18:22:05Z","deliverable_id":"9.4","dispatch_outcome":"landed","runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","footprint":{"files":3,"insertions":42,"deletions":7},"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"dollars":null,"spike_c_rung":"B","perf":{"landing_wallclock_s":1.25}}
```
