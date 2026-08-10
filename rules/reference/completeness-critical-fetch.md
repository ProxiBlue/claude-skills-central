# Full-page fetches only — MANDATORY (blanket, not just security)

Never use WebFetch (or any tool that pre-summarizes a page). Fetch the raw page and read it in full yourself. This applies to EVERY fetch — security scans, module/version checks, and general research/citation lookups alike. Widened 2026-08-11 from an advisory/CVE-only rule after the user made clear the same blind spot risks silently dropping content during research, not just security scans.

## Why this exists

WebFetch's own tool description says it plainly: fetches the URL, converts HTML to markdown, **processes the content with a small, fast model**, and "results may be summarized if the content is very large." That intermediate model decides what's relevant before you ever see the page — on a long document it can silently drop a section.

2026-08-11 incident: a Claude instance in the `lcd-mageos` container was asked to check a security advisory URL against installed Amasty modules. It used WebFetch (internally referred to as "ctx_search" / "preview windows" in the incident writeup). The summarized result reported clean. The raw page in fact contained two critical High-severity RMA lines and a `regenerate-url-rewrites` line in a later chunk of the High-severity section — a real critical update was nearly missed entirely, caught only because the user pushed back and demanded a re-check with `curl` + `grep`. See auto-memory `feedback_security_advisory_scan_raw_grep.md`.

This is not unique to WebFetch — the same blind spot applies to any tool that returns an excerpt/snippet/preview instead of full content: `mcp__claude-in-chrome__get_page_text`/`read_page`, chrome-devtools page snapshots, "search this doc" style helpers. Anything that runs a secondary model or search pass between you and the raw bytes can drop content you needed.

## Scope

Everything. No category carve-out. Security advisories, module/version cross-checks, compliance/legal/financial figures, general research citations, "what does this page say" — all of it gets the full raw page, every time.

## What to do instead

```
curl -sL '<url>'
```

Read the FULL output yourself. If grepping to locate something first, grep only to LOCATE — then read the surrounding context in full, don't discard the rest as noise.

For JS-rendered or authenticated pages (curl can't render JS or hold a session): use a browser tool's *raw* text extraction — e.g. `claude-in-chrome get_page_text`/`read_page`, chrome-devtools page snapshot — not a search/summarize variant of it.

## Enforcement

`webfetch-completeness-guard.sh` (PreToolUse, matcher `WebFetch`) hard-blocks **every** WebFetch call, full stop — widened 2026-08-11 from an advisory/CVE-keyword filter to a blanket block. One structural exception: `claude.ai/code/artifact/{uuid}` and `preview.claude.ai` URLs, since WebFetch is the only tool that can authenticate there (curl/headless-browser cannot) — not a completeness loophole, a hard capability gap. Blocked calls are redirected to curl or raw browser-tool extraction, not stopped outright — an alternative is always available for ordinary pages.

Genuinely need WebFetch for a page nothing else can reach? Ask the user, or add `webfetch-completeness-guard` to `<repo>/.claude/rules-disable`.

## Known consequence

The built-in `deep-research` skill and any workflow that leans on WebFetch for fan-out source fetching will hit this block on every source. Expected — the fix is to fetch each source via curl (or raw browser extraction) and read it in full instead of accepting WebFetch's per-source summary. Slower and pricier in tokens; that trade was made deliberately after the 2026-08-11 near-miss.
