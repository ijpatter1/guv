#!/bin/bash
# .claude/hooks/bash-guard.sh
# PreToolUse hook for Bash commands — blocks dangerous patterns.
# Receives JSON on stdin with tool_input.command.
# Exit 0 = allow, JSON stdout with deny = block.
#
# SECURITY MODEL:
# This hook is the SEMANTIC layer of the three-layer model (README "Security Model"):
#   1. Isolation tier — the spatial boundary: the native sandbox (default tier;
#      OS-enforced filesystem/network limits) or the Docker sandbox + firewall
#      (opt-in tier)
#   2. This hook — the semantic boundary within it: the spatial boundary permits
#      writes anywhere in the working directory, so destructive patterns
#      (rm -rf ., hard resets to remotes, publishes) remain THIS hook's job in
#      BOTH tiers
#   3. settings.json permissions — convenience layer, auto-allow safe commands
#
# This hook runs identically in either tier (and with no tier at all) — it reads
# only the command string and the manifest, never the isolation environment.
#
# STACK-AGNOSTIC GUARDS:
# The blocked set is two parts:
#   - UNIVERSAL_BLOCKED — always on, true stack-agnostic core (destructive FS ops,
#     pipe-to-shell, hard reset to remote). Every project gets these.
#   - Optional guards keyed by name (gcp, npm-publish, cargo-publish, …), layered
#     on only when listed in the manifest's "guards" array. A Rust CLI carries no
#     GCP guards it will never trigger; a GCP project opts in via "guards":["gcp"].

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ─────────────────────────────────────────────
# SINGLE-WRITER TRACKER GUARD — agent_type-gated ([7.4]; closes the [7.3] gap)
# Only the MAIN session writes the plan-of-record trackers (single-writer.sh
# denies a subagent's Write/Edit/MultiEdit). This closes the Bash surface that
# hook leaves open — a subagent redirecting or streaming over the tracker.
# agent_type is non-empty ONLY inside a subagent, so the main writer passes
# through untouched (it never sets agent_type), and so does every read.
# Covered: the honest write shapes — output redirect, tee, in-place sed/perl/
# ruby, dd of=, copy/move ONTO the tracker, truncate. An adversarial subagent
# assembling an obscure write (a variable-built path, python open('w')) is out
# of scope HERE by design: the real boundary is that lane work commits to its
# own branch and lands through the gated merge queue — never to the tracker on
# main — inside the native sandbox. Plan mutation is /replan in the main session.
# ─────────────────────────────────────────────
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
if [ -n "$AGENT_TYPE" ]; then
  # A path prefix with no shell metachars, then a tracker filename. The trailing
  # literal backtracks past the prefix, so quoted and ./-prefixed paths match too.
  TRK='[^[:space:]>|&;]*docs/(PHASE_STATUS|REQUIREMENTS)\.md'
  TRACKER_WRITES=(
    '>>?[[:space:]]*'"$TRK"                                   # > / >> redirect onto the tracker
    '\btee\b[^|]*'"$TRK"                                       # tee writing the tracker
    '\bsed\b[^|]*-i[^|]*'"$TRK"                                # sed -i in place
    '\b(perl|ruby)\b[^|]*-i[^|]*'"$TRK"                        # perl/ruby -i in place
    '\bdd\b[^|]*of='"$TRK"                                     # dd of=tracker
    '\b(cp|mv|install)\b.*[[:space:]]'"$TRK"'[[:space:]]*$'    # copy/move ONTO it (target position)
    '\btruncate\b[^|]*'"$TRK"                                  # truncate the tracker
  )
  for pattern in "${TRACKER_WRITES[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
      jq -n \
        --arg reason "Single-writer invariant: only the main session writes the plan-of-record tracker. Subagent (agent_type=$AGENT_TYPE) denied a Bash write to the tracker via: $COMMAND. Plan mutations go through /replan (/guv:replan under the plugin) in the main session." \
        '{
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
          }
        }'
      exit 0
    fi
  done
fi

# ─────────────────────────────────────────────
# UNIVERSAL BLOCKED — always on
# ─────────────────────────────────────────────
UNIVERSAL_BLOCKED=(
  # Destructive filesystem operations
  'rm\s+-rf\s+/'                    # rm -rf from root
  'rm\s+-rf\s+~'                    # rm -rf home directory
  'rm\s+-rf\s+\.\.?/?(\s|$)'        # rm -rf . / ./ / .. / ../ (the dir itself) — but NOT ./subdir
  'mkfs\.'                          # format filesystem
  'dd\s+if='                        # raw disk write
  'chmod\s+-R\s+777\s+/'            # open permissions from root
  '>\s*/dev/sd[a-z]'                # write to raw disk

  # Destructive git. (git push is intentionally NOT blocked — the agent may push.)
  'git\s+reset\s+--hard\s+origin'   # hard reset to remote — discards local work

  # Pipe-to-shell (remote code execution)
  'curl.*\|\s*(ba)?sh'              # pipe curl to shell
  'wget.*\|\s*(ba)?sh'              # pipe wget to shell
)

# ─────────────────────────────────────────────
# OPTIONAL BLOCKED — keyed by guard name, opt-in via manifest "guards"
# Echoes one regex per line for the requested guard; empty for unknown guards.
# ─────────────────────────────────────────────
optional_patterns_for() {
  case "$1" in
    gcp)
      cat <<'PATTERNS'
gcloud\s+.*\s+delete
bq\s+rm
bq\s+.*--delete
PATTERNS
      ;;
    npm-publish)
      cat <<'PATTERNS'
npm\s+publish
npx\s+npm\s+publish
PATTERNS
      ;;
    cargo-publish)
      cat <<'PATTERNS'
cargo\s+publish
PATTERNS
      ;;
    pypi-publish)
      cat <<'PATTERNS'
twine\s+upload
python[0-9.]*\s+-m\s+twine\s+upload
flit\s+publish
poetry\s+publish
uv\s+publish
PATTERNS
      ;;
    gem-publish)
      cat <<'PATTERNS'
gem\s+push
PATTERNS
      ;;
    *)
      : # unknown guard — contribute nothing
      ;;
  esac
}

# Build the active pattern set: universal core + any opted-in guards.
BLOCKED_PATTERNS=("${UNIVERSAL_BLOCKED[@]}")

MANIFEST=".claude/project.json"
if [ -f "$MANIFEST" ]; then
  GUARDS=$(jq -r '(.guards // [])[]' "$MANIFEST" 2>/dev/null)
  while IFS= read -r guard; do
    [ -z "$guard" ] && continue
    while IFS= read -r pattern; do
      [ -n "$pattern" ] && BLOCKED_PATTERNS+=("$pattern")
    done < <(optional_patterns_for "$guard")
  done <<< "$GUARDS"
fi

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qEi "$pattern"; then
    jq -n \
      --arg reason "Blocked by bash-guard: pattern '$pattern' matched in command: $COMMAND" \
      '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $reason
        }
      }'
    exit 0
  fi
done

# Command is safe — allow
exit 0
