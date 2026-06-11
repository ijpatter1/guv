#!/bin/bash
# Tests for .claude/settings.sandbox-example.json — the recommended native-sandbox
# settings fragment (Phase 3: native sandbox is the default isolation tier).
# Guards the invariants the docs promise:
#   - the fragment validates as JSON (the acceptance criterion)
#   - allowedDomains lives at the correct nesting (sandbox.network.allowedDomains)
#   - the starter set mirrors the firewall's core set EXACTLY (drift guard against
#     sandbox/init-firewall.sh — one source of truth for "what domains a stack needs")
#   - per-language registries stay guidance, never baked into the starter set
#   - denyRead covers secrets/ and .env (matching the permission denies)
# Pure bash + jq, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/sandbox-example.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FRAGMENT="$ROOT/.claude/settings.sandbox-example.json"
FIREWALL="$ROOT/sandbox/init-firewall.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T1 — fragment exists and validates as JSON. Everything else depends on this,
# so bail out (loudly) if it fails.
if [ -f "$FRAGMENT" ] && jq empty "$FRAGMENT" 2>/dev/null; then
  ok "fragment exists and validates as JSON"
else
  no "fragment missing or invalid JSON: $FRAGMENT"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# T2 — the fragment actually turns the sandbox on.
[ "$(jq -r '.sandbox.enabled' "$FRAGMENT")" = "true" ] \
  && ok "sandbox.enabled is true" \
  || no "sandbox.enabled must be true"

# T3 — allowedDomains at the correct nesting. The spec's flat "allowedDomains" name
# was directional; the settings schema puts it under sandbox.network.
[ "$(jq -r '.sandbox.network.allowedDomains | type' "$FRAGMENT" 2>/dev/null)" = "array" ] \
  && ok "allowedDomains nested under sandbox.network" \
  || no "sandbox.network.allowedDomains must be an array"

# T4/T5 mirror the fragment against the Docker tier's firewall. A consumer who
# dropped the opt-in Docker rig (deleted sandbox/) has no mirror subject — skip
# cleanly with a message rather than failing (same pattern as other optional
# subjects), never silently.
FR_DOMAINS=$(jq -r '.sandbox.network.allowedDomains[]?' "$FRAGMENT" | sort)
if [ ! -f "$FIREWALL" ]; then
  echo "  - sandbox/init-firewall.sh absent (Docker tier removed) — skipping firewall-mirror tests"
else
  # T4 — starter set mirrors the firewall's core set exactly, both directions.
  # The core set is the first ALLOWED_DOMAINS=( ... ) block in init-firewall.sh
  # (the += registry/project/gcloud additions are deliberately NOT mirrored).
  FW_CORE=$(awk '/^ALLOWED_DOMAINS=\(/,/^\)/' "$FIREWALL" | grep -o '"[^"]*"' | tr -d '"' | sort)
  if [ -n "$FW_CORE" ] && [ "$FW_CORE" = "$FR_DOMAINS" ]; then
    ok "starter allowedDomains == firewall core set (drift guard)"
  else
    no "starter allowedDomains must equal the firewall core set"
    diff <(echo "$FW_CORE") <(echo "$FR_DOMAINS") | sed 's/^/      /'
  fi

  # T5 — per-language registries are guidance, not defaults: every registry domain
  # from the firewall's per-language table is MENTIONED in the fragment (comment
  # guidance) but ABSENT from the starter array (a Rust CLI never opens npm).
  REGISTRIES=$(grep 'REGISTRY_DOMAINS=(' "$FIREWALL" | grep -o '"[^"]*"' | tr -d '"' | sort -u)
  [ -n "$REGISTRIES" ] || no "could not extract registry domains from firewall (test setup)"
  MISSING=""; LEAKED=""
  for d in $REGISTRIES; do
    grep -q "$d" "$FRAGMENT" || MISSING="$MISSING $d"
    echo "$FR_DOMAINS" | grep -qx "$d" && LEAKED="$LEAKED $d"
  done
  [ -z "$MISSING" ] \
    && ok "all per-language registry domains documented as guidance" \
    || no "registry domains missing from guidance:$MISSING"
  [ -z "$LEAKED" ] \
    && ok "no registry domain baked into the starter set" \
    || no "registry domains must stay guidance, found in starter set:$LEAKED"
fi

# T6 — denyRead covers every Read deny in settings.json's permission denies,
# DERIVED from settings.json (like T4 derives from the firewall) so a new
# Read deny added there fires this drift guard. Glob patterns reduce to their
# core token: Read(**/.env) → .env, Read(**/.env.*) → .env., Read(**/secrets/**)
# → secrets — each token must appear in some denyRead entry.
SETTINGS="$ROOT/.claude/settings.json"
DENY_TOKENS=$(jq -r '.permissions.deny[] | select(startswith("Read(")) | ltrimstr("Read(") | rtrimstr(")")' "$SETTINGS" \
  | sed 's|\*\*/||g; s|/\*\*||g; s|\*$||')
[ -n "$DENY_TOKENS" ] || no "could not extract Read denies from settings.json (test setup)"
UNCOVERED=""
for tok in $DENY_TOKENS; do
  jq -e --arg t "$tok" '.sandbox.filesystem.denyRead | map(select(contains($t))) | length > 0' "$FRAGMENT" >/dev/null 2>&1 \
    || UNCOVERED="$UNCOVERED $tok"
done
[ -z "$UNCOVERED" ] \
  && ok "denyRead covers every settings.json Read deny (drift guard)" \
  || no "denyRead misses permission-deny tokens:$UNCOVERED"

# T7 — the fragment is sandbox-only guidance: the live settings.json owns
# permissions and hooks, and the fragment must not fork them.
[ "$(jq -r 'has("permissions") or has("hooks")' "$FRAGMENT")" = "false" ] \
  && ok "fragment carries no permissions/hooks (sandbox-only)" \
  || no "fragment must not carry permissions or hooks blocks"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
