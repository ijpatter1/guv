# Metering Log — NDJSON shape ([9.1])

The metering log is the meter's **raw evidence**: one append-only NDJSON line per
session-close, written by `.claude/meter.sh`. It lives in the control plane at
`.claude/metering/metering.ndjson` (resolved relative to the project root the way
every harness script resolves state — never a hardcoded path).

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
- **No agent I/O — every field is harness- or git-derived.** There is no flag to
  set token counts, dollars, the operation wall-clock, the suite runtime, or any
  value. Tokens are harvested from the runtime transcript; the op wall-clock is
  measured by the writer; the suite runtime is measured by the writer (`--run-suite`)
  or read from the harness-written artifact `.claude/metering/.last-suite-runtime`,
  never a CLI argument; the timestamp and session id are derived. "Measure exhaust,
  never steam."
- **Raw evidence only.** No derived/aggregate field appears. Aggregation is the
  [9.5] emitter's job.

## Fields

One JSON object per line. Every field is present on every entry (degraded values
are explicit nulls, never omissions).

| field             | type            | source / meaning                                                                                 |
|-------------------|-----------------|--------------------------------------------------------------------------------------------------|
| `schema`          | string          | shape version — `guv.meter.v1`. Bumped if the shape changes (grammar-version discipline).         |
| `ts`              | string          | ISO-8601 UTC instant of the capture (`date -u`). Harness-derived.                                |
| `session`         | string          | harness session id, `session-YYYY-MM-DD-NNN`, derived from the newest `docs/sessions/session-*.md`. |
| `session_derived` | bool            | `true` when `session` came from a real session artifact; `false` on the date-fallback degradation. |
| `runtime_session` | string \| null  | the Claude Code runtime session id (`CLAUDE_CODE_SESSION_ID`) — the transcript harvest key; null if absent. |
| `deliverable_ids` | array<string>   | the deliverable ID(s) this session served, e.g. `["9.1"]` or `["9.1","9.4"]`; `["session-scalar"]` when no single ID applies. |
| `model`           | string \| null  | model identifier, harvested from the transcript's last assistant message; null when unharvestable.  |
| `tokens`          | object \| null  | token counts **by class** — `{input, output, cache_read, cache_creation}` — summed from the transcript's per-message `usage` objects. `null` when the transcript is unreachable. |
| `dollars`         | null            | **always null** on the current rung — token-only, no guessed price table (pricing tables drift; the spec forbids a guessed conversion). |
| `spike_c_rung`    | string          | the harvest rung this entry achieved (see below): `"B"` when tokens were harvested, `"degraded"` when not. |
| `perf`            | object          | mechanical performance fields the boundary affords (see below).                                  |
| `perf.op_wallclock_s` | number      | wall-clock seconds of the writer's own **deterministic session-close operations** — harvest + assemble + append. The genuinely mechanical perf field, **measured by the script**, never an agent value. |
| `perf.suite_runtime_s` | number \| null | test-suite wall-clock — **mechanical only**, never an agent value. Either the writer times the suite itself (`--run-suite`), or it READS the harness artifact `.claude/metering/.last-suite-runtime` (a number the session-close path writes mechanically when it runs the suite in handoff Step 3). No CLI flag or agent input can set it. `null` when neither source is present (artifact absent/unreadable/non-numeric — the designed degradation). Never an agent estimate. |

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

`.claude/commands/handoff.md` invokes the writer at session-close (after the
handoff artifact is generated and the suite has run), passing the deliverable
ID(s) the session served — or none, to record `session-scalar`. That is the only
production caller; the writer is otherwise standalone and testable.

The suite runtime is wired mechanically: handoff **Step 3** times its existing
suite run and writes the measured seconds to `.claude/metering/.last-suite-runtime`
(a harness write, no agent number), and **Step 6b**'s `meter.sh capture` READS
that artifact to populate `perf.suite_runtime_s`. Step 6b reports no numbers to
the writer; the artifact, like every other field, is harness-measured or null.
