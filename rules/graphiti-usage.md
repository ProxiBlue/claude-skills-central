# Graphiti Knowledge Graph — usage discipline

Shared fleet temporal knowledge graph. One host instance (Neo4j on host port 7474/7687, MCP at `http://host.docker.internal:8765/mcp/`). All projects share the database; namespacing is enforced **per call** via `group_id`.

## Scope model — two tiers

Every fact has a SCOPE. Pick at write time:

| Scope | `group_id` value | What goes here |
|---|---|---|
| **fleet** | the literal string `"fleet"` | Cross-project rules, tool-use defaults, methodology, fleet-wide vendor decisions, fleet-wide client/policy rules |
| **project** | the project's stable id (e.g. `ntotankm1`, `lcdscreen`, `pps`) | Project-specific quirks: LIVE-equivalent branch, project-only test commands, module-vendor decisions that don't generalize, per-client preferences |

Pick the project id deterministically:
- Read `$DDEV_PROJECT` env var inside the container (set by DDEV).
- Fall back to `basename $(git rev-parse --show-toplevel)` if unset.
- Never use `default`, `main`, session ids, or random suffixes.

## Hard rules

1. **Before EVERY `add_memory` call: classify and confirm scope with the user.**
   Output ONE line in this exact form, then wait for confirmation:

   ```
   Save to graph — scope: [fleet | project=<id>]. Reply g / p / correction.
   ```

   - `g` (or `global` / `fleet`) → use `group_id="fleet"`.
   - `p` (or `project`) → use the resolved project id from `$DDEV_PROJECT`.
   - Any other reply → treat as a correction; re-classify and re-confirm.

   Default suggestion in your classifier: project unless the fact references multiple projects, names a tool/methodology, or codifies a policy that applies anywhere. When in doubt → ask, don't guess.

2. **Always query BOTH scopes from a project context.** Use `group_ids: ["<project-id>", "fleet"]` on every `search_memory_nodes` / `search_memory_facts` call. This surfaces fleet rules in every project automatically without leaking project A's quirks into project B.

3. **From the host shell (no project context):** query `group_ids: ["fleet"]` only — host sessions shouldn't see any project's local quirks unless the user names a project.

4. **Never query across all projects without an explicit instruction from the user.** A fleet-audit ("look across the fleet") is the only valid reason to omit the `group_ids` filter or pass every project's id.

5. **Graphiti is for DOMAIN facts. Not for hard rules.** Hard rules (caveman, investigation, php-debugging, billing DRAFT-only, vendor blocklists) stay in `~/claude-skills-central/rules/` and `~/.claude/projects/-home-lucas/memory/` because they MUST auto-load every session. Graphiti is queried on-demand, not auto-loaded.

## Fixing a wrong scope after the fact

If a node landed in the wrong group_id, fix it via the Neo4j browser at http://localhost:7474:

```cypher
// Move ONE specific fact by name (preferred — avoids dragging unrelated nodes)
MATCH (n) WHERE n.group_id = '<wrong-id>' AND n.name CONTAINS '<keyword>'
SET n.group_id = '<right-id>'
RETURN n.name, n.group_id;

// Move the relationships attached to a moved node too
MATCH ()-[r]-(n {group_id: '<right-id>'}) WHERE r.group_id = '<wrong-id>'
SET r.group_id = '<right-id>';

// Move the episode that sourced the fact (so provenance stays consistent)
MATCH (ep:Episodic)-[:MENTIONS]->(n {group_id: '<right-id>'})
WHERE ep.group_id = '<wrong-id>'
SET ep.group_id = '<right-id>';
```

Verify before/after with `MATCH (n) RETURN DISTINCT n.group_id, count(*) ORDER BY count(*) DESC`.

## When to WRITE to Graphiti

