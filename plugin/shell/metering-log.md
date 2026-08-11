# Metering Log — NDJSON shape ([9.1]; epoch declared at [32.4], widened at [32.8])

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

## Epoch — current: declared 2026-08-11 ([32.8])

The log carries an **epoch line** (`guv.meter.epoch.v1`); consumers read only
entries **after the last epoch line** (file order — append order is lineage
order) and **never compare across it**. Pre-epoch entries are historical raw
evidence: they stay as written, and no burn sum, rate, or ceiling comparison
mixes them with post-epoch entries. (Session **counts** are unit-free — a
legacy grade's post-bank denominator may span the line; token quantities never
do.) A log with **no** epoch line is one epoch
whole — the fresh-project case; a new project never needs the line.

An epoch declares **three axes**, and every one of them qualifies what a burn
figure means: the **unit** (how a token was counted), the **coverage** (what the
reading spans), and the **window** (which entries count — only those after the
line, so declaring an epoch mid-initiative resets the burn-vs-ceiling
comparison; the tokens before the line leave it, undeleted but no longer
compared).

- **Date:** 2026-08-11 local (deliverable [32.8]; the machine line's `ts` is
  the UTC instant of the ratified append — the declared date and the line's
  `ts` may differ across a midnight, and the line is the record).
- **Unit:** `per_response` harvest (usage grouped by `requestId` — one API
  response counted once), summed as a **raw four-class token count**
  (`input + output + cache_read + cache_creation`, unweighted). Every setpoint
  in `budgets.*` is read in this same unit; the pre-epoch per-ceiling unit
  declarations (`harvest_basis`, `denomination` in the manifest) retired with
  the hazard machinery. Unchanged from the [32.4] epoch.
- **Coverage:** `main_plus_fleet` — the main session transcript summed into
  `tokens` **plus** the session's subagent transcripts summed into `fleet`, as
  a **split**: two components, never blended into one figure. Burn sums read
  main + fleet, and select only post-epoch samples of THIS declared coverage —
  a sample of another scope inside the window (the seam before a ratified
  append, or a stray downgrade) is excluded, because an average across scopes
  is not a number. A disclosed `fleet: null` contributes nothing, so that
  entry's burn is a floor (the gate notes the count on its comparison line).
  Platform ceilings stay out of scope — **a gate figure is never read as
  spend against the subscription limit**.

The epoch line's shape (the `ts` below is a placeholder — the live line in the
log carries the append's real instant):

```json
{"schema":"guv.meter.epoch.v1","ts":"YYYY-MM-DDTHH:MM:SSZ","harvest":"per_response","denomination":"raw_tokens","coverage":"main_plus_fleet"}
```

Declaring a new epoch (a unit or coverage change) is a person's append of a new
line plus an update to this section — machinery never writes one.

**Prior epochs:**

- **2026-08-10 ([32.4])** — declared 2026-08-10 local; its machine line's `ts`
  reads `2026-08-11T01:02:01Z`, the UTC instant of the same local evening's
  append. Same unit as above; coverage `main_session` (the main transcript
  only — subagent-fleet burn was out of band between [32.4] and [32.8]).

