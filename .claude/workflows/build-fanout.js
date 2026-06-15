export const meta = {
  name: 'build-fanout',
  description: 'Run the calibrated dual-review GATE over already-built fan-out lanes — the evaluator and reviewer grade each lane BY NAME against its acceptance bundle; returns structured per-lane verdicts. The build half and the fix loop stay conversational; the deterministic JOIN (lane-dispatch.sh) lands what passes.',
  whenToUse: 'After lane builders have executed (one per deliverable, red/green TDD in guv-lane worktrees) and before the lane-dispatch JOIN. Pass the lane ids to gate (e.g. "10.1 10.2 10.3", or an array). Findings are fixed conversationally in the main session, then re-run for the next pass.',
  phases: [
    { title: 'Gather', detail: 'per lane: merge-queue gate-input acceptance bundle + diff' },
    { title: 'Gate', detail: 'evaluator + reviewer per lane, by name, concurrent' },
  ],
}

// This is the GATE half of a build fan-out — the build-half analog of eval-parallel.js.
// A fan-out has three drivers (the lane-dispatch.sh header names them): the EXECUTION
// (one lane-builder per lane, conversational, red/green TDD) → THIS GATE (calibrated
// dual review per lane) → the deterministic JOIN (lane-dispatch.sh dispatch, lands what
// passed). The seam: the gate decides, dispatch lands.
//
// Like eval-parallel, the FIX loop is deliberately NOT here: workflow subagents run in
// acceptEdits mode, which conflicts with the conversational fix-and-re-gate gate, and
// the spec's posture is a conversational build half + single-writer join. Apply findings
// conversationally in the main session, then re-run this workflow for the next pass.
// Convergence criterion: a lane lands only once all Critical/Major findings are closed.
//
// Both gate stages spawn the CALIBRATED project agents BY NAME (Rule 14 in
// .claude/rules/guv-workflows.md — ad-hoc reviewers prohibited). agentType resolves the
// calibrated definition (.claude/agents/ on a template install; the namespaced agents
// under a plugin install), so each runs with its own tool set + read-only hook.
//
// DISCLOSED ([7.1] non-routing): workflow scripts get no path rewrite in the plugin
// build, so the gather agent resolves the merge-queue helper at runtime (.claude/ for a
// template/source install, ${CLAUDE_PLUGIN_ROOT}/scripts/ under a plugin) rather than a
// hardcoded path that would be dead in one mode.

