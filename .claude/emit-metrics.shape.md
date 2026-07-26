# Cost-and-performance metrics — shape ([9.5])

The cost-and-performance emitter (`.claude/emit-metrics.sh`) is the **one parser
of meaning** over the meter's raw evidence. It reads the raw metering log
(`.claude/metering/metering.ndjson`, written append-only by `.claude/meter.sh`)
and git history, and emits **one published JSON document** to stdout on the JSON
spine. This shape joins the **tracker grammar**, the **manifest schema**, and
**`status.json`** as published contract surface — the same four-surface contract
the metering-log shape (`.claude/metering-log.md`) and the estimate sidecar
shape (`.claude/estimate.shape.md`) are documented alongside.

## One-parser discipline (A-001)

**Consumers read the emitter, never the raw log, and never re-derive.** The raw
metering log stays **raw** — it carries no totals, rates, or cost-per-X fields;
those are *meaning*, computed here. Exactly two scripts may name the raw log:
`meter.sh` (the only writer) and `emit-metrics.sh` (the only reader). Every other
consumer — commands, hooks, the renderer — reads this emitter's output. The
emitter is **read-only over everything**: it reads the raw log, reads git, reads
the tracker (through the resolver), and writes nothing but its document. It never
appends to, truncates, or in-place-edits the raw log.

The grammar-version feedback entry gains this shape as a **data point**: the
`cost.by_initiative` rollup is the initiative-level cost report, and the
`perf.by_phase` wall-clock is the initiative's phase-by-phase performance read.

## Derive, don't instrument

The performance half is derived **mechanically from git history, retroactively
over existing history** — joined with the resolver's deliverable→phase map.
There is **no instrumentation**: no timer, no probe, no instrument hook, and
**no CLI flag that injects a metric**. A deliverable's commits are the commits
whose **subject** carries its bracketed `[N.M]` ID — the convention git already
records. Attribution is **subject-scoped, not full-message**: `git log
--grep='[N.M]' -F` (fixed-string, so the brackets are literal) *narrows* the
candidates, then a post-filter on the subject field (`%s`) drops any commit that
carries `[N.M]` only in its **body** prose. So a commit that merely
*cross-references* another lane in its body is **never** credited to that
deliverable — only a subject-line ID attributes a commit. The deliverable→phase
map comes from the **resolver**
(`resolve-ready.sh --json`), never from re-splitting the ID string: the emitter
knows which phase a deliverable belongs to *only* via that map. That is the JOIN
the spec names (tracker grammar ⋈ git history) — a single source of plan truth.

## Top-level shape

```json
{
  "schema": "guv.metrics.v1",
  "generated": "2026-06-15T12:00:00Z",
  "cost": {
    "by_deliverable": { "9.1": { "tokens": {"input":100,"output":10,"cache_read":0,"cache_creation":0}, "sessions": 1 } },
    "by_phase":       { "9":   { "tokens": {"input":340,"output":34,"cache_read":0,"cache_creation":0}, "sessions": 3 } },
    "by_initiative":  { "tokens": {"input":340,"output":34,"cache_read":0,"cache_creation":0}, "sessions": 3 }
  },
  "perf": {
    "by_deliverable": { "9.1": { "commits": 2, "cycle_time_s": 7200, "footprint": {"files":2,"insertions":4}, "lane_lifetime_s": 7200 } },
    "by_phase":       { "9": { "wall_clock_s": 82800 } }
  }
}
```

## Fields

| field | type | source / meaning |
|-------|------|------------------|
| `schema` | string | shape version — `guv.metrics.v1`. Bumped on a breaking shape change (grammar-version discipline). |
| `generated` | string | ISO-8601 UTC instant of the run (`date -u`). Mechanical, never an agent string. |

### `cost` — the raw log, aggregated

The raw metering log summed into a published shape. Tokens are summed **by
class** (`{input, output, cache_read, cache_creation}`), matching the meter's raw
shape. `sessions` is a count of contributing log entries.

**The token exclusion cuts tokens, never sessions — at every level.** A log entry
whose `slice_basis` is `unbounded_cumulative` carries a burn figure that is not a
slice of this session (it accumulated from process start), so its **tokens** are
zeroed everywhere they are summed. Its **session** still counts everywhere:
the session happened and is a real unit of work — it is the token *value* that
is not attributable, not the session. This is why the three `sessions` figures
stay reconcilable with each other on any single payload; dropping the entry
instead would have made `by_deliverable` disagree with `by_initiative` with
nothing in this document saying which to believe.

The consequence for a consumer: a `{tokens: {0,0,0,0}, sessions: N}` entry means
**"N sessions, burn not measurable"** — it does not mean "N sessions that cost
nothing". Any tokens-per-session rate computed off this shape is diluted by
excluded entries, so filter on the raw log's `slice_basis` if the rate must be
exact. The distinction is not recoverable from the payload alone.

