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
whose subject carries its bracketed `[N.M]` ID — the convention git already
records — found with `git log --grep='[N.M]' -F` (fixed-string, so the brackets
are literal). The deliverable→phase map comes from the **resolver**
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

| field | type | source / meaning |
|-------|------|------------------|
| `cost.by_deliverable` | object | keyed by deliverable ID. A session attributed to N deliverables credits its tokens to **each** leg (additive — the per-deliverable view), so an ID appearing in two sessions sums both. `session-scalar` (the meter's no-single-ID attribution) is **not** a deliverable and never appears here as a phantom phase. |
| `cost.by_phase` | object | keyed by phase number (as a string). The per-deliverable sums rolled up **through the deliverable→phase map** (the resolver's JOIN). An ID with no phase in the map contributes to the initiative but to no phase. |
| `cost.by_initiative` | object | the whole live plan: **every log entry counted once** (not per leg) — a multi-attribution session is one set of tokens, one session, never double-counted at the initiative level. `sessions` = the total log-entry count. |

### `perf` — git-derived, no instrumentation

Every number is derived from `git log` over existing history; nothing is
measured live, nothing is agent-supplied.

| field | type | source / meaning |
|-------|------|------------------|
| `perf.by_deliverable[ID].commits` | number | **commits-per-deliverable** — the count of commits whose subject carries `[ID]`. |
| `perf.by_deliverable[ID].cycle_time_s` | number | **cycle time** — last author date − first author date across the deliverable's commits, in seconds. A single commit is `0`. |
| `perf.by_deliverable[ID].footprint` | object | **footprint** — `{files, insertions}`: distinct files touched and total inserted lines across the deliverable's commits, from `git log --numstat`. |
| `perf.by_deliverable[ID].lane_lifetime_s` | number \| null | **lane lifetime** — the span the deliverable's lane was live. Absent merge metadata it degrades to the commit span (== cycle time); always present, number-or-null, never agent-set. |
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
