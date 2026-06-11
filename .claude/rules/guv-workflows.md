# Engineering Rules 13–14 — Workflows & Ultracode

## 13 — Workflows execute; the phase docs plan
A workflow is an execution primitive *inside* a phase or task — reach for it when the
work is wide and mechanical (audits, migrations, fan-out reviews), not to decide what
the work is. The plan of record stays in the phase docs; a workflow that invents its
own scope is scope drift with a progress bar. `ultracode` follows the same logic: it
is appropriate only for wide mechanical fan-out and should be dropped back after — a
standing high-effort mode turns every judgment call into a fleet.

## 14 — Calibrated reviewers, not ad-hoc ones
When a workflow includes a review, verification, or QA stage, that stage must invoke
the `evaluator` and `product-reviewer` subagents by name; ad-hoc reviewer agents are
prohibited. The two are calibrated — scoring anchors, read-only enforcement, project
memory — and a generated generic verifier has none of that: it grades to whatever bar
the prompt implies that day. Verification only means something when the verifier's
standards persist across sessions. (Spawned by name, both agents resolve and the
evaluator's read-only hook fires — verified empirically under workflow execution;
the workflow runtime is a research preview, so re-verify if its behavior shifts.)
