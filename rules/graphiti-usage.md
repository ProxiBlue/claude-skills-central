# Graphiti — always-on core

Full discipline lives in the plugin skill **`pb-graphiti:graphiti-usage`** — invoke it before non-trivial graph work (writes, scope fixes, bulk recall, ingest tuning, wrong-scope repair). Only this core is always-loaded.

1. **Before EVERY in-conversation `add_memory`:** classify scope and confirm with the user, one line, then wait:
   `Save to graph — scope: [fleet | host | project=<id>]. Reply g / h / p / correction.`
   Project id = `$DDEV_PROJECT`, else `basename $(git rev-parse --show-toplevel)`. Never `default`, `main`, or session ids. (Plugin's non-interactive consolidation hooks are exempt — they resolve scope deterministically.)
2. **Query scoping:** from a project → `group_ids=["<project-id>", "fleet"]`. From host shell → `["host", "fleet"]`. Never query unscoped / across all projects without explicit user instruction.
3. **Graphiti = domain facts, not hard rules.** Anything that must auto-load every session stays in `rules/` or flat-file memory; the graph is queried on demand.
4. **Thin results ≠ missing data.** Before claiming anything is "not in graphiti", run the 5-step search discipline in the skill (facts+nodes, synonyms, entity names, bi-temporal widening, get_episodes). Phrases like "not ingested" / "data missing from the graph" are banned until then.
5. **Cite recalled facts** when acting on them: append `[src: <source_description or episode UUID>]`.