**These tokens carry no unit guarantee, and this shape does not disclose it.** The
raw log's second axis, `harvest_basis`, records *how* a reading was harvested —
`per_response` for entries written after the dedupe fix, absent for the pre-fix ones
that counted usage once per transcript LINE and so overstate by roughly 2.5x, by a
factor that varies with the shape of the work. This document's aggregates sum across
that axis without projecting it: a `cost.by_phase` figure spanning the fix is a total
in no single unit, and nothing in the payload says which entries contributed to it.
The axis is orthogonal to `slice_basis` above — a `per_deliverable` entry is a bounded
slice whether or not it is denominated correctly — so the `slice_basis` filter does
not help here. A consumer comparing two periods, or grading a forecast against
actuals, **must go to the raw log and partition on `harvest_basis` itself**; treating
these aggregates as commensurable across the fix is the same phantom-headroom error
`budget-gate.sh` discloses one layer down, with no banner at this layer to catch it.
Publishing the axis in this shape is unbuilt work, not a decision that it does not
matter.

| field | type | source / meaning |
|-------|------|------------------|
| `cost.by_deliverable` | object | keyed by deliverable ID. A session attributed to N deliverables credits its tokens to **each** leg (additive — the per-deliverable view), so an ID appearing in two sessions sums both. `session-scalar` (the meter's no-single-ID attribution) is **not** a deliverable and never appears here as a phantom phase. |
| `cost.by_phase` | object | keyed by phase number (as a string), rolled up **through the deliverable→phase map** (the resolver's JOIN). **Tokens** are the sum across the phase's member deliverables (additive — the per-deliverable view of the phase's spend). **`sessions` is a *distinct* count, not that sum**: a session attributed to two deliverables *in the same phase* is one session at the phase level, counted **once** — the same distinct-session discipline `by_initiative` uses, applied per phase (computed over the raw log, where session identity survives). An ID with no phase in the map contributes to the initiative but to no phase. |
| `cost.by_initiative` | object | the whole live plan: **every log entry counted once** (not per leg) — a multi-attribution session is one set of tokens, one session, never double-counted at the initiative level. `sessions` = the total log-entry count. |

### `perf` — git-derived, no instrumentation

Every number is derived from `git log` over existing history; nothing is
measured live, nothing is agent-supplied.

| field | type | source / meaning |
|-------|------|------------------|
| `perf.by_deliverable[ID].commits` | number | **commits-per-deliverable** — the count of commits whose **subject** carries `[ID]`. Subject-scoped: a body-only cross-reference to `[ID]` is not counted. |
| `perf.by_deliverable[ID].cycle_time_s` | number | **cycle time** — last author date − first author date across the deliverable's commits, in seconds. A single commit is `0`. |
| `perf.by_deliverable[ID].footprint` | object | **footprint** — `{files, insertions}`: distinct files touched and total inserted lines across the deliverable's commits, from `git log --numstat`. |
| `perf.by_deliverable[ID].lane_lifetime_s` | number \| null | **lane lifetime** — the span the deliverable's lane was live: first lane commit → the author date of the **merge commit that landed the lane** (a `--min-parents=2` merge whose subject names the lane / carries `[ID]`), in seconds. A genuine, **independent** lane-boundary signal — distinct from `cycle_time_s` (which spans the work commits only), and **never an alias of it**. When the lane fast-forwarded (no landing merge — the merge queue's default `land` path), there is no boundary signal and the value is **null** (honest absence), not a copy of cycle time. The landing merge is the boundary, not work: it is excluded from `commits` / `cycle_time_s` / `footprint`. Always present, number-or-null, never agent-set. |
| `perf.by_phase[N].wall_clock_s` | number \| null | **phase wall-clock** — min→max author date across the commits of *all* the phase's member deliverables, in seconds. Membership is the resolver's deliverable→phase map (the JOIN), never re-derived from the ID prefix. |

## Designed degradation (Rule 15)

- **Absent metering log** → a valid document with **empty** `cost` aggregates
  (`by_deliverable: {}`, zeroed `by_initiative`). The emitter never fabricates
  and never crashes on a missing log.
- **No tracker / resolver refusal** → an empty deliverable→phase map; cost still
  aggregates by deliverable (the log is self-sufficient for that), and the
  phase/initiative rollups find no phase members rather than dying.
- **Outside a git repo** → perf degrades to zeros / nulls (perf is git-derived;
  no git, no derivation), never a crash.
- **An entry whose burn is not a slice** (`slice_basis: unbounded_cumulative`)
  → its **tokens** are zeroed at every level, its **session** is still counted at
  every level. The alternative rungs were both worse: dropping the entry loses a
  session that really happened, and summing it credits a deliverable with burn
  that accumulated before its work began.

## Interface (`.claude/emit-metrics.sh`)

```
bash .claude/emit-metrics.sh [--log PATH] [--tracker PATH]
```

`--log` and `--tracker` are test overrides (defaults: root-relative
`.claude/metering/metering.ndjson` and `docs/PHASE_STATUS.md`). cwd must be the
project root. There is **no flag that sets any cost or perf value** — cost is
summed from the raw log, perf is git-derived. *Measure exhaust, never steam.*
Pure bash + jq + git; no new runtime dependency.

Exit: `0` emitted one valid document · `2` usage · `4` no/corrupt manifest.
