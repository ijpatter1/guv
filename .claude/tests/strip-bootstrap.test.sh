#!/bin/bash
# Tests for .claude/strip-bootstrap.sh — the deterministic remover of the
# rendered CLAUDE.md "Bootstrapping" section once a project is past scaffold
# ([20.4]). The section is first-session-only template text; left in place it
# rots into a live project's identity doc. The strip is GATED on scaffold STATE
# (the manifest's scaffoldCheck), not on the section's mere presence — so the
# discriminating pair is T1 (scaffolded → strip) vs T3 (not scaffolded → keep):
# that pair is what proves the gate is real and not "always strip."
# Pure bash + jq + awk, no test runner. Run: bash .claude/tests/strip-bootstrap.test.sh
set -u

HELPER="$(cd "$(dirname "$0")/.." && pwd)/strip-bootstrap.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"

# make_fixture <scaffoldCheck|__none__|__nomanifest__> [trailer]
# Builds a scratch project: a manifest carrying the given scaffoldCheck (or none /
# no manifest at all), and a CLAUDE.md whose LAST section is the Bootstrapping
# block, preceded by a real section so "removed only itself" is checkable. With
# the `trailer` arg, a section is appended AFTER Bootstrapping to prove the strip
# is bounded by the next `## ` heading, not a truncate-to-EOF.
make_fixture() {
  rm -rf "$PROJ"; mkdir -p "$PROJ/.claude"
  case "${1-}" in
    __nomanifest__) : ;;                                   # no manifest on disk
    __none__) jq -n '{ceremony:"phased"}' > "$PROJ/.claude/project.json" ;;
    *) jq -n --arg sc "$1" '{ceremony:"phased", scaffoldCheck:$sc}' > "$PROJ/.claude/project.json" ;;
  esac
  {
    printf '# Project — identity\n\nSome intro line.\n\n'
    printf '## What is intentionally NOT in this file\n\n- Commands → manifest.\n\n'
    printf '## Bootstrapping (first session, `phased` greenfield only)\n\n'
    printf 'If `scaffoldCheck` fails, the project isn'"'"'t scaffolded yet. Remove this section once the project is scaffolded.\n'
    [ "${2-}" = "trailer" ] && printf '\n## After Bootstrapping (should survive)\n\nTrailer content.\n'
  } > "$PROJ/CLAUDE.md"
}
run() { ( cd "$PROJ" && bash "$HELPER" CLAUDE.md ); }

# T1 — past scaffold (scaffoldCheck passes): the Bootstrapping section is removed,
# every other line preserved.
make_fixture "true"
run
grep -q '## Bootstrapping' "$PROJ/CLAUDE.md" && no "scaffolded: Bootstrapping section should be removed" || ok "scaffolded: Bootstrapping section removed"
grep -q 'Remove this section once' "$PROJ/CLAUDE.md" && no "scaffolded: stale bootstrap body should be gone" || ok "scaffolded: stale bootstrap body gone"
grep -q '# Project — identity' "$PROJ/CLAUDE.md" && ok "identity heading preserved" || no "identity heading lost"
grep -q '## What is intentionally NOT in this file' "$PROJ/CLAUDE.md" && ok "preceding section heading preserved" || no "preceding section heading lost"
grep -q 'Commands → manifest' "$PROJ/CLAUDE.md" && ok "preceding section body preserved" || no "preceding section body lost"

# T2 — idempotent: a second run is a byte-for-byte no-op (the section is already gone).
cp "$PROJ/CLAUDE.md" "$WORK/after1"
run
cmp -s "$PROJ/CLAUDE.md" "$WORK/after1" && ok "idempotent: second run is a no-op" || no "second run changed the file"

# T3 — NOT yet scaffolded (scaffoldCheck fails): the section is KEPT, file untouched.
# This is the gate proof — without it the script could be a blind "always strip."
make_fixture "false"
cp "$PROJ/CLAUDE.md" "$WORK/orig"
run
grep -q '## Bootstrapping' "$PROJ/CLAUDE.md" && ok "not scaffolded: Bootstrapping section kept (first session)" || no "not scaffolded: section wrongly removed"
cmp -s "$PROJ/CLAUDE.md" "$WORK/orig" && ok "not scaffolded: file left untouched" || no "not scaffolded: file modified"

# T4a — manifest present but NO scaffoldCheck: can't confirm scaffold state → keep.
make_fixture "__none__"
cp "$PROJ/CLAUDE.md" "$WORK/orig"
run
cmp -s "$PROJ/CLAUDE.md" "$WORK/orig" && ok "no scaffoldCheck: file left untouched (indeterminate → keep)" || no "no scaffoldCheck: file modified"

# T4b — no manifest at all: indeterminate → keep, exit 0.
make_fixture "__nomanifest__"
cp "$PROJ/CLAUDE.md" "$WORK/orig"
run; rc=$?
cmp -s "$PROJ/CLAUDE.md" "$WORK/orig" && ok "no manifest: file left untouched" || no "no manifest: file modified"
[ "$rc" -eq 0 ] && ok "no manifest: exit 0" || no "no manifest: should exit 0"

# T5 — missing CLAUDE.md: exit 0, no error (advisory/maintenance never blocks).
make_fixture "true"
rm -f "$PROJ/CLAUDE.md"
( cd "$PROJ" && bash "$HELPER" CLAUDE.md ); [ $? -eq 0 ] && ok "missing CLAUDE.md: exit 0" || no "missing file should exit 0"

# T6 — bounded removal: with a section AFTER Bootstrapping, only Bootstrapping is
# removed; the trailing section survives (not a truncate-to-EOF).
make_fixture "true" "trailer"
run
grep -q '## Bootstrapping (first session' "$PROJ/CLAUDE.md" && no "boundary: Bootstrapping removed even with a trailer" || ok "boundary: Bootstrapping section removed"
grep -q '## After Bootstrapping' "$PROJ/CLAUDE.md" && ok "boundary: section after Bootstrapping survives" || no "boundary: trailing section wrongly removed"
grep -q 'Trailer content' "$PROJ/CLAUDE.md" && ok "boundary: trailing section body survives" || no "boundary: trailing body lost"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
