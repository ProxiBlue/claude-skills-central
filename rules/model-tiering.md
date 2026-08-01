## Model Tiering (workflows / subagents)

Never default every agent() / subagent to session model. Pick by task:

- **haiku + effort low**: mechanical scouting, output = list (glob, grep, enumerate files/modules/templates)
- **sonnet**: writing code (well-specified TDD tasks, boilerplate, migrations, repetitive transforms)
- **opus**: parallel judgment at scale (many mid-tier workers, deep debugging, research synthesis — breadth over ceiling)
- **inherit** (no override): orchestration, hard-design skills, verify/security/final-judge/review-panel stages. Session tier = ceiling; operator dials review depth via /model swap, no frontmatter edits.

**Inheritance caveat:** Task-dispatched subagents without override may resolve to session tier OR calling skill's tier (precedence undocumented). Reviews running at unexpectedly low tier → suspect mid-chain skill with own `model:` pin (e.g. plan-orchestrate); fix = unpin that skill or pin reviewer explicitly. Check via transcript metadata / `/agents`.

Pattern: **cheap writers, dynamic skeptics.** Writers pinned per task type; reviewers + security inherit — session ceiling IS security tier for that plan.
