# Projection — shape ([9.7])

The **projection** is guv's estimate of the **cost to complete** the live
initiative: a **range** carrying a **basis claim** and a **scope claim**. It is
the consuming surface that joins the [9.6] estimate sidecar (the quantity), the
[9.1] metering log (the observed rate), and the [9.2] occupancy threshold (the
rate ceiling) into one forward-looking number. The helper `.claude/projection.sh`
is the only producer; the shape joins the tracker grammar, the manifest schema,
the metering-log shape, and `status.json` as **published contract surface**.

## It is computed at n=0 and ever after — there is no refusal state

The projection always answers. With zero landings it stands on the **structural
spine** alone — the user's *own plan and guv*, never anyone's history. As
landings accrue, local observed rates **blend in** and correct the structural
assumption in flight. The structure is never discarded; history is a **weighted
input**, never the foundation.

## The structural spine = a quantity takeoff × a unit rate

Both halves are derived **locally** — from this control plane's plan and guv,
never from foreign history.

### Quantity — ratified sessions over remaining work

```
remaining_sessions = Σ  estimate(d)   for d in remaining work
```

- **Remaining work** comes from the resolver (`resolve-ready.sh --json`): every
  **open** deliverable, selected by the per-deliverable status the resolver
  emits — `todo` (⬜) + `in_progress` (🔄) + `human_gated` (🔒). The resolver
  never emits a per-deliverable status of `blocked` (`blocked` is a *frontier*
  classification — a ⬜ with an unsatisfied dep — not a deliverable status), so a
  ⬜ is counted as open whether or not its deps are satisfied. The projection
  consumes the resolver's published JSON and **never re-parses the tracker** (the
  one-parser discipline, A-001).
- **`estimate(d)`** is the ratified per-deliverable session estimate from the
  [9.6] sidecar (`docs/estimates.json`). A deliverable with **no ratified
  estimate** projects at the **default (1)** and is **DISCLOSED** in
  `spine.quantity.default_estimate_ids` — the range's honesty depends on naming
  which legs leaned on the default.

### Unit rate — the session envelope (floor measured, ceiling a setpoint)

```
floor_tokens    = tokenize(CLAUDE.md + .claude/rules/*.md)     # MEASURED
ceiling_tokens  = occupancy.threshold  (else window-relative default)  # SETPOINT
```

- The **floor** is the *fixed overhead* a session carries — measured by
  tokenizing the actual control-plane docs a session loads (the rendered
  `CLAUDE.md` plus the natively-loaded `.claude/rules/*.md`). Tokenization is the
  deterministic **chars/4** heuristic (Rule 12 — a transform, not a model call).
  If no doc is readable the floor degrades to a documented minimum (Rule 15), so
  the spine never collapses to zero.
- The **ceiling** is the [9.2] occupancy threshold — the manifest setpoint
  `occupancy.threshold` if present, else the same window-relative default the
  [9.2]/[10.6] meter ships (¾ of the standard 200 000-token window = 150 000).
  Floor is measured evidence; ceiling is a tunable setpoint.
- The floor is **bounded above by the ceiling**: a measured fixed overhead that
  exceeds the occupancy setpoint (a degenerate heavy-doc / low-threshold config)
  is **clamped** to the ceiling, so the band can never invert
  (`low_tokens <= high_tokens` always holds).

### The range

```
range.low_tokens  = remaining_sessions × blended_low_tokens    # n=0: floor_tokens
range.high_tokens = remaining_sessions × blended_high_tokens   # n=0: ceiling_tokens
range.denomination = "tokens"
```

