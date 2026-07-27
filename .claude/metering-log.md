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
| `tokens`          | object \| null  | token counts **by class** — `{input, output, cache_read, cache_creation}` — the **bounded per-session SLICE** ([13.6]): the transcript delta (main + subagents) from the last same-`runtime_session` capture to now, NOT the cumulative whole-transcript sum. `null` when the transcript is unreachable. |
| `transcript_tokens` | object \| null | the **raw cumulative high-water reading** by class at capture (main + subagents to that instant) — the value the NEXT slice differences against ([13.6]). NOT a per-session figure; `slice_basis` names the unit. `null` when the transcript is unreachable. |
| `slice_basis`     | string \| null  | self-describes `tokens`' unit ([13.6], Rule 15): `per_deliverable` (a bounded delta against a prior same-`runtime_session` capture) · `since_process_start` (the first capture in this transcript — the full reading IS the first slice) · `unbounded_cumulative` (**two distinct causes**: a non-monotone/unbounded degradation, OR a `harvest_basis` vintage break where the prior reading was harvested under a different unit — either way disclosed and **excluded** from `observed_rate()`) · `null` when nothing was harvested. |
| `harvest_basis`   | string \| null  | self-describes how the raw reading was **harvested**, the axis orthogonal to `slice_basis`'s unit: `per_response` (usage grouped by `requestId`, one API response counted once — the post-fix harvest); `null` on a **degraded** entry, where no harvest happened and there is no unit to name. **Absent on every entry written before the per-response dedupe landed**, and that absence is load-bearing: a prior reading whose `harvest_basis` differs from the current one is a *different unit*, so differencing against it is refused (`slice_basis` degrades to `unbounded_cumulative`). See "per-response dedupe" below. |
| `compaction_cycles` | number \| null | count of real compaction events (`isCompactSummary == true`) the slice spanned — main-transcript events with `timestamp ≥` the prior capture ([13.6]). Raw evidence (a count); powers balloon detection and Phase 14. `null` when the transcript is unreachable. |
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
  The writer groups those lines **per API response** and sums the responses by
  class — **rung B**: session-scalar token attribution. The per-response grouping
  is not incidental: one response occupies N transcript lines, so a per-*line*
  sum over-counts (see "per-response dedupe" below).
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

### [13.6] — the bounded per-session slice (the unit fix)

[13.1] got the harvest's **scope** right (subagents in). [13.6] gets its **unit**
right. A `CLAUDE_CODE_SESSION_ID` names the whole `claude` *process* — one transcript
that grows across every `/clear`, `/compact`, and handoff (`docs/notes/meter-forensics.md`).
A guv session is a **slice** of that transcript, not the whole thing. The pre-[13.6]
harvest summed the *whole* transcript at every capture, so each entry was a **cumulative
snapshot of the entire process to date** — the entries for one transcript strictly
increase, and averaging those running totals inflated the observed per-session anchor
~4.6× (a bogus ~503M mean vs. a real ~70–350M).

The fix records the **delta**, not the total:

- `tokens` is the **bounded slice** — `cumulative_now − cumulative_at_the_last_capture_for_this_runtime_session`, computed by reading the most recent prior `guv.meter.*` entry for this `runtime_session` (across **both** boundaries — session and queue advance one high-water mark per transcript) and differencing per class.
- `transcript_tokens` preserves the **cumulative high-water reading** so the next slice has something to difference against. It is raw evidence (the same extraction `tokens` *used* to be), never a per-session figure.
- `slice_basis` makes the unit **self-describing** (Rule 15): `per_deliverable` (a real delta), `since_process_start` (the first capture — the full reading is correctly the first slice, disclosed), or `unbounded_cumulative` (a non-monotone degradation — disclosed and excluded downstream). A reading is never mistaken for the wrong unit.
- `compaction_cycles` counts the real compaction events the slice spanned (`isCompactSummary == true`, `timestamp ≥` the prior capture) — raw evidence powering **balloon detection** and Phase 14.

**Migration (append-only, read-time).** The log is append-only, so pre-[13.6]
entries are **not** rewritten. `budget-gate.sh`'s `burn_sum` ([13.5]) is slice-aware:
it reads slice-tagged entries directly, excludes `unbounded_cumulative`, and
**differences legacy cumulative entries per `runtime_session`** at read time — recovering
the real per-session deltas from the existing history without a destructive migration.

