#!/bin/bash
# Tests for the plugin scaffold — Phase 5 D2: /guv:scaffold replaces the
# template-clone step for the project shell. The deterministic half is
# plugin/scripts/scaffold-shell.sh (judgment stays in the skill); these tests
# drive the script against scratch project dirs using the COMMITTED plugin/
# (the build's output — drift vs sources is plugin.test.sh's job).
# Ownership semantics mirror copy_core:
#   - harness-owned, refreshed every run: schema, guv-* rules, both templates,
#     the sandbox-settings example
#   - consumer-owned after first deploy, never clobbered: settings.json,
#     .gitignore content (guv block appended once, marker-guarded), Docker tier
#   - never touched: project.json, CLAUDE.md, README.md, docs/ contents
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/scaffold.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell
PLUGIN="$ROOT/plugin"
SCRIPT="$PLUGIN/scripts/scaffold-shell.sh"
SHELL_DIR="$PLUGIN/shell"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# The whole suite drives the COMMITTED plugin/ — a template-clone fork that
# deleted the generated tree (README's note) has nothing to scaffold from;
# skip cleanly, never as failures. SCAFFOLD_PLUGIN_TREE is the self-check seam.
if [ ! -d "${SCAFFOLD_PLUGIN_TREE:-$PLUGIN}" ]; then
  echo "  - plugin/ absent (template-clone fork) — suite skips"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

deploy() { (cd "$1" && bash "$SCRIPT" "${@:2}") }

# T1 — the script ships in the plugin
if [ -f "$SCRIPT" ]; then
  ok "scaffold-shell.sh ships in plugin/scripts/"
else
  no "scaffold-shell.sh missing: $SCRIPT"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# T2 — fresh deploy lays down the full project shell
P1="$WORK/fresh"; mkdir -p "$P1"
deploy "$P1" >/dev/null 2>&1
T2_OK=1
for f in CLAUDE.template.md README.template.md .claude/project.schema.json \
         .claude/settings.json .claude/settings.sandbox-example.json \
         docs/sessions/.gitkeep .gitignore \
         docs/REQUIREMENTS.md docs/ARCHITECTURE.md docs/PHASE_STATUS.md; do
  [ -e "$P1/$f" ] || { no "fresh deploy missing $f"; T2_OK=0; }