const GATHER_SCHEMA = {
  type: 'object',
  required: ['laneId', 'ok', 'deliverable', 'laneBranch', 'footprint', 'acceptance', 'diffStat'],
  properties: {
    laneId: { type: 'string', description: 'the lane / deliverable id gathered' },
    ok: { type: 'boolean', description: 'true if the lane + deliverable resolved and the bundle assembled; false if not (then explain in deliverable)' },
    deliverable: { type: 'string', description: 'one line: what this deliverable is (or the failure reason if ok=false)' },
    laneBranch: { type: 'string', description: 'the lane branch + head, or "" if unresolved' },
    footprint: { type: 'string', description: 'the lane footprint (files/insertions/deletions), or ""' },
    acceptance: { type: 'string', description: 'the deliverable acceptance criteria block from docs/REQUIREMENTS.md (what counts as good), verbatim' },
    diffStat: { type: 'string', description: 'the lane diff stat against the integration branch — what the lane changed' },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['report', 'weightedScore', 'verdict', 'criticalCount', 'majorCount', 'minorCount'],
  properties: {
    report: { type: 'string', description: 'the FULL structured report in your output format, unsoftened — the report itself, not a pointer' },
    weightedScore: { type: 'number', description: 'the weighted score out of 5' },
    verdict: { type: 'string', description: 'PASS | PASS WITH ISSUES | FAIL (evaluator) or PASS | NEEDS WORK (product)' },
    criticalCount: { type: 'integer' },
    majorCount: { type: 'integer' },
    minorCount: { type: 'integer' },
  },
}

// The lane↔join responsibility split — given to BOTH reviewers so neither grades a
// JOIN-owned step as a lane defect (the calibration bug observed during the Phase-10
// fan-out: source-only lanes were flagged Critical for plugin/ not being regenerated,
// which is the join's job, not the lane's).
const SPLIT = `RESPONSIBILITY SPLIT — grade accordingly. This is ONE lane of a fan-out.
- The LANE owns SOURCE only: red/green TDD confined to its worktree.
- The JOIN (lane-dispatch.sh, run AFTER this gate) owns the derived plugin/ tree (rebuilt at the join), the drift battery, and the assembly of shared prose (CHANGELOG/README) from docFragments.
So do NOT flag as a lane defect: a missing plugin/ rebuild, a prose delta routed through a docFragment instead of a direct edit, or any other join-owned step. Grade the lane's SOURCE work against its acceptance criteria. The two of you must not contradict on this split.`

// ── parse the lane list (single- and multi-lane both drive) ──
const laneIds = (typeof args === 'string'
  ? args.trim().split(/[\s,]+/)
  : Array.isArray(args) ? args.map(String) : []
).filter(Boolean)

if (!laneIds.length) {
  return { error: 'No lane ids given — pass the lanes to gate (e.g. "10.1 10.2", or an array). Lanes must already be built (one lane-builder per deliverable) before the gate runs.' }
}
log(`Build-fanout gate over ${laneIds.length} lane(s): ${laneIds.join(', ')}`)

// Each lane runs the whole gather→gate chain independently (pipeline: no barrier — a
// fast lane gates while a slow one is still gathering).
const perLane = await pipeline(
  laneIds,
  // ── Gather: assemble the acceptance bundle (Rule 12: code assembles, model grades) ──
  (id) => agent(
    `Assemble the dual-review bundle for fan-out lane "${id}" — this mirrors the deterministic merge-queue gate-input.
Resolve the guv merge-queue helper: use ".claude/merge-queue.sh" if it exists (template/source install), else "\${CLAUDE_PLUGIN_ROOT}/scripts/merge-queue.sh" (plugin install). Run: bash <that path> gate-input ${id}
It prints the deliverable id, the lane branch + head, the footprint, and the acceptance criteria block from docs/REQUIREMENTS.md. Also capture the lane's diff stat (its source changes) for the reviewers — resolve the lane branch from the gate-input output and diff it against the integration branch (the code repo's checked-out HEAD).
Return the structured bundle. If the lane or deliverable can't be resolved, set ok=false and put the reason in "deliverable".`,
    { label: `gather:${id}`, phase: 'Gather', schema: GATHER_SCHEMA }
  ),
  // ── Gate: evaluator + reviewer, by name, concurrent, with the responsibility split ──
  (bundle, id) => {
    if (!bundle || !bundle.ok) {
      return { laneId: id, gathered: false, reason: bundle ? bundle.deliverable : 'gather failed' }
    }
    const context = `Fan-out lane: ${id}
Deliverable: ${bundle.deliverable}
Lane: ${bundle.laneBranch}
Footprint: ${bundle.footprint}

${SPLIT}

--- acceptance criteria (what counts as good) ---
${bundle.acceptance}

--- the lane's diff (its source changes) ---
${bundle.diffStat}

Your final structured output must carry the FULL report — do not stash findings in files and return a summary.`
    return parallel([
      () => agent(
        `Evaluate fan-out lane "${id}" — run your full evaluation procedure (Functionality, Test Quality, Code Quality, Completeness, Integration) against the acceptance below.\n\n${context}`,
        { label: `evaluator:${id}`, phase: 'Gate', agentType: 'evaluator', schema: REPORT_SCHEMA }
      ),
      () => agent(
        `Review fan-out lane "${id}" for product quality against the acceptance below and the product vision in docs/REQUIREMENTS.md. Run your full review (Vision Alignment, User Experience, Content Quality, Feature Depth).\n\n${context}`,
        { label: `reviewer:${id}`, phase: 'Gate', agentType: 'reviewer', schema: REPORT_SCHEMA }
      ),
    ]).then(([tech, product]) => {
      // Convergence (code, Rule 12 — arithmetic is not a judgment call): a lane is
      // CLEAR to land only when no Critical/Major finding remains across both reviews.
      const critical = (tech?.criticalCount ?? 0) + (product?.criticalCount ?? 0)
      const major = (tech?.majorCount ?? 0) + (product?.majorCount ?? 0)
      const minor = (tech?.minorCount ?? 0) + (product?.minorCount ?? 0)
      const bothReturned = Boolean(tech && product)
      return {
        laneId: id,
        gathered: true,
        evaluator: tech ? { score: tech.weightedScore, verdict: tech.verdict, report: tech.report } : null,
        reviewer: product ? { score: product.weightedScore, verdict: product.verdict, report: product.report } : null,
        critical, major, minor,
        // Clear to land only if both reviews returned AND no Critical/Major remains.
        clearToLand: bothReturned && critical + major === 0,
      }
    })
  }
)

// ── summary (code, not a third agent) ──
const results = perLane.filter(Boolean)
const clear = results.filter(r => r.gathered && r.clearToLand).map(r => r.laneId)
const held = results.filter(r => r.gathered && !r.clearToLand).map(r => r.laneId)
const ungathered = results.filter(r => !r.gathered).map(r => r.laneId)
const summary = [
  '═══ Build-fanout Gate Summary ═══',
  '',
  `Lanes gated: ${results.length}`,
  `Clear to land (no Critical/Major): ${clear.length ? clear.join(', ') : 'none'}`,
  `Held (fix + re-gate): ${held.length ? held.join(', ') : 'none'}`,
  ungathered.length ? `Did not gather: ${ungathered.join(', ')}` : null,
  '',
  held.length
    ? 'Action: fix the held lanes IN-LANE, conversationally in the main session (the fix loop is not in this workflow — acceptEdits conflicts with it), then re-run this workflow. A lane lands through lane-dispatch only once all Critical/Major are closed.'
    : 'Action: all gated lanes are clear — hand the clear set to the lane-dispatch JOIN to land (the gate decides, dispatch lands).',
].filter(x => x !== null).join('\n')

return { summary, perLane: results }