`observed_rate()` ([9.7]) shares the slice-awareness but **not** the differencing, and
the divergence is deliberate rather than a gap. A **burn** legitimately sums every entry
in its window and then discloses the mix, because the question is "what has this cost".
A **rate** cannot average across two harvest units at all, so since the [9.1] dedupe fix
`observed_rate()` **excludes pre-fix (`pre-dedupe`) entries outright** and windows to the
live [13.4] lineage, rather than differencing them in. Same log, two questions, two
correct answers — and an `n=0` is a legible result, not a failure.

**Consumer migration status (follow-up, [13.6] scoped the read-side fix to
`observed_rate()`).** `budget-gate.sh` ([9.3]) got its read-time migration at
**[13.5]** (its `burn_sum` differences legacy cumulative entries per
`runtime_session` and excludes `unbounded_cumulative`), and its initiative figure
is additionally **windowed to the [13.4] lineage** (entries since the lineage
boundary — the opening plan bank, or between initiatives the last grade;
whole-log cumulative only as the no-lineage degradation). One reader of
`tokens` is only PARTLY slice-aware: `emit-metrics.sh` ([9.5], the aggregate
emitter). For **new** slice entries it is correct (a sum of per-session slices IS
the total burn), and it now excludes `unbounded_cumulative` from its
**per-deliverable** rollup. Two caveats remain. Over the **legacy** cumulative
entries it still double-counts, and its `cost.by_initiative` is a whole-log
rollup with no lineage window — a different figure from the gate's windowed burn.
Until it gets the same read-time migration `budget-gate.sh`'s `burn_sum` got, read
`emit-metrics` initiative totals over a log containing pre-[13.6] entries with
that caveat in mind.

**The exclusion cuts tokens, never sessions — at every level.** An
`unbounded_cumulative` entry is left out of the token sums in both
`cost.by_deliverable` and `cost.by_initiative`, because the reading is a
process-to-date cumulative that belongs to no single slice. Its **session count
still counts, everywhere**: the session really happened and is a real unit of
work; it is the token value that is not a slice, not the session. So
`by_deliverable[id].sessions`, `by_initiative.sessions`, and `by_phase.sessions`
always agree about whether a session existed, and disagree only where they are
*supposed* to (distinct-session counting at the phase and initiative levels vs.
per-attribution legs). Implementation note, because it is easy to get wrong:
`by_deliverable` **zeroes** the excluded entry's tokens rather than filtering the
entry out — filtering before the deliverable explode would silently take the
session count with it, and did.

**Balloon detection — declared, never stopped.** When a deliverable's slice spanned
**more compaction cycles than its sizing** (`compaction_cycles >` the deliverable's
sized sessions from [13.2]), the meter declares a loud `BALLOON:` line the handoff
surfaces — but the capture still exits 0. A deliverable-budget breach is **fuzzy**: a
human call at the handoff boundary, never a mid-flight stop ([13.5] semantics). No
compaction signal or no sized budget → no declaration (absence of a signal is never a
fabricated breach, Rule 15).

**Designed degradation (Rule 15).** The transcript is a research-preview surface.
If `CLAUDE_CODE_SESSION_ID` is unset, the file is absent, or jq cannot sum it,
the writer takes the documented fallback rung: it emits the fields that *are*
mechanical (`ts`, `session`, `deliverable_ids`, `model` if any, and the
**always-present** `perf.op_wallclock_s`), sets `tokens: null`, and marks
`spike_c_rung: "degraded"`. The log existing never depends on Spike C — a "no"
degrades the meter's resolution, never blocks the line.

### 2026-07-25 — per-response dedupe (the harvest-unit fix)

[13.1] got the harvest's **scope** right (subagents in). [13.6] got its **slice
unit** right (delta, not cumulative). Both were still reading the transcript one
**line** at a time — and a line is not a response.

**The defect.** The runtime serializes a single assistant response as N transcript
lines, one per content block (thinking / text / tool_use), and those lines carry
**duplicate usage** in one of two forms: 66.2% of responses repeat a byte-identical
`message.usage` on every line, and the other 33.8% carry near-zero placeholders until
the response's final line (measured over 41,949 responses, 2026-07-25). Summing per
line therefore multiplies `input`, `cache_read` and `cache_creation` by the block count — i.e. by
roughly the number of tool calls in the turn — and inflates `output` too under the
main-transcript serialization. Measured on the local corpus (2026-07-25; the corpus
grows, so treat the counts as as-of and the **ratio** as the finding): 21,323 usage
lines collapsing to 8,422 responses, naive 2.19B vs deduped 867M — **2.5x
inflation, ~1.32B phantom tokens**.