done
RULES_N=$(ls "$P1/.claude/rules/"guv-*.md 2>/dev/null | wc -l | tr -d ' ')
SRC_RULES_N=$(ls "$SHELL_DIR/../rules/"guv-*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$RULES_N" = "$SRC_RULES_N" ] && [ "$RULES_N" != "0" ] || { no "expected $SRC_RULES_N guv-* rules deployed, got $RULES_N"; T2_OK=0; }
[ "$T2_OK" -eq 1 ] && ok "fresh deploy lays down templates, schema, settings, rules, docs/, .gitignore"

# T3 — deployed settings carry the permissions layer but NO hooks block: hooks
# come from the plugin's hooks.json, and the template's hook commands point at
# .claude/hooks/ scripts a scaffolded project doesn't have.
jq -e '.permissions.allow | length > 0' "$P1/.claude/settings.json" >/dev/null 2>&1 \
  && ok "deployed settings.json keeps the permissions layer" \
  || no "deployed settings.json must keep permissions"
jq -e 'has("hooks") | not' "$P1/.claude/settings.json" >/dev/null 2>&1 \
  && ok "deployed settings.json has no hooks block (plugin hooks.json owns them)" \
  || no "deployed settings.json must not wire hooks"

# T4 — .gitignore carries the harness entries (and the marker that keeps the
# append idempotent)
T4_OK=1
for entry in "secrets/" ".claude/settings.local.json" ".claude/agent-memory/" ".DS_Store"; do
  grep -qF "$entry" "$P1/.gitignore" || { no ".gitignore missing entry: $entry"; T4_OK=0; }
done
[ "$T4_OK" -eq 1 ] && ok ".gitignore carries the harness entries"

# T5 — ownership on re-run: consumer-owned survives, harness-owned refreshes
echo '{"permissions":{"allow":["Bash(mycustom:*)"]}}' > "$P1/.claude/settings.json"
echo "# my team rule" > "$P1/.claude/rules/team-style.md"
echo "stale" > "$P1/.claude/rules/guv-verification.md"
echo "consumer-edited" > "$P1/CLAUDE.template.md"
deploy "$P1" >/dev/null 2>&1
grep -q "mycustom" "$P1/.claude/settings.json" \
  && ok "consumer-edited settings.json survives re-run" \
  || no "re-run clobbered consumer settings.json"
[ "$(cat "$P1/.claude/rules/team-style.md")" = "# my team rule" ] \
  && ok "consumer-authored unprefixed rule survives re-run" \
  || no "re-run touched a consumer rule"
grep -q "stale" "$P1/.claude/rules/guv-verification.md" \
  && no "stale guv-* rule not refreshed on re-run" \
  || ok "stale guv-* rule refreshed on re-run (ownership by filename)"
grep -q "consumer-edited" "$P1/CLAUDE.template.md" \
  && no "harness-owned template not refreshed on re-run" \
  || ok "templates are harness-owned: refreshed on re-run"
echo "# my filled-in requirements" > "$P1/docs/REQUIREMENTS.md"
deploy "$P1" >/dev/null 2>&1
grep -q "my filled-in requirements" "$P1/docs/REQUIREMENTS.md" \
  && ok "doc skeletons are consumer-owned: a filled-in REQUIREMENTS.md survives re-run" \
  || no "re-run clobbered a consumer's filled-in phase doc"

# T6 — pre-existing .gitignore: content kept, guv block appended exactly once
P2="$WORK/existing-gi"; mkdir -p "$P2"
printf 'my-build-dir/\n' > "$P2/.gitignore"
deploy "$P2" >/dev/null 2>&1
deploy "$P2" >/dev/null 2>&1
grep -q "my-build-dir/" "$P2/.gitignore" \
  && ok "existing .gitignore content preserved" \
  || no "existing .gitignore content lost"
N=$(grep -c "secrets/" "$P2/.gitignore")
[ "$N" -eq 1 ] \
  && ok "guv block appended exactly once across two runs" \
  || no "guv block duplicated or missing (secrets/ appears ${N}x)"
# single-source guard: the appended block IS the template's marker-delimited
# core block — extracted at deploy time, no hardcoded copy in the script to
# drift when the template gains a harness-critical entry
diff <(awk '/^# guv-core-start/,/^# guv-core-end/' "$SHELL_DIR/gitignore") \
     <(awk '/^# guv-core-start/,/^# guv-core-end/' "$P2/.gitignore") >/dev/null 2>&1 \
  && ok "appended block == template's guv-core block (single source, extracted)" \
  || no "appended .gitignore block must be extracted from shell/gitignore's core block"

# T7 — Docker tier is opt-in (--docker), and existing tier files are never
# clobbered (consumers patch init-firewall.sh with their registry domains)
[ ! -e "$P1/sandbox" ] && [ ! -e "$P1/Makefile" ] \
  && ok "Docker tier absent without --docker" \
  || no "Docker tier deployed without the flag"
P3="$WORK/docker"; mkdir -p "$P3"
deploy "$P3" --docker >/dev/null 2>&1
T7_OK=1
for f in sandbox/Dockerfile sandbox/entrypoint.sh sandbox/init-firewall.sh Makefile; do
  [ -e "$P3/$f" ] || { no "--docker missing $f"; T7_OK=0; }
done
[ "$T7_OK" -eq 1 ] && ok "--docker deploys sandbox/ + Makefile"
echo "MY_DOMAIN=example.com" >> "$P3/sandbox/init-firewall.sh"
deploy "$P3" --docker >/dev/null 2>&1
grep -q "MY_DOMAIN" "$P3/sandbox/init-firewall.sh" \
  && ok "consumer-patched firewall survives --docker re-run" \
  || no "--docker re-run clobbered a consumer-patched tier file"

# T8 — never touched: manifest, rendered CLAUDE.md, session docs
P4="$WORK/live"; mkdir -p "$P4/docs/sessions"
mkdir -p "$P4/.claude"
printf '{"name":"my-project"}\n' > "$P4/.claude/project.json"
printf '# My Project\n' > "$P4/CLAUDE.md"
printf 'handoff\n' > "$P4/docs/sessions/session-001.md"
deploy "$P4" >/dev/null 2>&1
[ "$(cat "$P4/.claude/project.json")" = '{"name":"my-project"}' ] \
  && ok "existing project.json never touched" \
  || no "scaffold touched project.json"
[ "$(cat "$P4/CLAUDE.md")" = "# My Project" ] \
  && ok "rendered CLAUDE.md never touched" \
  || no "scaffold touched CLAUDE.md"
[ "$(cat "$P4/docs/sessions/session-001.md")" = "handoff" ] \
  && ok "session artifacts never touched" \
  || no "scaffold touched docs/sessions/"

# T9 — the deploy reports what it did (fail loud, auditable), and the labels
# are accurate: a fresh deploy reports the rules as CREATED, a re-run as
# refreshed (the report is the feature — mislabels defeat it)
mkdir -p "$WORK/report" && OUT=$(cd "$WORK/report" && bash "$SCRIPT" 2>&1)
echo "$OUT" | grep -qi "created\|deployed" \
  && ok "deploy reports its actions" \
  || no "deploy must report created/refreshed/skipped actions"
echo "$OUT" | grep -E '^\[scaffold\] created:.*rules/guv-' >/dev/null \
  && ok "fresh deploy labels the rules as created" \
  || no "fresh deploy must label rules created, not refreshed"
OUT2=$(cd "$WORK/report" && bash "$SCRIPT" 2>&1)
echo "$OUT2" | grep -E '^\[scaffold\] refreshed:.*rules/guv-' >/dev/null \
  && ok "re-run labels the rules as refreshed" \
  || no "re-run must label rules refreshed"

# T10 — shell assets in the plugin match their harness sources: templates,
# gitignore, schema, sandbox-example, and the Docker tier byte-identical;
# settings = source settings minus the hooks block (jq-normalized compare)
T10_OK=1
for pair in \
  "CLAUDE.template.md:shell/CLAUDE.template.md" \
  "README.template.md:shell/README.template.md" \
  ".gitignore:shell/gitignore" \
  "Makefile:shell/Makefile" \
  ".claude/project.schema.json:shell/project.schema.json" \
  ".claude/settings.sandbox-example.json:shell/settings.sandbox-example.json" \
  "docs/REQUIREMENTS.md:shell/docs/REQUIREMENTS.md" \
  "docs/ARCHITECTURE.md:shell/docs/ARCHITECTURE.md" \
  "docs/PHASE_STATUS.md:shell/docs/PHASE_STATUS.md"; do
  cmp -s "$ROOT/${pair%%:*}" "$PLUGIN/${pair##*:}" || { no "shell asset ${pair##*:} differs from ${pair%%:*}"; T10_OK=0; }
done
diff -r "$ROOT/sandbox" "$PLUGIN/shell/sandbox" >/dev/null 2>&1 || { no "shell/sandbox differs from sandbox/"; T10_OK=0; }
[ "$T10_OK" -eq 1 ] && ok "shell assets byte-identical to harness sources"
diff <(jq -S 'del(.hooks)' "$ROOT/.claude/settings.json") <(jq -S . "$PLUGIN/shell/settings.json") >/dev/null 2>&1 \
  && ok "shell settings.json = source settings minus the hooks block" \
  || no "shell settings.json must equal the source with .hooks deleted"

# T11 — the /guv:scaffold skill fronts the script: ships in the plugin, runs
# the deploy via ${CLAUDE_PLUGIN_ROOT}, and writes the manifest via the
# resolver (the deliverable's "manifest via resolver")
SK="$PLUGIN/skills/scaffold/SKILL.md"
if [ -f "$SK" ]; then
  ok "scaffold skill ships in the plugin"
  grep -q 'CLAUDE_PLUGIN_ROOT.*scaffold-shell\.sh' "$SK" \
    && ok "scaffold skill invokes scaffold-shell.sh from the plugin root" \
    || no "scaffold skill must invoke scaffold-shell.sh via \${CLAUDE_PLUGIN_ROOT}"
  grep -q 'resolve-stack\.sh' "$SK" \
    && ok "scaffold skill writes the manifest via the resolver" \
    || no "scaffold skill must use resolve-stack.sh for the manifest"
  tr '\n' ' ' < "$SK" | tr -s ' ' | grep -qE '(--docker|Docker tier)' \
    && ok "scaffold skill offers the optional Docker tier" \
    || no "scaffold skill must offer the Docker tier option"
else
  no "scaffold skill missing: $SK"
fi

# Fork self-check: the wholesale skip fires and shows itself (output-grepped —
# exit 0 alone would pass in the canonical repo even with the skip deleted)
if [ -z "${SCAFFOLD_TEST_INNER:-}" ]; then
  INNER=$(SCAFFOLD_TEST_INNER=1 SCAFFOLD_PLUGIN_TREE="$ROOT/nonexistent-plugin" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "suite skips"; then
    ok "suite visibly skips in a fork that deleted plugin/"
  else
    no "suite must exit 0 and visibly skip when plugin/ is absent"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
