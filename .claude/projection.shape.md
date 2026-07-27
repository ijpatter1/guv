# Projection — shape ([9.7]; throughput-native unit model [12.1]; occupancy×turns structural prior [13.3]; auto-banked into the lifecycle [13.4])

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
expected_turns          = { base_build: 115, low: 115, central: 470, high: 1963 }  # base_build + eval/fix term
structural_low_tokens   = occupancy_budget × expected_turns.low                # 115   (clean run)
structural_tokens       = occupancy_budget × expected_turns.central            # 470   (typical eval/fix, 115 + 355)
structural_high_tokens  = occupancy_budget × expected_turns.high               # 1963  (fix-heavy, 115 + 1848)
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
  and turns `115/470/1963` give structural `36.8M / 150.4M / 628.16M` — bracketing the
  observed per-session envelope (≈37M–628M) from outside, around a central that
  reproduces the forensic mean (≈150M). ([15.6] widened the tails; the central is
  byte-unchanged from [13.3].)
  - **Calibration vs measurement** (which inputs are evidence, which are modeled): the
    forensic deltas independently ground the **working-set fraction** (≈0.375 observed,
    rounded to 0.4) and the **token band**. `expected_turns` is the **fitted free
    parameter** — `turns_central` is chosen so `occupancy_budget × turns` reproduces the
    forensic *mean* (320 000 × 470 = 150.4M; the forensics' own main-only estimate is
    ~360 inferences/session, of which 470 is the subagent-inclusive analog). The base/eval
    **split** (115 + 355/1848) and the band **spread** are a **modeling assumption** shaped
    to bracket the ≈37M–628M envelope; [13.1]'s now-in-scope subagent burn grounds the
    *direction* (fix-heavy sessions cost more), not the exact turn counts. A measured
    per-session inference-count distribution would refine the split — the exact reconcile
    lands the *product* on the evidence, not three independently measured factors.
  - **What unit that evidence is in** ([28.4]). Three axes separate the band's evidence
    from the burn this rate is added to. The first two are measured; the third is not:
    - **Vintage — `pre-dedupe`.** The forensic deltas were differenced from *naive
      per-line* usage sums, i.e. **pre-[9.1]**, which over-counted **~2.55x** in
      aggregate.
    - **Denomination — a `raw` four-class count.** `input + output + cache_read +
      cache_creation`, each weighted 1. **Not cost-weighted** (the base-input-equivalent
      unit a [9.3] ceiling may be chosen in, where `cache_read` ×0.1, `cache_creation` ×2,
      output ×5). The two differ by **3.9–6.8x** on guv's own record, and that ratio moves
      with a session's output/cache mix — no fixed conversion exists ([28.5] carries the
      gate-side hazard).
    - **Model — unquantified.** Every pre-fix entry in the log is `claude-opus-4-8` or
      `claude-fable-5`; every post-fix entry, including all three check samples below, is
      `claude-opus-5`. The vintage boundary is also a model boundary with **zero overlap**,
      and a per-session token rate depends on turn count, subagent use and cache behaviour
      — all plausibly model-dependent. [28.3] is the deliverable that measures this; until
      it lands, any old-vs-new comparison here is confounded.
  - **A deflator is arithmetically admissible — the earlier claim that it was not is
    withdrawn** ([28.4]). An earlier framing (and the pre-[28.4] text of this file) said no
    divisor could reconcile the vintages because the [9.1] error is *shape-dependent*,
    citing ≈1.04x subagent vs ≈3.20x main-loop. Those are **output-class** ratios, and
    output is **under 1%** of a session's burn — `cache_read` is 97–98%. Measured on the
    quantity that actually matters, all-class burn, `metering-log.md` records the spread as
    **2.65x main-loop vs 2.27x subagent** (2.31–2.88x across 18 reconstructed entries,
    weighted 2.53x; corpus-wide 2.49x / 2.35x), and states that **a single ~2.55x deflator
    recovers every one of them to within ±13%**. Per Rule 7 that measured finding wins over
    the older framing, which is corrected here rather than left to contradict it.
    What still blocks *using* a deflator on **this band** is narrower and worth stating
    exactly: the deflator was measured against surviving transcripts in the **metering
    log's** corpus, not the older forensic corpus this band was fitted to, and those
    transcripts do not survive. Applying it here is inference, not measurement — and it
    would carry the unquantified model axis with it.
  - **The post-fix check, and the retention decision** ([28.4]). Checked against the
    unit-correct record: **n = 3** `per_response` sessions in the live initiative,
    measuring **46 375 417 / 54 215 374 / 166 622 133** tokens (mean **89 070 974**,
    median **54 215 374**, a 3.6× spread). Two exclusions, both deliberate: pre-`[9.1]`
    entries are the wrong vintage, and the window's one
    `slice_basis = unbounded_cumulative` entry is a session scalar, not a burn slice.
    Three estimates of the same quantity, and **two of the three sit well below the
    retained central**:

    | estimate | value | vs central 150.4M |
    |---|---|---|
    | forensic mean, deflated ~2.55x | ≈59M (52–65M over the deflator spread) | 2.5× lower |
    | post-fix measured mean (n=3) | 89.07M | 1.69× lower |
    | post-fix measured median (n=3) | 54.2M | 2.77× lower |

    The band **contains all three observations** — but note that is a weak test: at
    36.8M–628.16M the band spans **17×** and would contain almost any plausible session.
    The ratios above, not containment, are the signal.

    **All four constants are nonetheless RETAINED, and this prior should be read as
    known-high rather than validated.** Moving the central means re-deriving the whole
    band — the central is the fitted product `occupancy_budget × 470`, and both tails were
    separately fitted by [15.6] to bracket the observed envelope — across a model boundary
    nobody has measured yet. Note also what the check can and cannot reach: it constrains
    the **product**, so `WORKING_SET_FRACTION` is not separately re-examined here and
    cannot be — the fraction and the turn counts appear only multiplied together (the
    "calibration vs measurement" note above makes the same point about the original
    fit). Fitting to n=3 at a 3.6× spread, or to a deflated figure whose deflator was
    measured on a different corpus, would bake that confound into the coefficients. **The cost of retaining is real and is not hidden:** at n=3 the emitted
    blended rate is **119.7M**, **+34%** above the observed mean, and `blended_high` is
    **397.4M**, **2.4×** the largest session ever measured post-fix. That inflates the
    published cost-to-complete range and biases the operator's extend / harvest / accept
    call toward extend. **Revisit trigger:** re-derive when **[28.3] lands** (it removes
    the model confound), when **n ≥ 10** post-fix sessions accumulate, or when the central
    leaves the band **0.5×–2× the post-fix mean** in *either* direction. None of these is
    enforced by code — they are conditions for a person to evaluate; the suite pins the
    constants against today's measurement so a silent move reds, which is not the same
    thing as watching the evidence move.
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
  tokens) that survive **two filters**, both applied before any arithmetic. At
  `n = 0` the weight is 0 — each edge **is** its structural occupancy×turns
  anchor, the spine is purely structural (a real modeled band).
  - **Vintage** — only entries harvested in the current unit
    (`harvest_basis: "per_response"`, written after the [9.1] dedupe fix). An
    **absent** key is pre-fix by construction and overstates burn (~2.55x in
    aggregate; the spread across work shapes is **2.27x–2.65x** on all-class burn,
    so the mixing is what makes a cross-vintage average meaningless — *not* an
    inability to deflate, see the [28.4] note above). An **explicit
    `null`** is a degraded harvest of unknown unit, and unknown degrades to *not
    a sample*, never to an assumed one. Averaging across the vintage boundary
    produces a rate in **no unit at all**.
  - **Lineage window** — only entries at or after the live initiative's boundary
    (the last `grade`, else the opening `plan` forecast in the calibration
    record). This is the **same window `budget-gate.sh` sums burn over**, and it
    must be: the cost-to-complete computed here is *added* to that windowed burn
    and compared against that initiative's setpoint. Reading every initiative's
    history built one initiative's forecast out of another's sessions.
  - **Legacy** entries (pre-[13.6] cumulative snapshots, no `slice_basis` key)
    are pre-fix by construction — [13.6] predates the dedupe fix — so the vintage
    filter excludes them and [13.6]'s read-time differencing is **gone from this
    reader**. `budget-gate.sh` still differences them and must: **burn**
    legitimately sums every entry in the window in whatever unit it was recorded
    and then discloses the mix; a **rate** cannot, because an average across two
    units is not a number.
