#!/bin/bash
# Tests for .claude/guv-cmd.sh — manifest command read + null-skip, once ([7.1]).
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/guv-cmd.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/guv-cmd.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_project() {  # $1 = commands object as JSON
  local p="$WORK/proj"
  rm -rf "$p"
  mkdir -p "$p/.claude"
  jq -n --argjson cmds "$1" \
    '{roots:{control:".",code:"."},name:"t",language:"node",commands:$cmds,scaffoldCheck:"true",ceremony:"task"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# T1 — defined command runs, stdout reaches the caller, exit 0.
P=$(make_project '{"test":"echo ran-the-tests"}')
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "ran-the-tests" \
  && ok "defined command runs and exits 0" \
  || no "commands.test should run (rc=$RC, out: $OUT)"

# T2 — null command: loud skip on stdout, exit 0 (null-means-skip).
P=$(make_project '{"test":null}')
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "null command: loud skip, exit 0" \
  || no "null command must skip loudly with exit 0 (rc=$RC, out: $OUT)"

# T3 — absent key behaves like null.
P=$(make_project '{}')
OUT=$( (cd "$P" && bash "$SCRIPT" lint) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "absent key: loud skip, exit 0" \
  || no "absent command must skip loudly with exit 0 (rc=$RC, out: $OUT)"

# T4 — a failing command's exit code propagates.
P=$(make_project '{"test":"exit 7"}')
( cd "$P" && bash "$SCRIPT" test ) >/dev/null 2>&1
[ $? -eq 7 ] \
  && ok "failing command's exit code propagates" \
  || no "exit code must propagate from the command"

# T5 — usage: no argument is a loud usage error.
P=$(make_project '{}')
( cd "$P" && bash "$SCRIPT" ) >/dev/null 2>&1
[ $? -eq 2 ] \
  && ok "missing argument -> usage error (exit 2)" \
  || no "missing argument must exit 2"

# T6 — no manifest is a loud error, not a silent skip (a project without a
# manifest has no commands to read — that is a caller bug, not a null).
rm -rf "$WORK/proj"; mkdir -p "$WORK/proj"
( cd "$WORK/proj" && bash "$SCRIPT" test ) >/dev/null 2>&1
[ $? -eq 4 ] \
  && ok "no manifest -> loud error (exit 4)" \
  || no "missing manifest must exit 4"

# T6b — a manifest that exists but cannot be parsed is a LOUD error, never a
# null-skip ("skipping" would misreport corruption as designed absence).
P=$(make_project '{}')
echo '{not json' > "$P/.claude/project.json"
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -q "not valid JSON" && ! echo "$OUT" | grep -qi "skip" \
  && ok "corrupt manifest -> loud error (exit 4), never a skip" \
  || no "corrupt manifest must fail loud, not skip (rc=$RC: $OUT)"

# T7 — the teaching surfaces route through the helper: no inline
# jq -r '.commands.…' read survives in executable command/skill markdown
# (prose naming commands.test as a manifest field is legitimate; the retired
# pattern is the inline jq read).
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
INLINE=$(grep -r "jq -r '\.commands\." \
  "$ROOT/.claude/commands" "$ROOT/.claude/skills" "$ROOT/.claude/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$INLINE" -eq 0 ] \
  && ok "no inline commands.* jq read on the teaching surfaces" \
  || no "$INLINE inline commands.* read(s) remain on teaching surfaces (route through guv-cmd.sh)"

# ── [11.3] — the per-repo selector: `cmd <name> [<repo>]` runs the named repo's
#    command IN that repo, not the control cwd (the consumer of [11.2]'s
#    forward-declared per-repo `commands`). ──
echo "── [11.3] per-repo selector: a command self-locates into the right code root ──"

# A split-topology fixture: control plane + two real code repos, each with a
# marker file so a command can PROVE which repo it ran in (the acceptance:
# "verified by the repo it acts on"). The per-repo command echoes the repo's
# marker; running in the control cwd (the misroute) would not find it.
mk_split() {  # $1 = code object JSON (name -> {path, commands?}); echoes proj dir
  local p="$WORK/split"; rm -rf "$p"; mkdir -p "$p/.claude"
  mkdir -p "$p/store" "$p/studio"
  printf 'STOREFRONT\n' > "$p/store/which-repo"
  printf 'STUDIO\n'     > "$p/studio/which-repo"
  jq -n --argjson code "$1" \
    '{roots:{control:".",code:$code,codePrimary:"storefront"},name:"t",language:"shell",commands:{test:"cat which-repo"},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# T8 — a NAMED repo runs its command IN that repo's root (self-location): the
# command `cat which-repo` resolves the named repo's marker, not the control
# plane's (which has none). storefront → STOREFRONT, studio → STUDIO.
P=$(mk_split '{"storefront":{"path":"store"},"studio":{"path":"studio"}}')
OUT=$( (cd "$P" && bash "$SCRIPT" test storefront) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "STOREFRONT" \
  && ok "named repo: command runs in storefront's root (self-locates, not control cwd)" \
  || no "cmd test storefront must run in storefront's root (rc=$RC, out: $OUT)"
OUT=$( (cd "$P" && bash "$SCRIPT" test studio) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "STUDIO" \
  && ok "named repo: command runs in studio's root (each repo addressable by name)" \
  || no "cmd test studio must run in studio's root (rc=$RC, out: $OUT)"

# T9 — a per-repo `commands` OVERRIDE wins over the top-level default; a field
# ABSENT from the override falls back to the top-level default (the [11.2]
# contract: per-repo commands are overrides, byte-identical fallback otherwise).
P=$(mk_split '{"storefront":{"path":"store","commands":{"test":"echo per-repo-override"}},"studio":{"path":"studio"}}')
OUT=$( (cd "$P" && bash "$SCRIPT" test storefront) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "per-repo-override" \
  && ok "per-repo commands override the top-level default" \
  || no "a per-repo commands.test must override the top-level default (rc=$RC, out: $OUT)"
# studio declares no per-repo test → falls back to the top-level `cat which-repo`,
# run in studio's root → STUDIO.
OUT=$( (cd "$P" && bash "$SCRIPT" test studio) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q "STUDIO" \
  && ok "per-repo absent field falls back to the top-level default (run in the repo)" \
  || no "an absent per-repo field must fall back to the top-level default (rc=$RC, out: $OUT)"

# T9b — a per-repo override that is explicitly null skips loudly (same
# null-means-skip semantics as the top-level), exit 0.
P=$(mk_split '{"storefront":{"path":"store","commands":{"test":null}},"studio":{"path":"studio"}}')
OUT=$( (cd "$P" && bash "$SCRIPT" test storefront) 2>&1 ); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "skip" \
  && ok "per-repo null override: loud skip, exit 0 (null-means-skip)" \
  || no "a per-repo null override must skip loudly with exit 0 (rc=$RC, out: $OUT)"

# T10 — a MISROUTED invocation (an unknown repo name) FAILS LOUD rather than
# silently running in the wrong place (Rule 15 — the worst version of this is a
# command acting in the wrong repo). Routes through the [11.2] resolver, which
# already names the offender.
P=$(mk_split '{"storefront":{"path":"store"},"studio":{"path":"studio"}}')
OUT=$( (cd "$P" && bash "$SCRIPT" test nope) 2>&1 ); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "nope" \
  && ok "misrouted invocation (unknown repo) fails loud, naming the offender (rc=$RC)" \
  || no "an unknown repo name must fail loud, never run in the wrong place (rc=$RC, out: $OUT)"

# T11 — BACK-COMPAT (load-bearing): a NAMED selector against a single-repo '.'
# plane is a no-op — naming the primary (by alias) runs in cwd exactly as the
# bare invocation does. A single-repo plane is unaffected.
P=$(make_project '{"test":"echo single-repo-ran"}')
OUT=$( (cd "$P" && bash "$SCRIPT" test) 2>&1 ); RC0=$?
OUT2=$( (cd "$P" && bash "$SCRIPT" test code) 2>&1 ); RC1=$?
[ $RC0 -eq 0 ] && [ $RC1 -eq 0 ] && echo "$OUT" | grep -q "single-repo-ran" && echo "$OUT2" | grep -q "single-repo-ran" \
  && ok "back-compat: bare and primary-named selector both run in cwd on a single-repo plane" \
  || no "single-repo plane must be unaffected by the selector (rc0=$RC0 rc1=$RC1)"

# T12 — usage: more than two args is a loud usage error (the selector is the
# ONLY new positional; a third arg is malformed).
P=$(make_project '{"test":"echo x"}')
( cd "$P" && bash "$SCRIPT" test repo extra ) >/dev/null 2>&1
[ $? -eq 2 ] \
  && ok "a third positional arg -> usage error (exit 2)" \
  || no "more than <name> <repo> must exit 2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