This was never cosmetic. `burn = input+output+cache_read+cache_creation` feeds
`budget-gate.sh`'s BREACH decision, the [13.4] forecast grade, and the calibration
record. And the error is **shape-dependent** — tool-heavy turns inflate far more
than prose turns (**corpus-wide, 2026-07-25**: main-loop output 3.02x vs subagent
output 1.03x) — so it biases any comparison between differently-shaped work instead
of cancelling out. Every ratio in this section is stamped and population-labelled
because they all drift as the corpus grows; re-measure rather than reuse them.

**The fix.** The harvest groups usage by `requestId` and takes the **max** per class
before summing. `max` is correct under both observed serializations: identical
repeats, and near-zero output placeholders until the response's final line. It also
ignores an aborted all-zero line sharing a live `requestId`. Lines carrying neither
`requestId` nor `uuid` — **or an empty one** — get a per-line synthetic key, so a
key-less transcript meters exactly as it did before rather than collapsing to a
single max.

**Evidence, and its limits.** The load-bearing proof is structural: **no
`message.id` spans two `requestId`s** (0 of ~42k responses corpus-wide), so a
`requestId` is a response boundary. The billing cross-check is **partial** — Claude
Code's `/cost` reports a scope this analysis could not reconstruct (no window start,
project slug, or session tree reproduces its per-model totals), so there is no
absolute per-model reconciliation; on opus-5, the one model whose corpus usage is
concentrated in the billed period, deduped output is **1.03x** of billed against
**2.35x** per-line. Both figures are an **instant reading** (2026-07-25), not a stable
constant — opus-5's per-line/deduped output ratio moves between ~1.8x and ~3.1x across
the three days that model has existed in this corpus, so re-measure rather than reuse
these two numbers. Corroboration, not proof.

**Known under-count, disclosed not corrected.** `message.usage.iterations[]`
decomposes a `requestId` that was retried or continued into its billed calls, and
the top-level `usage` this harvest reads reports only the **last** one. Measured: 3
requestIds in 105,109 usage lines, costing ~563k `cache_read` — **~0.01%** of corpus
burn. Summing iterations would add a branch for a research-preview field absent from
a third of lines to recover a rounding error; it is declared here instead. No
tripwire is built for this (Rule 3 — the branch would be the very thing declined);
the manual re-measure is the check, and the threshold that should trigger the fix is
`iterations`-bearing burn exceeding **1%** of corpus burn — two orders of magnitude
above today's 0.01%:

```bash
jq -s '[.[]|.message.usage//.usage|select(.!=null)]
       | { multi: [.[]|select((.iterations//[])|length > 1)]|length, lines: length }' \
  ~/.claude/projects/*/*.jsonl
```

**Migration — a vintage marker, and why the legacy entries are left inflated.**
[13.6] could migrate its legacy entries at read time (difference the cumulative ones
per `runtime_session`). That pattern does not transfer here — but the reason is
**transcript survival, not arithmetic.** An earlier draft of this section claimed
read-time recovery was *impossible* because the inflation is shape-dependent. That
claim does not hold up, and the measurement that refutes it is worth recording:

- Reconstructed per *entry* against surviving transcripts, the inflation runs
  **2.31–2.88x across 18 real entries** of widely varying shape (weighted 2.53x). A
  single ~2.55x deflator would recover every one of them to within ±13%, against
  leaving them ~155% high.
- The shape spread is real but far narrower than it looks on the **output** class
  alone (corpus-wide today, 3.02x main-loop vs 1.03x subagent). Entry burn is ~93%
  `cache_read`, which compresses the **all-class** spread to **2.65x main-loop vs
  2.27x subagent** over the 18-entry population above (corpus-wide the same
  all-class pair reads 2.49x / 2.35x — narrower still).

What actually blocks a backfill is that the evidence is mostly **gone**: of the 14
`runtime_session`s in this log, only **2 still have transcripts — 18 of 54 entries**.
A deflator applied to the other 36 would be an estimate wearing the same field name
as a measurement, inside an append-only record whose entire value is that its lines
are raw evidence. So pre-fix entries stay **as-written and disclosed** — known to be
~2.5x high, never silently corrected. (The 18 survivors are, as it happens, precisely
the entries feeding live decisions. A deliberate re-derivation of *those* is a
defensible future move — but as a new, separately-labelled record, never an in-place
edit of the log.)

What the fix can do is stop the two vintages being **subtracted from each other**.
The new **`harvest_basis`** field marks the harvest unit (`per_response`), and the
delta path checks it **before** the [13.6] magnitude guard: when the prior reading's
vintage differs from the current one, the delta is refused and `slice_basis` degrades
to `unbounded_cumulative` — disclosed, and excluded from `observed_rate()`.

