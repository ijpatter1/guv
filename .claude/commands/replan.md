Mutate the live plan through the one sanctioned door: classify the change, confirm it with the user, then apply it atomically across the three phase docs with an amendment record. $ARGUMENTS describes the change being requested.

## Step 0 — Preconditions

This command mutates phase docs, so it only applies in **`phased`** ceremony.
Read `ceremony` from `.claude/project.json`: in `task` or `onboard` mode, or when
`docs/PHASE_STATUS.md` doesn't exist, there is no plan to mutate — that's a mode
signal, not an error; say so and stop.

Run the resolver to load plan state:

```
bash .claude/resolve-ready.sh
```

- **Exit 5 (MALFORMED):** the tracker must be fixed before it can be mutated.
  Surface the named offenders and stop — repairing a malformed tracker is its own
  task, not a side effect of this one.
- **`mode=LEGACY`:** token-free trackers predate the DAG grammar and `/replan`
  does not apply; the engine will refuse them too. Explain that the grammar is
  opt-in by annotation (see the phase-docs skill, "Tracker grammar") and stop.

## Step 1 — Classify

Classify the requested change as exactly one verb:

| Verb | Meaning | Engine primitive(s) |
|---|---|---|
| **insert** | a new deliverable enters a phase | `insert` |
| **descope** | a deliverable leaves the plan (still might return someday) | `descope` |
| **abandon** | a deliverable leaves for good — the approach is dead | `descope` (records as abandon) |
| **deps-amend** | a deliverable's synced wording is amended in place — the deps token, the prose, or both | `reword` |
| **reorder** | the must-follow edges between deliverables change | `reword` on each affected token |
| **split** | one deliverable becomes several | `reword` the original to its narrowed scope + `insert` the carved-out parts |
| **merge** | several deliverables collapse into one | `reword` the absorbing deliverable + `descope` the absorbed (note: "merged into [N.M]") |

If the request doesn't fit a verb, say which interpretations are possible and ask —
don't silently pick. A wording-only fix that changes neither scope nor deps is still
a mutation of synced wording: it classifies as **deps-amend** (an in-place
amendment whose token happens not to move), and its record must say what changed —
pass the engine a one-line summary (the `reword` SUMMARY argument); the deps diff
is recorded automatically when the token did move.

Two structural rules have no verb because they are not operations: **deletion does
not exist** (descope/abandon mark ❌ and the line survives), and **completed phases
refuse mutation** (the engine enforces this; history is immutable — errata about
finished work belong in a new deliverable, not a rewrite). Granularity matters
here: a ✅ deliverable in an *open* phase can still be reworded (the amendment
record keeps the audit trail) but never descoped — done is done; only when its
whole phase completes does its wording freeze too.

## Step 2 — Draft

Read the grammar section of the phase-docs skill (`.claude/skills/phase-docs/SKILL.md`,
"Tracker grammar") if it isn't already in context. Then draft the full mutation:

