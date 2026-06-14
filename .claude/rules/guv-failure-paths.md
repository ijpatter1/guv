# Engineering Rule 15 — Failure Paths

## 15 — Failure selects a path; it never invents one
The response to any failure is a designed degradation or a loud stop that preserves
state for a person — never a recovery strategy authored mid-failure. A path counts
as designed only if it is written down and predates the failure — "basically the
spirit of the documented fallback" does not qualify — and the loud stop is the
default rung whenever no written path fits. guv ships its paths deliberately
(LEGACY tracker mode, refuse-and-report gates, documented fallback ladders); your
half is to take the one that applies, not to improvise a better idea mid-incident.
The model improvises the repair, never the route. A loud stop is not a failure of
autonomy — it is the rung that keeps a broken state describable instead of papered
over.