**Consumer migration status — two readers are vintage-aware; one discloses, one
excludes.** `harvest_basis` makes the two vintages *separable*, and the two consumers
that separate them do it differently on purpose:

- **`budget-gate.sh` discloses.** BURN legitimately sums every entry in the window in
  whatever unit it was recorded, so the gate cannot drop pre-fix entries without
  under-reporting spend. It reports the mix instead, under one `HARVEST UNIT HAZARD`
  banner carrying the kind as a field: `mixed` (the window spans both vintages),
  `mismatch` (the window is uniformly one vintage and the setpoint is declared in the
  other), or `malformed` (the declaration is not a harvest unit, so that second check
  is off). `mismatch` needs `budgets.initiative.harvest_basis`, because a setpoint is
  an integer and integers record no unit. It **qualifies** the number without
  converting it, and never moves a setpoint. Since [28.5] the same banner machinery
  carries a **second, orthogonal axis** — `budgets.initiative.denomination`, headed
  `SETPOINT DENOMINATION HAZARD` when it fires alone and emitted alongside the harvest
  headline when both do. The `hazard:` field names both axes' states. That axis has no
  log field at all and never will: burn is a raw four-class sum in *code*, so what is
  undeclared there is the *ceiling's* unit, not the reading's.
- **`projection.sh observed_rate()` excludes.** A RATE is an average, and an average
  across two units is not a number, so pre-fix and degraded-`null` entries are not
  samples at all — they are filtered out and the emitted document discloses the
  window and vintage it sampled (`basis.sample_window`, `basis.sample_vintage`).

Still unmigrated and averaging across the seam with nothing said: the [13.4]
close-time `ACTUAL_RATE` and `emit-metrics.sh` ([9.5]).

Two consequences were live for initiative 004, and both are **unit artifacts, not
performance**. Both have since been acted on — recorded here because the record is
what makes the next one recognizable:

- `budgets.initiative.tokens` was **4,741,208,137**, denominated in the **pre-fix**
  unit: every one of the 53 samples behind it came from the inflated log. It was
  **re-denominated to 1,000,000,000 on 2026-07-26**, derived bottom-up from measured
  post-fix cost rather than by dividing the old figure — the meter error is
  shape-dependent (subagent output 1.04x, main-loop output 3.20x), so no single
  divisor converts a pre-fix number and none was applied.
- The banked opening forecast (`blended_tokens` 105,712,556, from
  `observed_mean_tokens_per_session` 103,183,079 over n=53 — 53, not the 54 entries
  counted below, because the forecast was banked one entry before the count was taken)
  is **still** in the pre-fix unit and stays that way: the calibration record is
  append-only. The close-time [13.4] grade will therefore report a large *favourable*
  **rate** error that is entirely this unit change, against a setpoint that is no
  longer in that unit.

Re-denominating is a person's commit — which is exactly why the gate declares and
stops there. Note what re-denominating does **not** fix: the gate's burn figure is
still summed from whatever the log holds, so a post-fix ceiling over a pre-fix window
is the mismatch case above, not a solved one. Declare
`budgets.initiative.harvest_basis` alongside the ceiling or the gate cannot see it — and
`budgets.initiative.denomination` with it, which is the **second**, independent axis
([28.5]): `harvest_basis` says how a reading was harvested, `denomination` says what unit
the ceiling's integer is in (`raw_tokens` — the four-class sum the gate actually
computes — or `cost_weighted`, base-input-equivalents). Both default to off when absent,
and both are declarations rather than conversions.

What is **not** available as a remedy, though it reads like one: re-banking the
forecast. `projection.sh bank --at plan` is idempotent per initiative, so on a live
initiative it is a no-op; and a `--at phase-N` bank never moves the lineage window's
anchor, which reads the opening `plan` bank (or the prior `grade`) and ignores phase
boundaries. It is **not** universally true that a phase bank cannot become the grade's
baseline — `projection.sh` falls back to the last forecast of any boundary when no
plan bank exists, so on a record that never banked at `plan` a phase bank *is* the
baseline. On **this** record it is not, because 004 opened with a `plan` bank; do not
carry the shortcut to another record.

`observed_rate()` used to apply no ts window and no vintage filter at all — it blended the
whole record, so all 54 pre-fix samples sat in that blend permanently, and 53 of them
predate 004's lineage boundary (`2026-07-20T22:45:57Z`) and are outside the initiative's
burn window entirely while still setting the rate every 004 forecast was built on. **That
was fixed at [9.7]/`e16b99d`:** the reader now windows to the live lineage and filters to
`harvest_basis == "per_response"`, and discloses `basis.sample_window` /
`basis.sample_vintage` so the result is legible.

