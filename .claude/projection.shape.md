# Projection — published shapes (`guv.projection.v2`, [9.7]/[13.4], cut at [32.4])

`projection.sh project` emits one JSON document: **observed-rate ×
sized-remaining**, nothing else. The modeled occupancy×turns band, the blend,
and their constants were deleted at [32.4]; at n=0 the rate and forecast are
honest nulls, never a structural fallback. History of the retired model and the
unit seams it was fitted across: `.claude/metering-log.md` and git history.

## `guv.projection.v2` (project / the payload bank appends)

| field | meaning |
|---|---|
| `schema` | `guv.projection.v2` |
| `generated` | ISO-8601 UTC instant |
| `rate` | `{n, mean, min, max, denomination:"tokens_per_session"}` — the observed per-session burn over the local metering log: **post-epoch** (`guv.meter.epoch.v1` — entries after the last epoch line only) `per_response` bounded slices (`per_deliverable` / `since_process_start`), windowed to the [13.4] lineage boundary. **`null` at n=0**, the designed disclosure. |
| `quantity` | `{sized_remaining, defaulted_ids}` — Σ sessions × the [13.2] light/medium/heavy fraction over the resolver's open set (⬜ + 🔄 + 🔒). An id with no ratified fraction (absent from the sidecar, or a legacy integer estimate) contributes sessions × 1.0 and is listed in `defaulted_ids`. |
| `forecast` | `{central, low, high, denomination:"tokens"}` = `sized_remaining` × `rate.{mean,min,max}`, rounded. **`null` at n=0.** |
| `basis` | `{sample_window, sample_selection}` — the lineage boundary the samples were windowed to (`null` when nothing is banked yet) and the selection rule, so an n=0 is legible. |
| `scope` | `{claim}` — cost to complete **remaining** work, never total. |

## The calibration record (`.claude/metering/calibration.ndjson`, append-only)

`bank` appends `{kind:"forecast", banked_at, boundary?, banked_session}` + the
document above. `banked_session` is the newest `docs/sessions/` artifact at bank
time — the session-record position the grade's denominator counts from.
Idempotent per named boundary per initiative (a `grade` line closes the window).

`grade` emits and appends `guv.projection.grade.v2`:

| field | meaning |
|---|---|
| `graded_forecast` | `{boundary, banked_at}` — the lineage entry read: the opening `plan` forecast, degrading to the last banked. |
| `quantity_error` | `{estimated_session_equivalents, actual_sessions, delta_sessions, denominator_source}`. The denominator is the **session record** — every `docs/sessions/` artifact after `banked_session` counts, metered or not ([28.1]); `denominator_source:"metering_log"` marks the legacy degradation (a v1 forecast with no stamp). |
| `rate_error` | `{forecast_tokens_per_session, actual_tokens_per_session, delta_tokens}` — the banked mean vs the post-bank observed mean, same sample selection as the live rate. |

Legacy `guv.projection.v1` forecasts still grade: the estimate side falls back
to `.spine.quantity.remaining_sessions` / `.spine.unit_rate.blended_tokens`.

## Wiring ([13.4])

The lifecycle commands own the calls — `/plan` banks `--at plan` and grades at
initiative close; `/handoff` banks at each phase boundary (`--at phase-N`)
(guv:-namespaced under a plugin install). `budget-gate.sh` no longer reads the
projection: the [13.5] foreseen-overrun declaration retired at [32.4].