- **For an insert:** query the ordinal first — `bash .claude/replan.sh next-ordinal <phase>` —
  then draft the complete deliverable wording: leading `**[N.M]**`, scope, trailing
  `` `[deps: …]` `` expressing its *logical* position (the line always lands at the
  phase's end; deps carry the sequence). Draft its `- *Acceptance:*` sub-bullet for
  REQUIREMENTS too. Also draft its **session estimate** ([9.6]): you are reading the
  scope and acceptance to draft the line anyway, so propose the estimate in the same
  breath — **default 1** (the harness pushes deliverables session-sized), and flag it
  as a **balloon** if the scope reads as multi-session. The estimate is *not* part of
  the wording and never enters the tracker — it rides the **sidecar**, keyed by ID
  (`.claude/estimate.shape.md`).
- **For a new phase (the section header):** the engine inserts *deliverables* but
  does **not** create the `## Phase N` header — it is the one tracker mutation the
  door does not own, so the header is a sanctioned structural edit you make by hand
  (in the main session, which is the single writer), REQUIREMENTS first then
  PHASE_STATUS, *before* the engine can insert `[N.1]…`. Match the canonical shape
  exactly so every consumer (resolver, sync-check, renderer) parses it — in
  PHASE_STATUS that is, with the blank lines that engine-era phases carry (the one a
  hand-edit drops — A-003):

  ```
  ## Phase N — Title

  _Goal: <one line>._

  - ⬜ **[N.1]** …
  ```

  REQUIREMENTS uses its own phase shape (`## Phase N — Title`, a `**Goal:**` line, a
  `**Deliverables:**` lead, then the numbered list). After the header is in place,
  insert each deliverable through the engine as above, then validate the whole
  tracker with `bash .claude/replan.sh sync-check` and the resolver — a malformed
  header surfaces there, loud, before the phase goes live.
- **For a descope/abandon:** draft the note — why it's leaving, and where its scope
  went if anywhere.
- **For a reword (deps-amend, reorder, split, merge):** draft the new wording from
  leading ID through trailing token. The ID never changes.
- Check the target is mutable before going further: `bash .claude/replan.sh guard <ID-or-phase>`.

## Step 3 — Confirm

Present the drafted mutation to the user — the verb, the IDs touched, and the exact
before/after wording (for deps changes, show old → new tokens) — and get explicit
approval. **For an insert, the drafted session estimate is ratified in this same
confirmation** ([9.6]): present it alongside the wording (default 1, balloons flagged),
so the deliverable *and* its estimate clear one confirm gate, exactly as
`/plan-initiative` does at plan time. **This is a hard gate: no document is written
before the user confirms.** In headless mode, a prompt that itself specifies the exact
mutation is the confirmation; anything less specific means **draft and defer** (the
Rule-15 designed degradation), never guess and never auto-apply: write the full
drafted mutation into the session handoff / report for later ratification, leave the
plan docs untouched, and proceed with the rest of the work. The mutation lands here,
through this gate, once a person is back to confirm it.

## Step 4 — Apply atomically, REQUIREMENTS first

The mutation order is fixed — wording changes happen in **REQUIREMENTS first**,
forever; the tracker syncs from it; ARCHITECTURE follows where touched:

1. **`docs/REQUIREMENTS.md`** — apply the wording change with Edit: the deliverable
   line (numbered list, verbatim wording including ID and deps token) and its
   acceptance sub-bullets.
2. **`docs/PHASE_STATUS.md`** — apply the same change through the engine (never by
   hand; the engine validates the result with the resolver and writes atomically,
   appending the amendment record):

   ```
   bash .claude/replan.sh insert  <session-id> <verb> '<full wording>'
   bash .claude/replan.sh descope <session-id> <verb> <ID> '<note>'
   bash .claude/replan.sh reword  <session-id> <verb> <ID> '<full wording>' '' '<what changed>'
   ```

   `<session-id>` is today's session (`session-YYYY-MM-DD-NNN`, matching the
   handoff naming). In the reword line, the `''` is the TRACKER argument left
   at its default, and `<what changed>` is the one-line record summary for
   wording-only amendments (the deps diff records automatically when the
   token moved). A composed verb makes several engine calls in its table order.
   If the engine refuses or rejects (exit 5/6), **stop and revert the REQUIREMENTS
   edit** — the docs move together or not at all; surface the engine's message.
3. **`docs/ARCHITECTURE.md`** — update only where the mutation touches recorded
   architecture (a new component, a changed data flow); skip cleanly otherwise.
4. **The estimate sidecar** ([9.6], inserts only) — record the estimate the user
   ratified in Step 3, through the helper and **never** through the tracker engine:

   ```bash
   bash .claude/estimate.sh set <ID> <N>   # the ratified estimate; default N is 1
   ```

   Estimates are **interpretation**, not evidence: they live in the sidecar
   (`docs/estimates.json`), keyed by ID, **never in a tracker line or token**. This
   is by design — an estimate edit costs no grammar change, no contract change, and
   **leaves the tracker byte-identical**, which is exactly why the estimate does *not*
   pass through `replan.sh` (the tracker-mutation engine never sees it). A descope,
   abandon, or reword does not touch estimates — only an insert acquires one; an
   estimate revision is a bare `estimate.sh set`, no `/replan` needed.

## Step 5 — Verify and report

1. Verify the verbatim-sync contract on every touched ID:

   ```
   bash .claude/replan.sh sync-check <ID>
   ```

   Non-zero means tracker and REQUIREMENTS drifted mid-apply — fix before reporting.
2. Re-run `bash .claude/resolve-ready.sh` and present the new frontier — a plan
   mutation exists to change what's ready, so show what it changed.
3. Report: the verb, the amendment record line(s) as written, the docs touched, and
   the old → new frontier. Commit as `docs(replan): <verb> [IDs] — <one-line why>`.

## Reminders

- One operation per confirmation. A batch of unrelated changes is several `/replan`
  invocations, each with its own gate.
- The engine owns the deterministic half (ordinals, guards, records, validation,
  atomic writes); your half is judgment — classification, wording, deps reasoning,
  and the conversation. Don't re-implement either half in the other's lane.
- Atomicity is mechanical for the tracker (the engine validates before it writes;
  a rejected mutation changes nothing) and procedural across the three docs — the
  fixed order, the revert-on-refusal rule, and Step 5's `sync-check` are what hold
  the tri-doc set together. Skipping Step 5 forfeits the detector.
- Spec-alignment gaps found at session start route here too (`/start-phase` Step 5
  detects and routes; this command mutates).