The consequence is not a cleaner number — it is an honest `n=0`. With every 004 sample
pre-fix, the filter correctly admits nothing, and the projection falls back to its
**structural** constants. Those constants were themselves fitted to pre-fix burns, so the
forecast got *larger*, not smaller. Re-deriving them is **[28.4]**. Until it lands, read
any cost-to-complete on this record as modeled rather than measured — the gate now says
so in the `forecast basis:` line. Do not send an operator to `bank` expecting it to clear
anything.

The vintage guard below makes the first-ever `unbounded_cumulative` entry certain —
this log had never carried one (54 entries: 15 legacy, 30 `per_deliverable`, 9
`since_process_start`), so [13.6]'s emitter caveat stopped being a purely *legacy*
concern the moment the guard armed. That is why the same commit gave
`emit-metrics.sh` a `slice_basis` filter on its per-deliverable rollup: without it,
the guard's own first entry would have been credited in full to whatever deliverable
its session named. See the asymmetry note under "Who reads `tokens`" for what the
filter does and does not cover.

That ordering is the whole point. The [13.6] guard is **magnitude-based**
(`all(. >= 0)`), so it cannot see a unit change: once a deduped cumulative reading
outgrows the last inflated one, every class turns positive again and a **cross-unit
subtraction** would be written as a valid `per_deliverable` slice and summed into the
initiative burn and `observed_rate()`. A magnitude guard catches a reading that went
*backwards*; only a vintage marker catches one that changed *meaning*. So the first
capture after the fix, for a `runtime_session` that **has** a pre-fix prior, correctly
discloses `unbounded_cumulative` rather than inventing a plausible slice (Rule 15). A
`runtime_session` with no prior entry at all is unaffected — it discloses
`since_process_start` exactly as before, and that reading is a valid sample.

## Example entry

```json
{"schema":"guv.meter.v1","ts":"2026-06-13T21:40:12Z","session":"session-2026-06-13-004","session_derived":true,"runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","deliverable_ids":["9.1"],"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"transcript_tokens":{"input":72804,"output":662186,"cache_read":104991852,"cache_creation":7563948},"slice_basis":"per_deliverable","harvest_basis":"per_response","compaction_cycles":1,"dollars":null,"spike_c_rung":"B","perf":{"op_wallclock_s":0.041,"suite_runtime_s":1.232}}
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
| `tokens`           | object \| null  | token counts by class — `{input, output, cache_read, cache_creation}` — the **bounded per-deliverable SLICE** ([13.6]): the transcript delta (main + subagents, [13.1]) from the last same-`runtime_session` capture (session OR queue boundary — both advance one high-water mark per transcript), NOT the cumulative sum; `null` when unreachable. |
| `transcript_tokens`| object \| null  | the raw cumulative high-water reading by class at capture — the value the next slice differences against ([13.6]); `null` when unreachable. |
| `slice_basis`      | string \| null  | self-describes `tokens`' unit ([13.6]): `per_deliverable` · `since_process_start` · `unbounded_cumulative` (a non-monotone degradation OR a `harvest_basis` vintage break; excluded from `observed_rate()`) · `null`. Identical semantics to the session-boundary field above. |
| `harvest_basis`    | string \| null  | self-describes the **harvest** unit: `per_response` (usage grouped by `requestId`); `null` on a degraded entry. Absent on pre-dedupe entries; a vintage mismatch against the prior reading refuses the delta. Identical semantics to the session-boundary field above. |
| `compaction_cycles`| number \| null  | count of real compaction events (`isCompactSummary == true`, `timestamp ≥` the prior capture) the slice spanned ([13.6]); `null` when unreachable. |
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
{"schema":"guv.meter.queue.v1","ts":"2026-06-14T18:22:05Z","deliverable_id":"9.4","dispatch_outcome":"landed","runtime_session":"6c1048bb-a31b-45bb-afbb-de9a6e5d2c0b","footprint":{"files":3,"insertions":42,"deletions":7},"model":"claude-fable-5","tokens":{"input":36402,"output":331093,"cache_read":52495926,"cache_creation":3781974},"transcript_tokens":{"input":72804,"output":662186,"cache_read":104991852,"cache_creation":7563948},"slice_basis":"per_deliverable","harvest_basis":"per_response","compaction_cycles":0,"dollars":null,"spike_c_rung":"B","perf":{"landing_wallclock_s":1.25}}
```
