# Projection — shape ([9.7]; throughput-native unit model [12.1]; occupancy×turns structural prior [13.3])

The **projection** is guv's estimate of the **cost to complete** the live
initiative: a **range** carrying a **basis claim** and a **scope claim**. It is
the consuming surface that joins the [9.6] estimate sidecar (the quantity) and the
[9.1] metering log (the observed **throughput** rate) into one forward-looking
number. ([12.1]) The cost unit is cumulative session **throughput**, not
point-in-time occupancy. ([13.3]) Occupancy returns only as a modeled **factor** —
the structural per-session rate is `occupancy_budget × expected_turns`, the
cumulative-flow reconstruction of the point-in-time occupancy stock — never as the
cost itself; the raw [9.2] occupancy threshold stays an informational reference.
The helper `.claude/projection.sh` is the only producer; the shape joins the tracker
grammar, the manifest schema, the metering-log shape, and `status.json` as
**published contract surface**.

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

### Unit rate — throughput, modeled as occupancy × turns ([13.3])

```
occupancy_budget_tokens = max( occupancy_reference × 2/5 , floor_tokens )      # the modeled working set
expected_turns          = { base_build: 220, low: 220, central: 470, high: 1090 }  # base_build + eval/fix term
structural_low_tokens   = occupancy_budget × expected_turns.low                # 220   (clean run)
structural_tokens       = occupancy_budget × expected_turns.central            # 470   (typical eval/fix)
structural_high_tokens  = occupancy_budget × expected_turns.high               # 1090  (fix-heavy)
floor_tokens               = tokenize(CLAUDE.md + .claude/rules/*.md)          # INFORMATIONAL lower bound
occupancy_reference_tokens = occupancy.threshold (else window-relative default)  # INFORMATIONAL setpoint
```

The cost unit is cumulative session **throughput** — the burn the [9.1] meter
captures (input + output + cache_read + cache_creation summed across every turn,
the unit a [9.3] budget is set in). The crucial distinction ([12.1]): **occupancy
is a point-in-time _stock_** (the window working set, bounded by the window);
**throughput is cumulative _flow_** (unbounded, cache_read-dominated, in practice
orders of magnitude larger). Conflating them was BUG 3.

([13.3]) The structural per-session rate **reconstructs the flow from the stock**: a
session re-reads ≈ its working set on every inference, so cumulative flow ≈
`occupancy_budget × expected_turns`. Occupancy is back — but as a **modeled factor**,
never as the cost itself.

- **`occupancy_budget`** = the [9.2] setpoint's *working set* — the **average**
  point-in-time occupancy over a session, empirically **≈ 0.4× the setpoint** (a
  session sits below the calm ceiling most of its life; `meter-forensics.md` B4), not
  the full ceiling. It is **clamped up to the measured floor** as a true lower bound,
  so a tiny or absent setpoint degrades to the floor rather than collapsing the rate
  to zero (Rule 15).
- **`expected_turns`** = `base_build + an eval/fix term`, where "turns" are
  **inferences/session** (hundreds — the granularity at which cumulative flow
  accrues). The eval/fix term's **distribution sets the band**: the **low** edge is
  `base_build` alone (a **clean run**, no fix iterations), the **high** edge adds the
  **fix-heavy** eval/fix loop. At the real 800k setpoint, `occupancy_budget = 320 000`
  and turns `220/470/1090` give structural `70.4M / 150.4M / 348.8M` — in the forensic
  band (≈70–350M/session, mean ~150M).
  - **Calibration vs measurement** (which inputs are evidence, which are modeled): the
    forensic deltas independently ground the **working-set fraction** (≈0.375 observed,
    rounded to 0.4) and the **token band**. `expected_turns` is the **fitted free
    parameter** — `turns_central` is chosen so `occupancy_budget × turns` reproduces the
    forensic *mean* (320 000 × 470 = 150.4M; the forensics' own main-only estimate is
    ~360 inferences/session, of which 470 is the subagent-inclusive analog). The base/eval
    **split** (220 + 250/870) and the band **spread** are a **modeling assumption** shaped
    to the 70–350M envelope; [13.1]'s now-in-scope subagent burn grounds the *direction*
    (fix-heavy sessions cost more), not the exact turn counts. A measured per-session
    inference-count distribution would refine the split — the exact reconcile lands the
    *product* on the evidence, not three independently measured factors.
