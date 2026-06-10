#!/bin/bash
# .claude/hooks/bash-guard.sh
# PreToolUse hook for Bash commands — blocks dangerous patterns.
# Receives JSON on stdin with tool_input.command.
# Exit 0 = allow, JSON stdout with deny = block.
#
# SECURITY MODEL:
# This hook is one layer of a defense-in-depth strategy:
#   1. settings.json permissions — convenience layer, auto-allow safe commands
#   2. This hook — deterministic enforcement, blocks dangerous patterns
#   3. Docker sandbox firewall — network-level isolation (when using sandbox)
#
# This hook should be safe to use WITH OR WITHOUT the Docker sandbox.
# When running outside Docker (e.g., native Claude Code with built-in sandbox),
# this hook provides the primary enforcement for destructive patterns (filesystem
# wipes, hard resets, publishes) that the Docker firewall would otherwise catch.
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