Write an episode when you learn ANY of:
- A decision with rationale ("we squash-merge to live because rollback is one `git revert`")
- A non-obvious project quirk ("ntotank's LIVE-equivalent is `uat`, ntotankM1's is literal `live`")
- An incident root cause ("DISPLAY=:0 lost during 2026-06-04 Lapce sweep; carrier moved to mounts.yaml")
- A vendor / module verdict ("Anowave blocked", "Mageplaza_OrderLabels OK for PVC")
- A client preference ("billing invoices always DRAFT", "PR comments minimized as off-topic")
- A repeatable runbook step ("re-run pb-codegraph index after composer require")

Don't write:
- Ephemeral session state, in-progress task lists
- Information directly readable from `git log` / `git blame` / current file state
- Restatements of CLAUDE.md content

## When to READ from Graphiti

Read at the start of any task that touches:
- A project area you haven't touched in this session (`search_memory_nodes` with the area name)
- A vendor / module / extension before recommending it
- A branching / deploy / merge step (check for project-specific rules)
- A decision that looks like it might already have a precedent

Cite the Graphiti episode UUID + summary when acting on a recalled fact, same as artefact citation in the investigation protocol.

## Search discipline — exhaust strategies before blaming ingest

When a Graphiti search returns thin or no results, do NOT conclude "the data isn't in the graph". The default failure mode is search-method, not ingest-gap. Verify before claiming missing.

**Mandatory sequence before saying "not in graphiti":**

1. **Try `search_memory_facts` AND `search_nodes` for the SAME query.** They index differently. A fact about ticket #262 may have no entity NODE called `ticket #262`, yet the facts that describe its root cause (`AvaTax helper`, `Uptactics TaxCompanyValue module`) ARE indexable.
2. **Re-query with synonyms.** Domain vocabulary varies — `payment failure` won't match a fact phrased `infinite loop in checkout`. Try 3–4 phrasings: the ticket number, the symptom, the module/vendor name, the dated event.
3. **Search for known entity names directly.** If you know an incident touched `Avalara AvaTax` or `Braintree`, do `search_nodes(query="Avalara AvaTax")` and read its summary. Entity nodes rank well; substring matches inside fact bodies do not.
4. **Scope bi-temporally.** Use `valid_at_min` / `valid_at_max` to control whether you see active facts only or historical ones too. **Facts marked `invalid_at: <date>` are de-prioritized by default** — they're not gone; they're superseded. To find resolved/old incidents, widen the time window or explicitly query the invalidated set.
5. **Check `get_episodes` and existing entities** before writing a new entity. A new `ticket #X` node created during the same session may falsely look like "graphiti finally has it" — when in fact the fact-level data was there all along (just not as a named node).

If you've done all 5 and STILL come up empty: that's evidence-based "not in graphiti". Otherwise the deficit is at the searcher, not the writer.

**Banned phrases — not allowed until the 5-step sequence has been run and cited:**

- "graphiti returned generic facts"
- "tickets are not ingested"
- "the cron isn't writing"
- "data is missing from the knowledge graph"
- "graphiti doesn't have this"

If the instinct to write one of these arises before the 5 steps are done, that instinct itself is the signal — go run the steps.

## Tool call shape

Adding an episode (AFTER scope confirmation per Hard Rule 1):
```
add_memory(
  group_id="fleet",                                # or the project id (ntotankm1, lcdscreen, pps, ...)
  name="<short title>",
  episode_body="<the fact, with Why + How to apply>",
  source="text",
  source_description="claude-code session <date>"
)
```

Searching from inside a project context (always pass BOTH project + fleet):
```
search_memory_nodes(group_ids=["<project-id>", "fleet"], query="<your question>")
search_memory_facts(group_ids=["<project-id>", "fleet"], query="<relationship you need>")
```

Searching from a host shell (no project context):
```
search_memory_nodes(group_ids=["fleet"], query="<your question>")
```

## Why this exists

Flat-file memory at `~/.claude/projects/-home-lucas/memory/` scales to ~50 facts before the index becomes unreadable. Domain knowledge across 12 ddev projects easily hits 500+. Graphiti handles supersession (X was true until time T, then Y) and cross-fact retrieval (entity-relation queries) natively. Pairs with pb-codegraph the way a brain pairs with a nervous system: codegraph = structural code graph, Graphiti = domain knowledge graph.
