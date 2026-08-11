# Metering Log — NDJSON shape ([9.1], epoch declared at [32.4])

The metering log is the meter's **raw evidence**: append-only NDJSON, one line
per metering event, at `.claude/metering/metering.ndjson` in the control plane
(resolved relative to the project root the way every guv script resolves state).
One boundary writes to it — the **session boundary** ([9.1]): `.claude/meter.sh`
appends one `guv.meter.v1` line per session-close. (A retired second boundary
left `guv.meter.queue.v1` lines in old logs — see the tombstone at the end.)

This shape joins the tracker grammar, the manifest schema, and `status.json` as
**published contract surface**. The consumers are `budget-gate.sh` (burn at the
session boundaries) and `projection.sh` (the observed rate, and the [13.4]
bank/grade lineage). **The raw log stays raw** — no totals, rates, or cost-per-X
fields appear here; those are meaning, computed by the consumers. (The [9.5]
aggregate emitter retired at [32.4]: nothing consumed its document — its two
live duties, the burn sum and the rate, already lived in the two consumers.)

## Epoch — declared 2026-08-10 ([32.4])

The log carries an **epoch line** (`guv.meter.epoch.v1`); consumers read only
entries **after the last epoch line** (file order — append order is lineage
order) and **never compare across it**. Pre-epoch entries are historical raw
evidence: they stay as written, and no burn sum, rate, or ceiling comparison
mixes them with post-epoch entries. (Session **counts** are unit-free — a
legacy grade's post-bank denominator may span the line; token quantities never
do.) A log with **no** epoch line is one epoch
whole — the fresh-project case; a new project never needs the line.

- **Date:** 2026-08-10 (session-2026-08-10-003, deliverable [32.4]).
- **Unit:** `per_response` harvest (usage grouped by `requestId` — one API
  response counted once), summed as a **raw four-class token count**
  (`input + output + cache_read + cache_creation`, unweighted). Every setpoint
  in `budgets.*` is read in this same unit; the pre-epoch per-ceiling unit
  declarations (`harvest_basis`, `denomination` in the manifest) retired with
  the hazard machinery.
- **Coverage:** `main_session` — the **main session transcript only**.
  Subagent-fleet burn is **out of band** (it returns at [32.8] as a distinct
  `fleet` component beside main-session burn, never blended silently), and
  platform ceilings are out of scope — **a gate figure is never read as total
  spend**.

The epoch line's shape:

```json
{"schema":"guv.meter.epoch.v1","ts":"2026-08-10T00:00:00Z","harvest":"per_response","denomination":"raw_tokens","coverage":"main_session"}
```

Declaring a new epoch (a unit or coverage change) is a person's append of a new
line plus an update to this section — machinery never writes one. **Upgrading a
pre-[32.4] project with an existing log:** append an epoch line before trusting
any gate figure — without it the whole log is one epoch, so pre-dedupe (~2.5x
inflated) and fleet-inclusive history counts against your ceiling undisclosed;
and if the ceiling itself was sized in a pre-epoch unit (the retired
`harvest_basis`/`denomination` manifest declarations said so), re-derive it in
the epoch's unit — the gate no longer warns about either.

## Invariants

- **Append-only.** No code path ever rewrites, truncates, or in-place-edits the
  log. The only write primitive against it is `>>` (append). The suite
  grep-asserts this on the writer and across the `.claude` tree.
- **No agent I/O — every field is guv- or git-derived.** There is no flag to set
  token counts, dollars, the operation wall-clock, the suite runtime, or any
  value. Tokens are harvested from the runtime transcript; the op wall-clock is
  measured by the writer; the suite runtime is measured by the writer
  (`--run-suite`) or read from the guv-written artifact
  `.claude/metering/.last-suite-runtime`, never a CLI argument. "Measure
  exhaust, never steam."
- **Raw evidence only.** No derived/aggregate field appears.

## Session-boundary fields (`guv.meter.v1`)

One JSON object per line. Every field is present on every entry (degraded values
are explicit nulls, never omissions).

