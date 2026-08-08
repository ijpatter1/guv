# UAT Plan Structure

The reference for the user-acceptance-testing plan that `handoff` Step 8 generates
when a phase completes. Step 8 keeps only the phase-complete trigger, the forecast
bank, and the inlined `confirm()` human-judgment gate, and points here for the rest
— so the handoff procedure stays short enough to remain resident (this structure is
needed only on the comparatively rare phase-completion path). Read this file when
Step 8 tells you to generate the UAT plan.

## Automation-first hierarchy

Follow the same automation-first hierarchy as `/guv:manual` — automate what can be
automated, fall back to human guidance only where judgment is required:

1. **CLI tool or backend service →** a UAT script at `docs/uat/phase-N-uat.sh`. It
   sets up prerequisites, runs each scenario, pauses for human observation where
   visual verification is needed, collects pass/fail results, and prints a summary.
   Use the `verify()` pattern from the `/guv:manual` script template for mechanical
   checks, and the `confirm()` helper (defined inline in handoff Step 8) for steps
   requiring human judgment.
2. **Web UI →** a UAT script that automates setup and verification where possible
   and uses `confirm()` prompts for visual/interactive checks. Include `open`
   commands to launch the relevant pages; structure it as a guided walkthrough —
   the human follows along while the script manages state and collects results.
3. **Purely manual to test →** a UAT task card at `docs/uat/phase-N-uat.md` with
   numbered scenarios, each carrying steps, expected outcomes, and pass/fail
   checkboxes. This is the last resort.

## UAT artifact structure

Whether script or card, each UAT plan covers:

- **Header stamp (UNVETTED by construction)** — author a default QA line into the
  artifact *as you generate it*, before the vet runs: `# QA: UNVETTED — not yet vetted`
  in a script's header comment block, `**QA:** UNVETTED — not yet vetted` in a `.md`
  card's metadata (the same default the `/guv:manual` templates ship). This makes the
  [18.2] G4 backstop real **by construction**, not merely asserted: a skipped or
  failed vet still ships a *visibly* un-vetted artifact rather than one that reads as
  silently passed. The vet below overwrites this default line with the real verdict.
- **Prerequisites** — what must be running, configured, or seeded before testing.
- **Scenarios** — numbered end-to-end workflows, each exercising multiple
  deliverables together. Each scenario states a name and what it validates, steps
  (automated where possible, guided where not), expected outcomes with concrete
  checks, and which deliverables it exercises.
- **Edge cases** — at least 2–3 scenarios testing boundaries, error states, or
  non-obvious flows.
- **Results summary** — pass/fail (and skip) counts with a clear overall verdict.

## After generating

Make the script executable if applicable:

```bash
chmod +x docs/uat/phase-N-uat.sh
```

### Vet the generated plan (calibrated, by name)

The `reviewer` generated these scenarios, so vet them with an **independent** second eye:
invoke the **`evaluator`** subagent **by name** (calibrated test-quality scrutiny, retained
until [32.3] for exactly this vet; ad-hoc verifiers remain prohibited — Rule 14) to judge
the UAT for soundness —
do the scenarios exercise the deliverables end-to-end, are the `verify()` checks real, do
the `confirm()` gates ask genuine human-judgment questions. The evaluator vetting what the
reviewer wrote is the point: independent of the generator, never the same agent grading
its own work.

**Routing is by artifact class, deliberately.** Every UAT vet goes to the `evaluator`
regardless of the plan's form — an executable `.sh` script *or* a tier-3 prose `.md`
card. Spike S3 left a dominant-nature refinement open (a prose UAT card "leans
reviewer"); it is resolved here to **class-based routing** — a UAT is a test-quality
surface whatever its form, the evaluator is its calibrated eye, and one matched vet keeps
the latency bounded (Rule 7: the choice is made, not blended). For a prose `.md` card
(no `verify()`/`confirm()` constructs to judge) point the evaluator at scenario coverage,
edge-case completeness, and whether each scenario's expected outcome is a concrete check
— and stamp the `.md` form (`qa-stamp.sh` selects `**QA:**` by extension automatically).

This vet is **declared-not-gated** — the Rule-15 exit-0 rung: a NEEDS WORK verdict does
**not** block the handoff. The session still exits 0 and the plan ships labelled with its
verdict, the human deciding whether to act before accepting the phase. Do **two** things
with the verdict, never one:

1. **Record it** in the handoff artifact under **Issues & Technical Debt** — the verdict,
   the findings, and the reviewer name — the written record a person reads later.
2. **Stamp it** on the artifact with the canonical helper (one source of the stamp format,
   idempotent — it overwrites the script's default `# QA: UNVETTED` line in place):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/qa-stamp.sh docs/uat/phase-N-uat.sh pass guv:evaluator "0 findings"
   # On NEEDS WORK, locate the findings in the NOTE so a reader of the stamp can find them:
   bash "${CLAUDE_PLUGIN_ROOT}"/scripts/qa-stamp.sh docs/uat/phase-N-uat.sh needs-work guv:evaluator "N findings — see handoff Issues & Technical Debt"
   ```

If the vet **cannot run** (the evaluator is unavailable), do **not** present the plan as
passed: degrade **loudly** to UNVETTED — recorded and stamped — so the unvetted state is
visible, never a silent pass.

```bash
bash "${CLAUDE_PLUGIN_ROOT}"/scripts/qa-stamp.sh docs/uat/phase-N-uat.sh unvetted guv:evaluator "evaluator unavailable"
```

Because the header stamp is authored UNVETTED by construction (see *UAT artifact
structure* above), an un-vetted plan is **visibly** un-vetted even when the vet is skipped
or cannot run — never a plan that silently reads as passed.

Note under **Next Steps** in the handoff artifact that UAT is ready to run:

```
1. Run Phase N UAT: `bash docs/uat/phase-N-uat.sh`
2. [Next phase planning — if UAT passes]
```

The phase is not accepted until UAT passes; the next session's `/guv:phase` checks for
UAT results before starting new phase work.
