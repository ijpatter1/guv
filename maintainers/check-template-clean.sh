#!/bin/bash
# maintainers/check-template-clean.sh
# CI guard: fail (exit 1) if a project-shell (L3) artifact is TRACKED in the
# template repo. The dogfooding split (see DOGFOODING.md) keeps shell artifacts
# in the control plane by construction; this is the deterministic backstop that
# catches one sneaking into a commit anyway.
#
# Only tracked state counts — presence via `git ls-files`, content via the index
# (`git show :file`) — so untracked scratch (review docs, .DS_Store, a local
# rendered CLAUDE.md) and unstaged working-tree edits never fail the guard, and
# it is safe to run locally mid-session. A staged violation fails before it is
# ever committed.
#
# Run: bash maintainers/check-template-clean.sh   (any cwd inside the repo)
set -u

cd "$(git rev-parse --show-toplevel)" || exit 2

violations=0
flag() { echo "✗ $1"; violations=$((violations + 1)); }
tracked() { git ls-files --error-unmatch "$1" >/dev/null 2>&1; }
# Tracked files under a directory, minus that directory's own .gitkeep placeholder.
tracked_under() { git ls-files -- "$1" | grep -v "^$1\.gitkeep$"; }

# 1 — rendered CLAUDE.md (the template ships CLAUDE.template.md only).
tracked CLAUDE.md && \
  flag "CLAUDE.md is tracked — only CLAUDE.template.md ships; the rendered file belongs to a project"

# 2 — guv-friction log (belongs in the record).
FEEDBACK=$(tracked_under .claude/feedback/)
[ -n "$FEEDBACK" ] && \
  flag ".claude/feedback/ content is tracked ($(echo "$FEEDBACK" | tr '\n' ' ')) — feedback lives in the control plane"

# 3 — session handoffs (only the .gitkeep placeholder may be tracked).
SESSIONS=$(tracked_under docs/sessions/)
[ -n "$SESSIONS" ] && \
  flag "session artifacts tracked in docs/sessions/: $(echo "$SESSIONS" | tr '\n' ' ')"

# 4 — per-agent memory (gitignored, but the backstop must not rely on discipline).
MEMORY=$(tracked_under .claude/agent-memory/)
[ -n "$MEMORY" ] && \
  flag ".claude/agent-memory/ content is tracked ($(echo "$MEMORY" | tr '\n' ' ')) — agent memory is per-project, never shipped"

# 5 — personal settings overrides.
tracked .claude/settings.local.json && \
  flag ".claude/settings.local.json is tracked — personal overrides never ship"

# 6 — UAT artifacts (generated per-project by the phase machinery).
UAT=$(tracked_under docs/uat/)
[ -n "$UAT" ] && \
  flag "UAT artifacts tracked in docs/uat/: $(echo "$UAT" | tr '\n' ' ')"

# 7 — archived initiatives (frozen per-project phase docs from /plan).
INITIATIVES=$(tracked_under docs/initiatives/)
[ -n "$INITIATIVES" ] && \
  flag "archived initiative docs tracked in docs/initiatives/: $(echo "$INITIATIVES" | tr '\n' ' ')"

# 8 — rendered project README. A rendered README carries the STATUS markers as
# standalone lines; the template's own README may mention them mid-line in
# prose, and README.template.md legitimately contains them.
if tracked README.md && git show :README.md | grep -q '^<!-- STATUS:START'; then
  flag "README.md carries a rendered STATUS block — the template's own README must not"
fi

# 9 — docs/ must stay placeholders (filled-in docs are a project's, not the template's).
placeholder() {  # $1 = file, $2 = placeholder string that must still be present
  tracked "$1" || return 0
  git show ":$1" | grep -qF "$2" || \
    flag "$1 no longer contains the '$2' placeholder — looks filled in for a real project"
}
placeholder docs/REQUIREMENTS.md  "[PROJECT NAME]"
placeholder docs/ARCHITECTURE.md  "[PROJECT NAME]"
placeholder docs/PHASE_STATUS.md  "[Phase Name]"

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "Template repo is carrying project-shell artifacts. Route them to the control plane (see maintainers/DOGFOODING.md)."
  echo "(Consumer project repo, not the template? These artifacts are fine — delete maintainers/ and .github/workflows/template-clean.yml.)"
  exit 1
fi

echo "template clean: no project-shell artifacts tracked"
exit 0
