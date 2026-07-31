# HCF plan-orchestrate — MANDATORY pb-hcf wire (replaces legacy overlay)

For any plan orchestration in a Magento / Mage-OS project, the project MUST be wired with `/pb-hcf:wire` first. After that, `/hcf:plan-orchestrate` runs natively — **no wrapper.**

This rule supersedes the earlier mandate to use the retired wrapper skill (a wrapper around HCF). The wrapper has been retired in favour of context wiring + HCF v2's frontmatter-based hook pipeline.

## What changed (2026-06-30 — HCF v2.0.0 alignment)

HCF v2.0.0 (released 2026-06-26) **retired `.claude/pipeline.md`**. Agents now declare hook membership via YAML frontmatter (`phase:` / `order:` / `mode:`) — see [HOOKS.md upstream](https://github.com/markshust/hcf#pipeline). HCF actively blocks `plan-create` / `plan-orchestrate` while a legacy `pipeline.md` exists (SessionStart notice + PreToolUse + UserPromptExpansion gates), unblocked by `/hcf:project-update`.

pb-hcf v0.3.0 lines up:
- `/pb-hcf:wire` no longer writes `pipeline.md`. It refuses to run while a legacy `pipeline.md` exists and points the user at `/hcf:project-update` first.
- Bundled pb-hcf agents (`codegraph-reviewer`, `security-quorum`) are enrolled into HCF's `post-implementation` hook **only when** the user passes `--enable=<name>[,<name>]` (or `--enable-all`). Default: dormant — matches HCF's `standards-enforcer` convention.

| Substitution from the old overlay | New home in HCF v2 |
|---|---|
| (A) codegraph-reviewer (per-task) | `.claude/agents/codegraph-reviewer.md` with `phase: post-implementation`, `order: 30`, `mode: single` (whole-diff at plan-end). For per-batch cadence, switch `phase` to `post-batch`. |
| (B) test deferral | **Not yet rehomed.** Currently uses HCF defaults. Mitigate per-project via `.claude/testing.md` scoping — see "Open concern" below. |

## How to apply

When the user (or another skill) asks for plan orchestration:

- **Verify wire state first.** Check that `.claude/wires.json` exists at project root (written by `/pb-hcf:wire`). If missing, run `/pb-hcf:wire` first.
  - **Legacy `pipeline.md` present?** STOP and run `/hcf:project-update` first — it migrates any active entries into per-agent frontmatter (`.claude/agents/<name>.md` with `phase` stamped) and removes the file. THEN re-run `/pb-hcf:wire`. Both `pb-hcf:wire` and HCF itself refuse to operate around a legacy pipeline.md.
  - **Legacy `<!-- legacy plugin fence -->` fence in CLAUDE.md?** `/pb-hcf:wire` auto-migrates that part of the fence (independent of pipeline.md handling).
- **Invoke `/hcf:plan-orchestrate` directly.** HCF native is the default. No wrapper.
- **For the codegraph-reviewer behaviour**, run `/pb-hcf:wire --enable=codegraph-reviewer` once per project — copies the plugin agent to `.claude/agents/codegraph-reviewer.md` with `phase: post-implementation` stamped. HCF picks it up via frontmatter discovery; no other action needed.
- **For the security-quorum gate**, similarly `/pb-hcf:wire --enable=security-quorum`. Or `--enable-all` for both.
- **For per-domain agent guidance** (codegraph, graphiti, …): the wire installs `.claude/<domain>.md` playbooks and a single fenced section in `.claude/CLAUDE.md` pointing to them. HCF's default agents (devils-advocate, tdd-worker, standards-enforcer) auto-load CLAUDE.md and follow the pointers — they consult the right playbook for the right question.
- **Non-Magento projects** (Leaf PHP, etc.): `/hcf:plan-orchestrate` is fine. Wire is optional; only run `/pb-hcf:wire` if the project benefits from any of the wired playbooks (graphiti always applies; codegraph is Magento-only).

## Open concern — test deferral

The retired wrapper deferred all full-suite test execution to plan-end. HCF default has tdd-worker run the full suite at end of EACH task, and the orchestrator run the full suite again after the post-implementation pipeline. Under parallel worker dispatch, those full-suite runs collide on shared resources (MariaDB rows, Redis cache, OpenSearch indexes, Playwright sessions, `var/` artefacts, search indexers).

**Without the wrapper, this collision is back.** Mitigations available without re-wrapping:
- Scope each project's `.claude/testing.md` test commands to **targeted invocation only** (per-file or per-testsuite), not full-suite. tdd-worker uses what testing.md says.
- Run plan-orchestrate with `--max-parallel 1` if HCF supports the flag (degrades to sequential — slow but safe).
- Author a project-local agent under `.claude/agents/` with `phase: post-implementation` that runs the full suite once — and rely on it instead of tdd-worker's per-task runs (testing.md scoped to targeted only).

The migration intentionally drops the test-deferral feature; revisit if the parallel-collision pattern shows up in practice on a real plan.

## What this rule does NOT do

- Does not modify HCF source files. HCF stays upstream-clean.
- Does not prevent ad-hoc `/hcf:plan-create` use.
- Does not apply to `tdd-worker` invocations spawned directly outside an orchestration. Those still follow worker docs.
- Does not enforce any specific frontmatter enrollment — that's per-project. Just call out that `--enable=codegraph-reviewer` (and `--enable=security-quorum` for security-sensitive projects) is the recommended Magento-project default.

## Origin

- Original mandate (the retired wrapper) added 2026-06-20 after parallel-test conflicts surfaced under HCF default.
- Superseded 2026-06-26 to drop the wrapper. Migration to `pb-hcf:wire`. Per-task gating dropped; per-batch review preserved via pipeline.md slot.
- Updated 2026-06-30 for HCF v2.0.0: pipeline.md retired everywhere; enrollment moved to `.claude/agents/<name>.md` frontmatter via `/pb-hcf:wire --enable=<name>`.

See `~/.claude/projects/-home-lucas/memory/feedback_hcf_plan_orchestrate_overlay.md` and `~/.claude/projects/-home-lucas/memory/project_pb_hcf_intro.md` for the decision arc.
