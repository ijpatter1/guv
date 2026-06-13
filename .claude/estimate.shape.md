# Estimate sidecar — shape

The estimate sidecar holds the harness's **session estimates** for the live
plan's deliverables ([9.6] of the plan-as-data spec; A-003, the governor's
meter). It is **published shape** alongside the tracker grammar, the manifest
schema, and `status.json` — the projection ([9.7]) reads it as the quantity
half of its takeoff, and the helper `.claude/estimate.sh` is the only writer.

## Where it lives, and why beside the tracker

```
docs/estimates.json        # the sidecar (default path; cwd = the control plane root)
docs/PHASE_STATUS.md       # the tracker — a SEPARATE file, never carrying estimate data
```

The sidecar sits **beside** the tracker, **never inside it**. The tracker is
**evidence** — what *is*: which deliverables exist, their deps, their
completion. Estimates are **interpretation** — what we *guess* a deliverable
will cost. Keeping them in separate files is the whole design:

- An estimate edit leaves the tracker **byte-identical** — it costs no grammar
  change, no contract change, and never routes through the `/replan` tracker
  engine. `.claude/estimate.sh set` writes only the sidecar.
- Estimates are **revisable without touching plan state**: re-`set` an ID and
  the plan, its IDs, its deps, and its amendment record are all untouched.
- **No estimate token ever enters the tracker grammar.** The word "estimate"
  appears nowhere in a deliverable line; the sidecar is its only home.

## Shape

A single JSON object keyed by deliverable ID, each value the ratified
session estimate:

```json
{
  "9.1": 1,
  "9.6": 1,
  "9.7": 3
}
```

- **Keys** are deliverable IDs (`N.M`), matching the tracker's IDs verbatim —
  the sidecar is keyed by ID so a `/replan` reorder or rename of *position*
  never disturbs it (IDs are immutable; the sidecar rides their stability).
- **Values** are integers **≥ 1**. There is no zero-session deliverable;
  sessions are whole. A value below 1, a fraction, a string, or a non-object
  document is **MALFORMED** — `validate` exits 5 and `set` refuses the write.
- **Absent file** = no estimates ratified yet — legal, validates trivially.
  Every ID not present reads as the **default**.

## The default, and balloons

The default estimate is **1**. The harness pushes deliverables toward
session-sized work, so a 1 is the unremarkable case and needs no ratification
event of its own (a deliverable with no entry reads as 1). Anything **above 1**
is a **balloon** — a deliverable the planner judged larger than one session —
and is **flagged** so it surfaces at the plan-time confirm gate for the person
to ratify or split. `.claude/estimate.sh balloons` lists them.

## How estimates are proposed and ratified

Estimates are acquired at **plan time**, in the **same confirm gate** as the
plan itself — the planner is already reading the wording and acceptance
criteria, so it proposes a per-deliverable estimate (default 1, balloons
called out) and the person ratifies them alongside the plan:

- **`/plan-initiative`** proposes an estimate per generated deliverable and
  records the ratified set with `estimate.sh set` after the plan's confirm.
- **`/replan` insert** acquires the new deliverable's estimate **inside the
  same confirmation** that approves the insert, then `set`s it — the tracker
  mutation and the sidecar write are one ratification, two files.

The helper is deterministic (Rule 12): it reads, writes, and validates; the
judgment (the number, the conversation) stays in the commands.

## Interface (`.claude/estimate.sh`)

| Command | Effect |
| --- | --- |
| `default` | print the default estimate (`1`) |
| `get ID [SIDECAR]` | the estimate for `ID`, or the default if unrecorded (read-only) |
| `set ID N [SIDECAR]` | ratify `ID → N` (`N` integer ≥ 1); creates the sidecar; refuses out-of-shape |
| `validate [SIDECAR]` | check the sidecar against this shape; exit 5 MALFORMED |
| `list [SIDECAR]` | emit the sidecar JSON (sorted), `{}` when absent |
| `balloons [SIDECAR]` | the IDs whose estimate exceeds the default |

`SIDECAR` defaults to `docs/estimates.json` (the same default-and-override
convention the resolver and `/replan` engine use for the tracker). Pure bash +
jq; no new runtime dependency.