The blended band-edge rates are **emitted** in `spine.unit_rate`
(`blended_low_tokens`, `blended_high_tokens`) alongside the centre
(`blended_tokens`) and the raw structural `floor_tokens`/`ceiling_tokens`, so the
document is **self-reconcilable**: a reader can derive the range from the
projection's own published fields (`range.low_tokens == remaining_sessions ×
spine.unit_rate.blended_low_tokens`). At n=0 the blended edges equal the
structural floor/ceiling, so the structural relationship still reads off directly.

At `n = 0` the band is purely structural — the tight session (floor) to the
full-window session (ceiling), an **occupancy** band. As landings accrue the band
**edges migrate toward observed throughput** by the same blend weight as the
centre (low edge → observed min, high edge → observed max; see *The local
blend*), so the reported range and the central blended rate stay in the **same
unit and the same universe**. This is the BUG-3 correction: occupancy is a
point-in-time *stock* (bounded by the window) but cost-to-complete is cumulative
session *throughput* (the four classes summed across every turn, cache_read-
dominated, unbounded) — a static floor..ceiling band left the throughput-scale
central rate sitting orders of magnitude **outside** its own occupancy-scale
range. Blending the band edges keeps the document coherent: the centre always
lies inside its band. **Denomination follows Spike C's rung — tokens — never a
guessed dollar conversion** (pricing tables drift; the spec forbids the guess,
exactly as the [9.1] meter keeps `dollars` null).

## The local blend

As landings accrue in **this** control plane's metering log, the observed
per-session rate blends into the central unit rate:

```
observed_{mean,min,max} = {mean,min,max}( per-session total token burn )  over the local log
weight           = n / (n + K)        K = 3 (smoothing)
blended_tokens   = (1 − weight) × floor   + weight × observed_mean    # the centre
blended_low_rate = (1 − weight) × floor   + weight × observed_min     # the band low edge
blended_high_rate= (1 − weight) × ceiling + weight × observed_max     # the band high edge
```

- `n` is the count of **local** landings (metering entries with harvested
  tokens). At `n = 0` the weight is 0 — `blended_tokens == floor_tokens`, the
  band is `floor..ceiling`, the spine is purely structural.
- The **same weight** drives the centre and **both band edges**, so the whole
  band is corrected in-flight, not just the centre. With `floor ≤ ceiling`
  (clamped) and `min ≤ mean ≤ max`, the band never inverts and the centre always
  lies inside it.
- The **weight rises monotonically** with the sample count and never reaches 1 —
  the structure always retains some pull. More samples → more weight on observed
  → the blended rate (and band) move further toward the observed burn.
- The blend reads **only the local metering log**. The arithmetic is plain
  (mean + a count-based weight), not a model call.

## Confinement — ONLY local artifacts, never foreign history

The projection's **entire input set** is this control plane's own files:

| input | path (default) | role |
| --- | --- | --- |
| metering log | `.claude/metering/metering.ndjson` | observed-rate blend (local landings) |
| estimate sidecar | `docs/estimates.json` | quantity takeoff |
| calibration record | `.claude/metering/calibration.ndjson` | banked forecasts + grades |
| tracker (via resolver) | `docs/PHASE_STATUS.md` | remaining-work set |

There is **no path to another project's history** — no home-global crawl, no
cross-project glob, no network fetch. The [9.1] harvest reaches into the runtime
transcript to *capture* tokens; the projection never does — it consumes the
already-harvested **local** log. The suite **grep-asserts** this against the code
paths.

## Banked forecasts and close-time grading

Every projection can be **banked** — appended as a `kind:"forecast"` line to the
calibration record (append-only NDJSON, like the metering log). At initiative
close, **grading** compares the banked forecast against the outcome and emits
**two separable errors** so a miss **names its layer**:

- **quantity error** — `estimated_sessions` (the forecast's takeoff) vs
  `actual_sessions` (distinct sessions in the local metering log occurring
  **after the forecast was banked** — the takeoff was remaining work from bank
  time forward, so the actual count is bounded to post-bank sessions to keep the
  comparison like-for-like).
- **rate error** — `envelope_tokens` (the forecast's floor) vs
  `actual_tokens_per_session` (the mean per-session burn over the **post-bank**
  sessions — the same like-for-like bound as the quantity layer: the envelope was
  set against the work the forecast covers, so the rate is compared only against
  post-bank burn). The grade's bound is symmetric with `actual_sessions`; only the
  GRADE comparison is bounded — the live projection blend reads the full observed
  history.

The grade is banked back (`kind:"grade"`) so the **local** calibration record
learns from the close.

## `/replan` follows by recomputation

A `/replan` change to remaining work or estimates is **not special-cased**: the
next `project` re-reads the tracker (via the resolver) and the sidecar, and the
range follows. A deps-amend that adds remaining work raises the next
projection's quantity and grows its range — purely by recomputation.

## Interface (`.claude/projection.sh`)

| Command | Effect |
| --- | --- |
| `project` | emit the projection JSON document to stdout (**read-only**) |
| `bank` | compute the projection and **append** it as a forecast to the calibration record |
| `grade` | close-time: grade the latest banked forecast, emit the two-error grade, and bank it |

All three accept `--tracker`, `--log`, `--sidecar`, `--calibration`, and `--root`
overrides; defaults are root-relative (cwd = the project root, the sibling
convention every guv spine script carries). Pure bash + jq; no new runtime
dependency.
