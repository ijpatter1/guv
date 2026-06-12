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
| **deps-amend** | a deliverable's `[deps: …]` token changes | `reword` |
| **reorder** | the must-follow edges between deliverables change | `reword` on each affected token |
| **split** | one deliverable becomes several | `reword` the original to its narrowed scope + `insert` the carved-out parts |
| **merge** | several deliverables collapse into one | `reword` the absorbing deliverable + `descope` the absorbed (note: "merged into [N.M]") |

If the request doesn't fit a verb, say which interpretations are possible and ask —
don't silently pick. Note that wording-only fixes that change neither scope nor deps
are still mutations of synced wording: route them as `deps-amend`-style rewords (the
record's deps detail will simply be absent).

Two structural rules have no verb because they are not operations: **deletion does
not exist** (descope/abandon mark ❌ and the line survives), and **completed phases
refuse mutation** (the engine enforces this; history is immutable — errata about
finished work belong in a new deliverable, not a rewrite).

## Step 2 — Draft

Read the grammar section of the phase-docs skill (`.claude/skills/phase-docs/SKILL.md`,
"Tracker grammar") if it isn't already in context. Then draft the full mutation:

- **For an insert:** query the ordinal first — `bash .claude/replan.sh next-ordinal <phase>` —
  then draft the complete deliverable wording: leading `**[N.M]**`, scope, trailing
  `` `[deps: …]` `` expressing its *logical* position (the line always lands at the
  phase's end; deps carry the sequence). Draft its `- *Acceptance:*` sub-bullet for
  REQUIREMENTS too.
- **For a descope/abandon:** draft the note — why it's leaving, and where its scope
  went if anywhere.
- **For a reword (deps-amend, reorder, split, merge):** draft the new wording from
  leading ID through trailing token. The ID never changes.
- Check the target is mutable before going further: `bash .claude/replan.sh guard <ID-or-phase>`.

## Step 3 — Confirm

Present the drafted mutation to the user — the verb, the IDs touched, and the exact
before/after wording (for deps changes, show old → new tokens) — and get explicit
approval. **This is a hard gate: no document is written before the user confirms.**
In headless mode, a prompt that itself specifies the exact mutation is the
confirmation; anything less specific means stop and report instead of guessing.

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
   bash .claude/replan.sh reword  <session-id> <verb> <ID> '<full wording>'
   ```

   `<session-id>` is today's session (`session-YYYY-MM-DD-NNN`, matching the
   handoff naming). A composed verb makes several engine calls in its table order.
   If the engine refuses or rejects (exit 5/6), **stop and revert the REQUIREMENTS
   edit** — the docs move together or not at all; surface the engine's message.
3. **`docs/ARCHITECTURE.md`** — update only where the mutation touches recorded
   architecture (a new component, a changed data flow); skip cleanly otherwise.

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
- Spec-alignment gaps found at session start route here too (`/start-phase` Step 5
  detects and routes; this command mutates).
