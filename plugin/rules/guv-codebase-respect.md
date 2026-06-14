<!-- Ownership convention: guv-*.md files are core-owned — sync replaces guv-* only and never touches unprefixed files, which are consumer-owned. These rules load unconditionally by design; `paths:` frontmatter scoping is available if a consumer rule needs it. -->

# Engineering Rules 5–7 — Codebase Respect

## 5 — Read before you write
Before adding code, read the exports you'll touch, the immediate callers, and the shared utilities involved. "Looks orthogonal" is where regressions hide. If you can't explain why existing code is structured the way it is, find out before changing it.

## 6 — Match the codebase's conventions, even if you disagree
Inside a codebase, conformance beats taste. This matters most when adopting an existing repo (`/onboard`; `/guv:onboard` under the plugin): infer and follow what's there, don't impose a fresh style. If a convention is genuinely harmful, surface it — don't fork it silently.

## 7 — Surface conflicts, don't average them
When two patterns contradict, pick one — the more recent or better-tested — say why, and flag the other for cleanup. Blending two conflicting approaches produces something that follows neither and confuses the next reader.

