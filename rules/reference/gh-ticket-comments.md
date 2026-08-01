---
paths:
  - "**/.github/**"
---

# GitHub / GitLab ticket comments — MANDATORY

Every AI-posted comment on a GitHub issue, GitHub PR, or GitLab ticket MUST be (a) bare-minimal in caveman style and (b) minimized as off-topic immediately after posting. This applies to ALL projects in the fleet, not just the originating one.

## Why this exists

Originated from ITToolsAU/LaptopLCDScreen #352 — client complained AI comments were verbose essays wasting reading time. Minimization keeps the comment present for context-aware lookback but collapses it from the active reading flow. The caveman style ensures even an expanded comment delivers information without filler. Generalized fleet-wide on 2026-06-20 — all client-facing ticket trackers, not just LCD.

## Content rules — apply BEFORE posting

- **Max 5 lines.** No headers, no tables, no reasoning narrative, no speculation, no "I" statements, no emojis, no markdown ornamentation.
- **Outcomes only. Past tense.** Drop articles (caveman default).
- **Start with status prefix** — pick ONE: `Done.` / `Blocked.` / `Needs input.` / `UAT done.` / `Deployed.` / `Reverted.` / `Reproduced.` / `Cannot reproduce.`
- **Template:** `<Status>. <outcome>. [gap/blocker per line]. [one link if actionable].`
- **No reasoning, no analysis, no "I noticed", no "I think".** If diagnosis matters, paste it into the PR description or the commit body — not the ticket.

### Examples

Bad (DO NOT do this):
```
## UAT Verification — Structured Data Confirmed Working
After investigation, I noticed that the JSON-LD output...
[3-row table]
[FAQ schema essay paragraph]
[scope declaration block]
```

Good:
```
UAT done. JSON-LD confirmed on 4 products. Gaps (admin config): brand mapping, aggregateRating, Organization. FAQ schema removed from scope — needs content first.
```

## Posting rules — MANDATORY mechanic

**Never** use `gh issue comment` (or `gh pr comment`, or GitLab equivalent) bare. Every post MUST be followed by a `minimizeComment` GraphQL mutation with `classifier: OFF_TOPIC`.

**Use the central helper script — it does both steps:**

- Inside any ddev container: `/var/www/html/.claude/scripts/gh-comment-hidden.sh <repo> <issue_number> "<body>"`
- On the host: `~/claude-skills-central/scripts/gh-comment-hidden.sh <repo> <issue_number> "<body>"`

The script posts then resolves the comment node ID and runs the minimize mutation in one call. If the script cannot resolve the node ID it prints a warning but does NOT fail — manually minimize via the GitHub UI in that case.

For GitLab (no equivalent minimize API yet), follow the SAME content rules but skip the minimize step — collapse is not available there.

## When NOT to apply

- Commit messages — those are not ticket comments, they need full context.
- PR descriptions / merge request bodies — those are read by reviewers in full and should carry the diagnosis.
- Internal Slack / Telegram — separate channel, separate audience.
- Comments written by Lucas himself — this rule is for AI-generated text only.
