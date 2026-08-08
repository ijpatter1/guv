# Engineering Rules 13–14 — Workflows & Ultracode

## 13 — Workflows execute; the phase docs plan
A workflow is an execution primitive *inside* a phase or task — reach for it when the
work is wide and mechanical (audits, migrations, fan-out reviews), not to decide what
the work is. The plan of record stays in the phase docs; a workflow that invents its
own scope is scope drift with a progress bar. `ultracode` follows the same logic: it
is appropriate only for wide mechanical fan-out and should be dropped back after — a
standing high-effort mode turns every judgment call into a fleet.

## 14 — Platform review first; one calibrated alignment reviewer
Technical review belongs to the platform: the `code-review` skill, session-invoked
with an explicit target and level (`/code-review` typed at high effort is the
operator's audit posture) — verified findings, calibrated upstream, no scoring
apparatus of ours to maintain. guv
adds the one dimension the platform cannot: the `reviewer` subagent (`guv:reviewer`
under a plugin install) grades alignment against the spec and vision — findings, not
scores — spawned **by name**, worktree-isolated, with project memory. Ad-hoc generated
reviewer agents remain prohibited: a generic verifier grades to whatever bar the
prompt implies that day, and its standards persist nowhere. Recurring mechanical
patterns graduate to tests; judgment patterns persist in the reviewer's memory.
(S2/S3, spec-2026-07-31; the dual-eval apparatus retired at [32.1].)