- `basis.sample_window` (ISO-8601 string, or `null` when nothing is banked yet)
  and `basis.sample_vintage` (`"per_response"`) **disclose where the n samples
  came from**. Without them an `n = 0` is unreadable: "no sessions yet" and
  "sessions exist but none in this unit or window" are different claims that lead
  to different decisions. A `null` window is the **opening forecast's own case** —
  no boundary is banked when the first ceiling is set, so the whole log is read
  (prior initiatives' post-fix sessions are the only signal available, and they
  are unit-correct) and the absence is stated rather than silently implied.
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
calibration record (append-only NDJSON, like the metering log).

([13.4]) Banking is **wired into the lifecycle**, not left to a manual call — the
projection is banked **when made**, at three boundaries the skills run as documented
steps (the `meter.sh capture` convention, not a hook):

- **`/plan` (or `/init` greenfield) → `bank --at plan`** — the **opening
  forecast** (n=0 structural), the cost to complete the whole new initiative. The
  greenfield door banks against default estimates (disclosed) since it does not yet
  ratify per-deliverable sizing (a [13.2] follow-up).
- **`/handoff` phase-completion → `bank --at phase-<N>`** — a **gradeable
  mid-initiative forecast**, the landings so far folded into the blend.
- **`/plan` initiative close → `grade`** (before archival) — the close-time settlement.

