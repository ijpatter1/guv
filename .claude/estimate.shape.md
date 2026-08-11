# Estimate sidecar — shape

The estimate sidecar holds guv's **session estimates** for the live
plan's deliverables ([9.6] of the plan-as-data spec; A-003, the governor's
meter). It is **published shape** alongside the tracker grammar, the manifest
schema, and `status.json` — the projection ([9.7]) reads it as the quantity
half of its takeoff, and the helper `.claude/estimate.sh` is the only writer.

> Every command named in this file (`/plan`, `/replan`, …) is `/guv:`-namespaced
> under a plugin install.

## Where it lives, and why beside the tracker

```
docs/estimates.json        # the sidecar (default path; cwd = the guv instance root)
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

## Shape (dual-form — [13.2])

A single JSON object keyed by deliverable ID. Each value is **either** a legacy
integer session count **or** a *sized* object that carries the deliverable's
**context-fraction** alongside the session count:

```json
{
  "9.1": 1,
  "9.7": 3,
  "13.2": { "sessions": 1, "fraction": 0.5, "size": "medium" }
}
```

- **Keys** are deliverable IDs (`N.M`), matching the tracker's IDs verbatim —
  the sidecar is keyed by ID so a `/replan` reorder or rename of *position*
  never disturbs it (IDs are immutable; the sidecar rides their stability).
- **Legacy value** — a bare integer **≥ 1** (the original shape). Still valid,
  still resolves: existing plans need no migration. There is no zero-session
  deliverable; sessions are whole.
- **Sized value** ([13.2]) — an object `{ "sessions": 1, "fraction": F, "size":
  S }` where `0 < F ≤ 1` is the deliverable's share of the **[9.2] occupancy
  budget** (the per-session context setpoint) and `S ∈ {light, medium, heavy}`.
  A sized deliverable is **one session by construction** (`sessions` is 1) —
  anything larger is a balloon to be **split**, never a stored `sessions: 2`. A
  stored `fraction > 1`, an unknown `size`, or a missing `sessions` is MALFORMED.
- Any other value — below 1, a bare fraction, a string, an array, a malformed
  object — is **MALFORMED**: `validate` exits 5 and `set`/`set-sized` refuse the
  write.
- **`get` returns the SESSIONS integer for both forms** (legacy → itself, sized
  → `.sessions`), so the projection's quantity takeoff ([9.7]) is transparent to
  the shape. The **context-fraction is read with `fraction ID`** (empty for a
  legacy/unsized entry — a caller never guesses one); `size ID` returns the class.
- **Absent file** = no estimates ratified yet — legal, validates trivially.
  Every ID not present reads as the **default**.

## The sizing rubric ([13.2])

At plan time the agent does not guess a bare integer — it judges what fraction of
a session's context budget a deliverable will occupy, through a fixed rubric (the
judgment is *which class*; the mapping to a fraction is deterministic, Rule 12):

| size class | fraction of the [9.2] occupancy budget |
| --- | --- |
| **light** | 0.35 |
| **medium** | 0.5 |
| **heavy** | 0.9 |
| **balloon** | **> 1 — not a class; SPLIT, never stored** |

`bash .claude/estimate.sh rubric` emits this map as data. The fractions are the
dogfooded anchors (session-007's manual sizing of the Phase-13 deliverables). A
**balloon** — a deliverable that would exceed one session's budget — has no stored
estimate: it is **split** into deliverables that each fit one session, so "one
deliverable ≈ one session" holds *by construction* and the projection's quantity
half stays honest. `set-sized` **refuses** a `balloon` (and any unknown class)
rather than letting an `N > 1` estimate slip in. [13.3] reads the stored fraction
as `occupancy_budget = fraction × the [9.2] setpoint`, the base of its
`occupancy × turns` structural rate.

## The default, and balloons

The default estimate is **1**. guv pushes deliverables toward
session-sized work, so a 1 is the unremarkable case and needs no ratification
event of its own (a deliverable with no entry reads as 1). A residual legacy
entry **above 1** is a **balloon** — flagged by `.claude/estimate.sh balloons`
so it surfaces for the person to split. Under the rubric ([13.2]) a balloon is
never *stored* as `N > 1` in the first place — it is split at plan time — so this
list is the back-compat surface for plans sized before the rubric existed.

## How estimates are proposed and ratified

Estimates are acquired at **plan time**, in the **same confirm gate** as the
plan itself — the planner is already reading the wording and acceptance
criteria, so it **sizes each deliverable through the rubric** (light/medium/heavy,
splitting any balloon) and the person ratifies the sizing alongside the plan:

- **`/plan`** sizes each generated deliverable through the rubric and records the
  ratified set with `estimate.sh set-sized` after the plan's confirm.
- **`/replan` insert** sizes the new deliverable through the rubric **inside the
  same confirmation** that approves the insert, then `set-sized`s it — the tracker
  mutation and the sidecar write are one ratification, two files.

The helper is deterministic (Rule 12): it reads, writes, and validates, and maps a
size class to its fraction; the judgment (which class, the conversation) stays in
the commands.

## Interface (`.claude/estimate.sh`)

| Command | Effect |
| --- | --- |
| `default` | print the default estimate (`1`) |
| `get ID [SIDECAR]` | the **sessions** integer for `ID` (both forms), or the default if unrecorded (read-only) |
| `fraction ID [SIDECAR]` | the context-fraction for `ID`; **empty** for a legacy/unsized entry (read-only) |
| `size ID [SIDECAR]` | the rubric class for `ID` (`light`/`medium`/`heavy`); empty if unsized (read-only) |
| `rubric` | emit the size → fraction map as JSON (the documented rubric, as data) |
| `set ID N [SIDECAR]` | ratify `ID → N` (legacy, `N` integer ≥ 1); creates the sidecar; refuses out-of-shape |
| `set-sized ID SIZE [SIDECAR]` | ratify `ID` via the rubric (`light`/`medium`/`heavy`); **refuses `balloon`** (split it) |
| `validate [SIDECAR]` | check the sidecar against this shape (both forms); exit 5 MALFORMED |
| `list [SIDECAR]` | emit the sidecar JSON (sorted), `{}` when absent |
| `balloons [SIDECAR]` | the IDs whose **sessions** exceed the default (residual legacy N>1) |

`SIDECAR` defaults to `docs/estimates.json` (the same default-and-override
convention the resolver and `/replan` engine use for the tracker). Pure bash +
jq; no new runtime dependency.