**Upgrading a project with an existing log:** append an epoch line before
trusting any gate figure, and weigh all **three axes**, not just the unit —
without the line the whole log is one epoch, so pre-dedupe (~2.5x inflated)
history counts against your ceiling undisclosed (the **unit** axis); a ceiling
derived from fleet-inclusive or blended samples gates main+fleet burn
correctly only under a `main_plus_fleet` epoch — under a `main_session` one it
under-gates (~1.4x on review-heavy sessions, the [13.1] measurement; the
**coverage** axis); and the append itself resets the burn **window**
mid-initiative, so the gate reads 0% the moment the line lands — a reset, not
a refund, and worth recording as a deliberate call so the next reader knows it
was one. If the ceiling was sized in a pre-epoch unit or scope, re-derive it
in the epoch's — the gate no longer warns about any of this.

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
| `fleet`           | object \| null  | subagent-fleet burn by class ([32.8]) — the **distinct component** beside `tokens`, never blended into it: the bounded slice of the sibling `<session>/` transcript tree, under the same window and unit as `tokens`. `{0,0,0,0}` is a **measured zero** (no subagents spawned); `null` is the **disclosed degradation** — transcripts unreachable, or no prior fleet cumulative to difference against (each declared loudly at capture). Burn consumers sum main + fleet; a `null` adds nothing, so that entry's burn is a floor. |
| `transcript_fleet` | object \| null | the fleet's cumulative high-water at capture — what the next fleet slice differences against. Banked whenever the fleet tree is readable, even when the `fleet` slice degraded to `null`. An unreachable fleet at one capture therefore costs TWO fleet slices — its own and its successor's (which finds no cumulative to difference against); the chain heals at the second capture after the outage, and the fleet burn across the gap stays out of every sum (a disclosed floor, never a fabricated recovery). |
| `slice_basis`     | string \| null  | self-describes the slice unit of BOTH components ([13.6], Rule 15): `per_deliverable` (a bounded delta against a prior same-`runtime_session` capture) · `since_process_start` (the first capture — the full reading IS the first slice) · `unbounded_cumulative` (a non-monotone degradation in either component's cumulative, OR a `harvest_basis`/`coverage` seam where the prior reading is a different unit or scope — disclosed and **excluded** from every burn sum and rate) · `null` when nothing was harvested. |
| `harvest_basis`   | string \| null  | how the reading was **harvested**: `per_response` (grouped by `requestId`, one response counted once); `null` on a degraded entry. Absent on entries written before the 2026-07-25 dedupe fix (see *History*); a differing prior refuses the delta. |
| `coverage`        | string \| null  | what the reading **spans**: `main_plus_fleet` (the [32.8] epoch's coverage — main into `tokens`, fleet into `fleet`, split); `main_session` on [32.4]-era entries (main only); `null` on a degraded entry. Absent on entries written before the [32.4] narrowing (those BLENDED main + subagent transcripts into one figure). A differing prior refuses the delta exactly as `harvest_basis` does, and burn consumers skip post-epoch samples whose coverage differs from the epoch line's declared one. |
| `compaction_cycles` | number \| null | count of real compaction events (`isCompactSummary == true`, `timestamp ≥` the prior capture) the slice spanned ([13.6]); powers balloon detection. |
| `dollars`         | null            | **always null** — token-only rung; pricing tables drift and the spec forbids a guessed conversion. |
| `spike_c_rung`    | string          | `"B"` when tokens were harvested, `"degraded"` when not.                                          |
| `perf`            | object          | `{op_wallclock_s, suite_runtime_s}` — both **measured by guv**, never agent values. `suite_runtime_s` comes from `--run-suite` or the `.last-suite-runtime` artifact; `null` when neither exists. |

## Harvest semantics (the kept [13.6] slice + the per-response dedupe)

- **Bounded slice.** A `CLAUDE_CODE_SESSION_ID` names a whole `claude` process;
  a guv session is a slice of it. `tokens` is the delta from the last
  same-`runtime_session` capture (per class); `transcript_tokens` preserves the
  cumulative high-water for the next delta. The `fleet` component rides the
  same discipline against `transcript_fleet`, in the same window. A negative
  class delta in EITHER component (non-monotone reading; for fleet: subagent
  files pruned) degrades the whole entry to `unbounded_cumulative`, disclosed,
  never a fabricated slice — one `slice_basis`, one rule. A fleet that cannot
  be differenced at all (unreachable now, or a `null` prior cumulative) goes
  `fleet: null`, disclosed, while the main slice proceeds.
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
- **Designed degradation (Rule 15).** Main transcript unreachable → the
  mechanical fields still write, `tokens: null`, `spike_c_rung: "degraded"`.
  Fleet transcripts unreachable → `fleet: null`, disclosed, main harvest
  intact (never a partial fleet sum — a floor wearing a total's field name).
  The log existing never depends on harvestability.

## Example entry

```json
{"schema":"guv.meter.v1","ts":"2026-08-11T10:00:00Z","session":"session-2026-08-11-002","session_derived":true,"runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","deliverable_ids":["32.8"],"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"transcript_tokens":{"input":72804,"output":662186,"cache_read":104991852,"cache_creation":7563948},"fleet":{"input":1204,"output":48211,"cache_read":9120455,"cache_creation":602138},"transcript_fleet":{"input":2408,"output":96422,"cache_read":18240910,"cache_creation":1204276},"slice_basis":"per_deliverable","harvest_basis":"per_response","coverage":"main_plus_fleet","compaction_cycles":1,"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.041,"suite_runtime_s":786.572}}
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
- **Coverage narrowing ([32.4]) and the split ([32.8]).** [13.1] had widened
  the harvest to the sibling subagent transcripts (main-only captured ~71% of a
  review-heavy session's cache_read; subagents added ~1.4x). That blended total
  was indistinguishable from main-session burn, so [32.4] narrowed coverage to
  the main transcript and made the scope self-describing; [32.8] re-added fleet
  burn as the distinct `fleet` component — the same span [13.1] reached for,
  in the shape that keeps the two figures apart. Absence of `coverage` marks a
  pre-narrowing (blended) entry; `main_session` marks a [32.4]-era main-only
  one.
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
  large favourable rate error that is entirely the unit change — and, for any
  forecast banked before the [32.8] widening, a coverage-scope component too
  (a rate fitted from main-only samples graded against a main+fleet actual).
  The calibration record carries no coverage stamp, so that seam is disclosed
  here, not machine-checked at the grade.
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