The `--at <boundary>` token tags the forecast with its boundary — the **lineage key**.
Banking at a boundary is **idempotent**: re-banking the **same** boundary is a no-op
(re-invoking `/plan`, or re-running a phase-completion handoff, never double-banks),
while a **different** boundary appends (the lineage accrues, one forecast per boundary).
A bank with **no `--at`** is unconditionally appended — the manual escape hatch,
untagged and identical to the legacy shape. The dedup window is **this initiative**: a
`grade` line marks a close, so a new initiative's `--at plan` re-banks rather than
colliding with the predecessor's `plan` forecast still in the accumulating ledger.

At initiative close, **grading** reads the forecast **lineage** and grades the
**opening (plan-boundary) forecast** — its scope was the whole remaining initiative,
which is what a close-time grade honestly grades ("how good was the plan?"), not the
last phase-boundary snapshot (closest to actual, least informative). It degrades to
the most recent forecast when none was banked at `plan` (a legacy record, or manual
banks, Rule 15). The grade **names the lineage entry it read** in `graded_forecast`
(`{boundary, banked_at}`), so "the grade reads the lineage" is visible in the grade
itself. It then emits **two separable errors** so a miss **names its layer**:

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
learns from the close. Unlike a boundary forecast, the grade is **append-only and
not idempotent by design**: it is an *outcome measurement*, not a banked forecast —
re-running it after more sessions have landed legitimately yields a *different*
grade, and the record honestly accrues each measurement. (The bank dedup window keys
on the **latest** `grade` line, so an extra grade only reopens the next initiative's
window — it never corrupts the lineage.) The per-boundary idempotency the acceptance
requires is a property of `bank`, not `grade`.

## `/replan` follows by recomputation

A `/replan` change to remaining work or estimates is **not special-cased**: the
next `project` re-reads the tracker (via the resolver) and the sidecar, and the
range follows. A deps-amend that adds remaining work raises the next
projection's quantity and grows its range — purely by recomputation.

## Interface (`.claude/projection.sh`)

| Command | Effect |
| --- | --- |
| `project` | emit the projection JSON document to stdout (**read-only**) |
| `bank [--at B]` | compute the projection and **append** it as a forecast to the calibration record; `--at B` tags the boundary (the lineage key) and makes the bank **idempotent** per boundary ([13.4]) |
| `grade` | close-time: read the lineage, grade the **opening (plan-boundary)** forecast (degrading to the latest), emit the two-error grade naming the entry read, and bank it ([13.4]) |

All three accept `--tracker`, `--log`, `--sidecar`, `--calibration`, and `--root`
overrides; `bank` additionally accepts `--at <boundary>` (the lifecycle boundary the
forecast is banked at — e.g. `plan`, `phase-9`). Defaults are root-relative (cwd = the
project root, the sibling convention every guv spine script carries). Pure bash + jq;
no new runtime dependency.
