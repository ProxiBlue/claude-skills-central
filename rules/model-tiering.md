## Model Tiering (workflows / subagents)

Never default every agent() / subagent to session model. Pick by task:

- **haiku + effort low**: mechanical scouting, output = list (glob, grep, enumerate files/modules/templates)
- **sonnet**: non-code grunt work only — reporters/summaries, plan-file annotation, recall lookups. Never code writers.
- **opus**: parallel judgment at scale (many mid-tier workers, deep debugging, research synthesis — breadth over ceiling)
- **inherit** (session model): code writing (tdd-worker, standards-enforcer, any agent that edits code), orchestration incl. `/hcf:plan-orchestrate`, hard-design skills, verify/security/final-judge/review-panel stages. Session tier = ceiling; operator dials worker intelligence via /model swap, no frontmatter edits. (Owner directive 2026-10-15.)

**Inherit ≠ omit when the agent pins.** An agent's own frontmatter `model:` wins over "no override". Fleet HCF mirror is patched to `model: inherit` (see `claude-plugins-central/seed/marketplaces/hcf/PROXIBLUE-PATCHES.md`); upstream markshust/hcf still pins sonnet. Any other agent pinning a lower tier for code writing → pass `model` explicitly = session tier, or unpin it.

**Inheritance caveat:** Task-dispatched subagents without override may resolve to session tier OR calling skill's tier (precedence undocumented). Workers/reviews running at unexpectedly low tier → suspect mid-chain skill with own `model:` pin; fix = unpin that skill or pin worker/reviewer explicitly. Check via transcript metadata / `/agents`.

Pattern: **session-tier writers, dynamic skeptics.** Writers + reviewers + security run at session tier; only list-scouting (haiku) and non-code reporting (sonnet) drop down — session ceiling IS build + security tier for that plan.
