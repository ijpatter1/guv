# UAT Plan Structure

The reference for the user-acceptance-testing plan that `handoff` Step 8 generates
when a phase completes. Step 8 keeps only the phase-complete trigger, the forecast
bank, and the inlined `confirm()` human-judgment gate, and points here for the rest
— so the handoff procedure stays short enough to remain resident (this structure is
needed only on the comparatively rare phase-completion path). Read this file when
Step 8 tells you to generate the UAT plan.

## Automation-first hierarchy

Follow the same automation-first hierarchy as `/manual` — automate what can be
automated, fall back to human guidance only where judgment is required:

1. **CLI tool or backend service →** a UAT script at `docs/uat/phase-N-uat.sh`. It
   sets up prerequisites, runs each scenario, pauses for human observation where
   visual verification is needed, collects pass/fail results, and prints a summary.
   Use the `verify()` pattern from the `/manual` script template for mechanical
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

Note under **Next Steps** in the handoff artifact that UAT is ready to run:

```
1. Run Phase N UAT: `bash docs/uat/phase-N-uat.sh`
2. [Next phase planning — if UAT passes]
```

The phase is not accepted until UAT passes; the next session's `/phase` checks for
UAT results before starting new phase work.