| field             | type            | source / meaning                                                                                 |
|-------------------|-----------------|--------------------------------------------------------------------------------------------------|
| `schema`          | string          | shape version — `guv.meter.v1`.                                                                   |
| `ts`              | string          | ISO-8601 UTC instant of the capture (`date -u`). guv-derived.                                     |
| `session`         | string          | session id, `session-YYYY-MM-DD-NNN`, derived from the newest `docs/sessions/session-*.md`.       |
| `session_derived` | bool            | `true` when `session` came from a real session artifact; `false` on the date-fallback degradation. |
| `runtime_session` | string \| null  | the Claude Code runtime session id (`CLAUDE_CODE_SESSION_ID`) — the transcript harvest key.       |
| `deliverable_ids` | array<string>   | the deliverable ID(s) this session served; `["session-scalar"]` when no single ID applies.        |
| `model`           | string \| null  | model id, harvested from the main transcript's last assistant message.                            |
| `tokens`          | object \| null  | token counts **by class** — `{input, output, cache_read, cache_creation}` — the **bounded per-session SLICE** ([13.6]): the main-transcript delta from the last same-`runtime_session` capture to now. `null` when the transcript is unreachable. |
| `transcript_tokens` | object \| null | the **raw cumulative high-water reading** by class at capture — what the NEXT slice differences against ([13.6]). Not a per-session figure; `slice_basis` names the unit. |
| `slice_basis`     | string \| null  | self-describes `tokens`' unit ([13.6], Rule 15): `per_deliverable` (a bounded delta against a prior same-`runtime_session` capture) · `since_process_start` (the first capture — the full reading IS the first slice) · `unbounded_cumulative` (a non-monotone degradation, OR a `harvest_basis`/`coverage` seam where the prior reading is a different unit or scope — disclosed and **excluded** from every burn sum and rate) · `null` when nothing was harvested. |
| `harvest_basis`   | string \| null  | how the reading was **harvested**: `per_response` (grouped by `requestId`, one response counted once); `null` on a degraded entry. Absent on entries written before the 2026-07-25 dedupe fix (see *History*); a differing prior refuses the delta. |
| `coverage`        | string \| null  | what the reading **spans** ([32.4]): `main_session` (the main transcript only — the epoch's coverage); `null` on a degraded entry. Absent on entries written before the narrowing (those summed main + subagent transcripts); a differing prior refuses the delta exactly as `harvest_basis` does. [32.8] widens this to a main+fleet split. |
| `compaction_cycles` | number \| null | count of real compaction events (`isCompactSummary == true`, `timestamp ≥` the prior capture) the slice spanned ([13.6]); powers balloon detection. |
| `dollars`         | null            | **always null** — token-only rung; pricing tables drift and the spec forbids a guessed conversion. |
| `spike_c_rung`    | string          | `"B"` when tokens were harvested, `"degraded"` when not.                                          |
| `perf`            | object          | `{op_wallclock_s, suite_runtime_s}` — both **measured by guv**, never agent values. `suite_runtime_s` comes from `--run-suite` or the `.last-suite-runtime` artifact; `null` when neither exists. |

## Harvest semantics (the kept [13.6] slice + the per-response dedupe)

- **Bounded slice.** A `CLAUDE_CODE_SESSION_ID` names a whole `claude` process;
  a guv session is a slice of it. `tokens` is the delta from the last
  same-`runtime_session` capture (per class); `transcript_tokens` preserves the
  cumulative high-water for the next delta. A negative class delta (non-monotone
  reading) degrades to `unbounded_cumulative`, disclosed, never a fabricated
  slice.
- **Per-response dedupe.** The runtime serializes one assistant response as N
  transcript lines carrying duplicate usage; the harvest groups by `requestId`
  and takes the per-class max before summing. A per-line sum over-counts ~2.5x
  (see *History*).
- **Seam guard.** A prior reading harvested under a different `harvest_basis`
  OR spanning a different `coverage` is a different accounting — the delta is
  refused, the entry discloses `unbounded_cumulative`, and a loud
  `VINTAGE/COVERAGE BREAK` line says so. Expect it once per `runtime_session`
  at each seam. Magnitude checks cannot catch a seam once the new cumulative
  outgrows the old one; only the recorded markers can.
- **Balloon detection — declared, never stopped.** A deliverable whose slice
  spanned more compaction cycles than its [13.2] sizing gets a loud `BALLOON:`
  line the handoff surfaces; the capture still exits 0 ([13.5] fuzzy
  semantics). No compaction signal, no explicitly sized deliverable, or a
  `since_process_start` slice → no declaration.
- **Designed degradation (Rule 15).** Transcript unreachable → the mechanical
  fields still write, `tokens: null`, `spike_c_rung: "degraded"`. The log
  existing never depends on harvestability.

## Example entry

```json
{"schema":"guv.meter.v1","ts":"2026-08-10T21:40:12Z","session":"session-2026-08-10-003","session_derived":true,"runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","deliverable_ids":["32.4"],"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"transcript_tokens":{"input":72804,"output":662186,"cache_read":104991852,"cache_creation":7563948},"slice_basis":"per_deliverable","harvest_basis":"per_response","coverage":"main_session","compaction_cycles":1,"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.041,"suite_runtime_s":786.572}}
```

## Wiring

The handoff skill invokes the writer at session-close (Step 6b), passing the
deliverable ID(s) the session served — or none, to record `session-scalar`.
Step 3 times the suite run and writes the measured seconds to
`.claude/metering/.last-suite-runtime` (a guv write, no agent number); Step 6b's
capture READS that artifact. Step 6c runs `budget-gate.sh exit` — the
burn-vs-ceiling comparison over this log's post-epoch entries.

## History — why the epoch exists (facts kept from the retired machinery)

Everything below describes **pre-epoch** entries and the machinery that used to
qualify them. It is kept because the record is what makes the next unit seam
recognizable; none of it applies to post-epoch entries.

- **Pre-dedupe inflation (~2.5x).** Entries written before 2026-07-25 summed
  usage once per transcript LINE, not per response — measured 2.31–2.88x
  all-class across the 18 reconstructed entries whose transcripts survived
  (weighted 2.53x; a single ~2.55x deflator recovers all 18 to ±13%). They were
  never backfilled: only 2 of 14 runtime_sessions still had transcripts, and a
  deflator applied to the rest would be an estimate wearing a measurement's
  field name inside an append-only record. `harvest_basis` marks the seam;
  absence of the field IS the pre-fix marker.
- **Coverage narrowing ([32.4]).** [13.1] had widened the harvest to the
  sibling subagent transcripts (main-only captured ~71% of a review-heavy
  session's cache_read; subagents added ~1.4x). That blended total was
  indistinguishable from main-session burn, so [32.4] narrowed coverage to the
  main transcript and made the scope self-describing; [32.8] re-adds fleet burn
  as a distinct component. Absence of `coverage` marks a pre-narrowing entry.
- **The denomination axis.** A ceiling chosen in cost-weighted tokens
  (base-input-equivalents: cache_read ×0.1, cache_creation ×2, output ×5) runs
  several times smaller than the raw four-class count — 3.9x, 6.0x and 6.8x on
  three windows of guv's own record — and the ratio moves with each session's
  output/cache mix, so no fixed divisor converts between them. The epoch pins
  raw four-class for burn and ceiling alike; re-denominating a ceiling means
  re-deriving it, never scaling it.
- **The 004 setpoint's history.** `budgets.initiative.tokens` was 4,741,208,137
  in the pre-fix unit (all 53 samples behind it inflated); re-denominated to
  1,000,000,000 on 2026-07-26, derived bottom-up from initiative 003's
  420,810,420 (closed at the 2026-07-10T12:49:12Z grade — itself pre-dedupe
  vintage). Later moves are the manifest's own git history — the commit is the
  provenance. The banked opening forecast of 004 stays in the pre-fix unit
  (the calibration record is append-only); its close-time grade will show a
  large favourable rate error that is entirely the unit change.
- **The retired hazard machinery.** `budget-gate.sh` used to scan burn vintages
  and the per-ceiling declarations and print HARVEST UNIT / SETPOINT
  DENOMINATION HAZARD banners with per-direction remedies; `projection.sh`
  carried a modeled occupancy×turns band (fitted to pre-dedupe evidence,
  disclosed as known-high) and blended it with observed rates. Both deleted at
  [32.4]: the epoch makes the comparisons they qualified either valid (post-
  epoch vs post-epoch) or refused (never across the line). The full texts are
  in git history at `4b3161d`'s ancestry.

---

## Tombstone — the queue boundary (`guv.meter.queue.v1`, [9.4])

`meter-queue.sh` wrote one `guv.meter.queue.v1` line per merge-queue landing.
Its invokers were deleted at [32.3] (the lane cluster) and the writer itself at
[32.4]. Lines of that shape in old logs are historical raw evidence — same
invariants, `deliverable_id`/`dispatch_outcome`/`footprint` instead of the
session fields, `perf.landing_wallclock_s` — documented in full in git history.
Do not build against the shape; no new line can be written.
