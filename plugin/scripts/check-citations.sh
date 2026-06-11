#!/bin/bash
# .claude/check-citations.sh
# ADVISORY integrity check: flag session-handoff citations whose commit hashes no
# longer resolve. Always exits 0 — it never blocks anything.
#
# WHY THIS EXISTS (and when it runs):
# In a control-plane split (roots.code != roots.control), session artifacts in
# docs/sessions/ cite commit hashes that live in a *separate* history. A rebase or
# force-push in the code repo can leave a handoff citing a hash that no longer
# resolves — an old handoff that "lies" months later. This catches that.
# It NO-OPS in single-repo (roots.code == roots.control): the artifact and the
# commits it cites share one history, so a rewrite moves both together and there is
# nothing to verify. The check activates ONLY in the split configuration that needs it.
#
# POSTURE: read-time, advisory. Wired into /status (where artifacts are read), not
# /handoff (where they're written; /guv:-namespaced forms under the plugin). Mirrors stop-check.sh — a reminder, not a gate.
#
# WHICH HASHES ARE FLAGGED: a token is flagged only if it resolves in NEITHER the
# code repo NOR the control plane. Split-mode handoffs legitimately cite BOTH (code
# commits for product history, control commits for doc/session history — see the
# session-management skill), so checking only the code repo would flag every valid
# control-plane citation. Requiring "resolves in neither" suppresses those and leaves
# only genuinely-dangling references.
#
# CAVEATS (advisory tolerates these — this is deliberately NOT a citation parser):
#   - False positives: any 7–40 hex whole-word token is treated as a candidate, so
#     non-commit hex (PR/issue refs, other-repo SHAs, UUID fragments, color codes)
#     that resolves in neither repo may be flagged. Skim past noise.
#   - False negatives: tokens longer than 40 hex (e.g. SHA-256 object ids) are not
#     matched; abbreviations under 7 chars are not matched.
#
# Usage: bash .claude/check-citations.sh   (run from the control plane / cwd)

MANIFEST=".claude/project.json"
[ -f "$MANIFEST" ] || exit 0

CODE=$(jq -r '.roots.code // "."' "$MANIFEST" 2>/dev/null || echo ".")
CONTROL=$(jq -r '.roots.control // "."' "$MANIFEST" 2>/dev/null || echo ".")

# No-op in single-repo: one shared history, nothing to verify.
[ "$CODE" = "$CONTROL" ] && exit 0

SESSIONS="${CONTROL%/}/docs/sessions"
[ -d "$SESSIONS" ] || exit 0

# The code repo must actually be a git repo, or there's nothing to verify against.
git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Is the control plane its own git repo? If so, a cited hash that resolves there is a
# legitimate control-plane (doc/session) citation, not a dangling code reference.
CONTROL_IS_GIT=0
git -C "$CONTROL" rev-parse --git-dir >/dev/null 2>&1 && CONTROL_IS_GIT=1

# resolves <repo-root> <token> → exit 0 if the token resolves to a commit there.
resolves() { git -C "$1" rev-parse --verify --quiet "${2}^{commit}" >/dev/null 2>&1; }

# Collect session files (nullglob so an empty dir yields an empty list, not a literal).
shopt -s nullglob
FILES=("$SESSIONS"/*.md)
[ ${#FILES[@]} -gt 0 ] || exit 0

REPORT=""
for f in "${FILES[@]}"; do
  # Hash-shaped tokens: 7–40 hex chars, whole-word (-w is portable across BSD/GNU grep).
  # sort -u so a hash repeated within one file is checked and reported once.
  TOKENS=$(grep -owE '[0-9a-fA-F]{7,40}' "$f" 2>/dev/null | sort -u)
  [ -z "$TOKENS" ] && continue
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    # Resolves in the code repo → fine (product citation).
    resolves "$CODE" "$tok" && continue
    # Resolves in the control plane → fine (doc/session citation).
    [ "$CONTROL_IS_GIT" -eq 1 ] && resolves "$CONTROL" "$tok" && continue
    # Resolves in neither → dangling.
    REPORT+="  $(basename "$f"): $tok"$'\n'
  done <<< "$TOKENS"
done

if [ -n "$REPORT" ]; then
  echo "[citation-check] Session artifacts cite commit hashes that resolve in NEITHER the code repo ($CODE) nor the control plane:"
  printf '%s' "$REPORT"
  echo "[citation-check] Advisory only — a rebase/force-push may have rewritten them, or they were never commit hashes (any 7–40 hex token is checked). Verify before relying on them."
fi

exit 0
