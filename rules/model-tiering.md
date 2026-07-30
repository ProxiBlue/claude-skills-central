## Model Tiering (workflows / subagents)

Do NOT default every agent() / subagent to the session model. Pick by task:

- **haiku + effort low**: mechanical scouting where output is a list (glob, grep, enumerate files/modules/templates)
- **sonnet**: writing code (well-specified TDD tasks, boilerplate, migrations, repetitive transforms)
- **opus**: parallel judgment at scale (many mid-tier workers in parallel, deep debugging, research synthesis where you need breadth over ceiling)
- **inherit** (no model override): orchestration, hard-design skills, verify/security/final-judge/review-panel stages. Operator's session tier controls the ceiling — swap `/model` to fable for a high-stakes plan, drop to opus for cost-sensitive iteration, drop to sonnet to A/B test outcomes at different tiers. Reviewers inherit so cost + depth can be tuned per plan without editing frontmatter.

**Caveat on inheritance:** Task-dispatched subagents WITHOUT a model override may resolve to either the top-level session tier OR the immediate calling skill's tier (Claude Code precedence not documented publicly). If you observe reviews running at an unexpectedly low tier (e.g. sonnet when session was fable), the culprit is likely a mid-chain skill with its own `model:` pin (e.g. `plan-orchestrate`) — the fix is either to unpin that skill too or pin the reviewer explicitly. Empirical check via transcript metadata / `/agents` view.

Pattern: **cheap writers, dynamic skeptics.** Writers get pinned tiers per task type; reviewers inherit so the operator dials review depth via `/model` swap. Security review inherits too — session ceiling IS the security tier for that plan.