- The **floor** (the *fixed overhead* a session loads at least once — tokenizing the
  rendered `CLAUDE.md` plus the natively-loaded `.claude/rules/*.md`, the deterministic
  **chars/4** heuristic, Rule 12) and the raw **occupancy reference** ([9.2] threshold,
  else the ¾-of-200 000 = 150 000 default) are carried as **informational** fields.
  The threshold **never clamps the measured floor** (the pre-[12.1] occupancy-as-ceiling
  coupling stays retired); it feeds the rate **only** through `occupancy_budget`.

### The range

```
range.low_tokens  = remaining_sessions × blended_low_tokens    # n=0: structural_low_tokens
range.high_tokens = remaining_sessions × blended_high_tokens   # n=0: structural_high_tokens
range.denomination = "tokens"
```

The blended band-edge rates are **emitted** in `spine.unit_rate`
(`blended_low_tokens`, `blended_high_tokens`) alongside the centre
(`blended_tokens`), the modeled `structural_{low,,high}_tokens`,
`occupancy_budget_tokens` + `expected_turns`, and the informational `floor_tokens`
and `occupancy_reference_tokens`, so the document is **self-reconcilable**: a
reader can derive the range from the projection's own published fields
(`range.low_tokens == remaining_sessions × spine.unit_rate.blended_low_tokens`).

At **`n = 0`** (no throughput history) the band is the **modeled occupancy×turns
band** — a *real* band `remaining_sessions × [structural_low, structural_high]`
(low **<** high, not a point), and the basis discloses `bound="modeled_range"`. This
**supersedes [12.1]'s `lower_bound_only`**: there is now a principled central
estimate (`structural_tokens`) and a genuine spread from the eval/fix term, instead
of a bare floor-anchored point — and still **no fabricated turn-count guess** (the
coefficients are calibrated from forensic evidence, the same no-guess discipline
that keeps [9.1]'s `dollars` null and forbids foreign history). As landings accrue
the band **edges migrate toward observed throughput** by the same blend weight as the
centre (low → observed min, high → observed max; see *The local blend*), and `bound`
becomes `"observed_range"` — the reported range and the central blended rate stay in
the **same unit (throughput) and the same universe**, the centre always inside its
band. **Denomination follows Spike C's rung — tokens — never a guessed dollar
conversion** (pricing tables drift; the spec forbids the guess, exactly as the [9.1]
meter keeps `dollars` null).

## The local blend

As landings accrue in **this** control plane's metering log, the observed
per-session rate blends into the central unit rate:

```
observed_{mean,min,max} = {mean,min,max}( per-session total token burn )  over the local log
weight           = n / (n + K)        K = 3 (smoothing)
blended_tokens   = (1 − weight) × structural_tokens      + weight × observed_mean   # the centre
blended_low_rate = (1 − weight) × structural_low_tokens  + weight × observed_min    # the band low edge
blended_high_rate= (1 − weight) × structural_high_tokens + weight × observed_max    # the band high edge
```

- `n` is the count of **local** landings (metering entries with harvested
  tokens). At `n = 0` the weight is 0 — each edge **is** its structural
  occupancy×turns anchor, the spine is purely structural (a real modeled band).
- ([13.3]) **Each edge anchors on its own structural occupancy×turns edge**
  (`structural_low/central/high`) and migrates toward the matching observed edge by
  the **same weight** — the centre toward the observed mean, the low/high edges
  toward observed min/max — so the whole band is corrected in-flight as one. Because
  the blend now corrects a **meaningful prior** (a throughput-scale central estimate,
  not the near-zero floor), it **converges from a sensible start** rather than
  dragging up from ≈0. With `structural_low ≤ structural_central ≤ structural_high`
  and `min ≤ mean ≤ max`, the per-edge blend stays ordered (the band never inverts)
  and the centre always lies inside it. (The raw occupancy threshold is **not** an
  anchor — it enters only through `occupancy_budget`.)
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
- **rate error** — `envelope_tokens` (the forecast's **blended central rate** — the
  throughput cost the forecast actually committed, [12.1]; falls back to the floor
  only for a legacy forecast banked before `blended_tokens` existed) vs
  `actual_tokens_per_session` (the mean per-session burn over the **post-bank**
  sessions — the same like-for-like bound as the quantity layer: the envelope was
  set against the work the forecast covers, so the rate is compared only against
  post-bank burn). Both sides are now in the same throughput unit (pre-[12.1] this
  graded the occupancy-scale floor against throughput — incoherent, the same
  stock-vs-flow mismatch the range had). The grade's bound is symmetric with
  `actual_sessions`; only the GRADE comparison is bounded — the live projection
  blend reads the full observed history.

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
