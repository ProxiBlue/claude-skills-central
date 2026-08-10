# Completeness-critical page fetches — MANDATORY

When the answer to "does X appear on this page" or "is Y affected" has to be right — not just plausible — do not use WebFetch (or any tool that pre-summarizes a page). Fetch the raw page and grep/read it in full yourself.

## Why this exists

WebFetch's own tool description says it plainly: fetches the URL, converts HTML to markdown, **processes the content with a small, fast model**, and "results may be summarized if the content is very large." That intermediate model decides what's relevant before you ever see the page — on a long document it can silently drop a section.

2026-08-11 incident: a Claude instance in the `lcd-mageos` container was asked to check a security advisory URL against installed Amasty modules. It used WebFetch (internally referred to as "ctx_search" / "preview windows" in the incident writeup). The summarized result reported clean. The raw page in fact contained two critical High-severity RMA lines and a `regenerate-url-rewrites` line in a later chunk of the High-severity section — a real critical update was nearly missed entirely, caught only because the user pushed back and demanded a re-check with `curl` + `grep`. See auto-memory `feedback_security_advisory_scan_raw_grep.md`.

This is not unique to WebFetch — the same blind spot applies to any tool that returns an excerpt/snippet/preview instead of full content: `mcp__claude-in-chrome__get_page_text`/`read_page`, chrome-devtools page snapshots, "search this doc" style helpers. Anything that runs a secondary model or search pass between you and the raw bytes can drop content you needed.

## What counts as completeness-critical

- Security advisories, CVEs, vulnerability bulletins, security patches/hotfixes
- Cross-checking installed packages/modules/versions against an affected-versions list
- Compliance, legal, or financial figures where an omission has real cost
- Research citations where a claim must be verifiable against the actual source text, not a paraphrase

## What to do instead

```
curl -sL '<url>' | grep -iE '<keyword-or-package-name>'
```

Or fetch the raw page (curl, or a browser tool's *raw* content extraction — not its summarizing variant) and read the full output yourself. Don't re-summarize your own grep output either — if the match count is manageable, read all of it.

## Enforcement

`webfetch-completeness-guard.sh` (PreToolUse, matcher `WebFetch`) hard-blocks WebFetch calls whose URL or prompt match advisory/CVE/vulnerability-shaped keywords (CVE-, advisory, vulnerab*, exploit, RCE, XSS, SQL injection, security update/patch/bulletin/fix, patch level, affected version/module, high/critical severity, zero-day). Blocked calls are redirected to curl + grep, not stopped outright — the alternative tool is always available.

False positive (URL/prompt matched but isn't actually a completeness-critical lookup)? Ask the user, or add `webfetch-completeness-guard` to `<repo>/.claude/rules-disable`.

## What this does NOT cover yet

General research fetches (deep-research skill, casual "what does this page say") still use WebFetch's summarization by default — that's an accepted tradeoff for token efficiency on non-critical lookups. If a specific research claim needs source-exact verification, apply the same curl+grep/full-read discipline manually; the guard hook only catches the advisory/vuln keyword pattern above, not general research completeness.
