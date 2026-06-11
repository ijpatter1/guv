export const meta = {
  name: 'evaluate-parallel',
  description: 'Dual QA review over a commit-range scope — the evaluator and product-reviewer run concurrently; returns both reports plus the combined summary',
  whenToUse: 'After completing a feature or before handoff, when both calibrated reviewers should run at once. Scope via args (e.g. "last 3 commits"); default is work since the last handoff. The fix loop stays conversational — apply fixes in the main session, then re-run.',
  phases: [
    { title: 'Scope', detail: 'commit range, changed files, current phase' },
    { title: 'Review', detail: 'evaluator + product-reviewer, concurrent, by name' },
  ],
}

// Mirrors the /evaluate skill's Steps 1-4. Step 5 — the fix loop — is deliberately
// NOT in this workflow: workflow subagents always run in acceptEdits mode, which
// conflicts with the conversational fix-and-re-evaluate gate. Fix in the main
// session, then re-run this workflow for the next pass.
//
// Both review stages spawn the CALIBRATED project agents by name (rule 14 in
// .claude/rules/guv-workflows.md — ad-hoc reviewers are prohibited). agentType
// resolves the .claude/agents/ definition, so the evaluator runs with its own
// restricted tool set (Read/Glob/Grep/Bash) and its read-only PreToolUse hook,
// which fires under workflow execution (verified empirically — Phase 4 spike).

const SCOPE_SCHEMA = {
  type: 'object',
  required: ['phase', 'commits', 'filesChanged', 'scopeDescription'],
  properties: {
    phase: { type: 'string', description: 'current phase number/name from docs/PHASE_STATUS.md, or "unknown"' },
    commits: { type: 'array', items: { type: 'string' }, description: 'commits in scope as "hash subject", oldest first' },
    filesChanged: { type: 'array', items: { type: 'string' }, description: 'paths changed across the scope' },
    scopeDescription: { type: 'string', description: 'one line: what is being evaluated' },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['report', 'weightedScore', 'verdict', 'criticalCount', 'majorCount', 'minorCount'],
  properties: {
    report: { type: 'string', description: 'the FULL structured report in your specified output format, unsoftened — the report itself, not a pointer to it' },
    weightedScore: { type: 'number', description: 'the weighted score out of 5' },
    verdict: { type: 'string', description: 'PASS | PASS WITH ISSUES | FAIL (evaluator) or PASS | NEEDS WORK (product)' },
    criticalCount: { type: 'integer' },
    majorCount: { type: 'integer' },
    minorCount: { type: 'integer' },
  },
}

// ── Step 1 — gather the evaluation scope ──
phase('Scope')
const scopeHint = typeof args === 'string' && args.trim() ? args.trim() : null
const scope = await agent(
  `Gather the evaluation scope for a dual QA review (this mirrors the /evaluate skill's Step 1).
${scopeHint
    ? `The user scoped the evaluation: "${scopeHint}". Resolve that to concrete commits.`
    : 'No explicit scope was given: evaluate all work since the last session handoff (latest file in docs/sessions/) or the last evaluation, whichever is more recent.'}
Run git against the code repo: git -C "$(jq -r '.roots.code' .claude/project.json)" log/diff/show (a no-op for single-repo, where roots.code is ".").
Read the current phase from docs/PHASE_STATUS.md.
Collect: the phase, the commits in scope (oldest first), the files changed across them, and a one-line description of what is being evaluated.`,
  { label: 'scope', phase: 'Scope', schema: SCOPE_SCHEMA }
)
if (!scope || !scope.commits.length) {
  return { error: 'No commits in scope — nothing to evaluate. Commit the work first, or scope explicitly (e.g. /evaluate-parallel last 3 commits).' }
}
log(`Scope: ${scope.scopeDescription} (${scope.commits.length} commits, ${scope.filesChanged.length} files)`)

// ── Steps 2 + 3 — both calibrated reviewers, concurrently ──
phase('Review')
const context = `Phase ${scope.phase}. Commits in scope (oldest first):
${scope.commits.join('\n')}
Changed files:
${scope.filesChanged.join('\n')}

Your final structured output must carry the FULL report — do not stash findings in agent memory or files and return a summary.`

// Barrier justified: Step 4's combined summary needs both reports together.
const [tech, product] = await parallel([
  () => agent(
    `Evaluate the following work from Phase ${scope.phase}. Run your full evaluation procedure — Functionality, Test Quality, Code Quality, Completeness, and Integration.\n\n${context}`,
    { label: 'evaluator', phase: 'Review', agentType: 'evaluator', schema: REPORT_SCHEMA }
  ),
  () => agent(
    `Review the following work from Phase ${scope.phase} for product quality. Review against the product vision in docs/REQUIREMENTS.md and any content guides referenced in CLAUDE.md. Run your full review — Vision Alignment, User Experience, Content Quality, and Feature Depth.\n\n${context}`,
    { label: 'product-reviewer', phase: 'Review', agentType: 'product-reviewer', schema: REPORT_SCHEMA }
  ),
])

if (!tech || !product) {
  // Fail loud (rule 10): half a review is not a review — never summarize over a
  // missing report.
  return {
    error: 'A reviewer did not return a report — evaluation incomplete, do not proceed on a half review.',
    evaluatorReport: tech ? tech.report : null,
    productReviewerReport: product ? product.report : null,
  }
}

// ── Step 4 — combined summary, computed in code (rule 12: arithmetic is not a
// judgment call, so no third agent) ──
const critical = tech.criticalCount + product.criticalCount
const major = tech.majorCount + product.majorCount
const minor = tech.minorCount + product.minorCount
const action = critical + major + minor > 0
  ? 'fix and re-evaluate — conversationally, in the main session (/evaluate Step 5), then re-run this workflow'
  : 'proceed ✓'
const summary = [
  '═══ Evaluation Summary (parallel) ═══',
  '',
  `Technical:  ${tech.weightedScore}/5 — ${tech.verdict}`,
  `Product:    ${product.weightedScore}/5 — ${product.verdict}`,
  '',
  `Critical issues: ${critical || 'none'}`,
  `Major issues:    ${major || 'none'}`,
  `Minor issues:    ${minor || 'none'}`,
  '',
  `Action:  ${action}`,
].join('\n')

return {
  summary,
  evaluatorReport: tech.report,
  productReviewerReport: product.report,
}
