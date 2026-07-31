# Codegraph-First Protocol — MANDATORY

When a task involves planning, investigation, impact analysis, "find where X is used / defined / wired", or any completeness question over Magento/PHP code, query the pb-codegraph MCP server FIRST — before grep, before Glob, before reading files. Grep misses Magento's XML-driven indirection (plugins, observers, DI preferences, layout hooks); the code graph carries those as first-class edges.

## Availability check (once per session)

`mcp__pb-codegraph__list_repos` — non-empty repo list = available; cache the result. If the server/tools are absent (project not wired: no `.ddev/pb-codegraph/registry.json`), fall back to grep/read and SAY SO — do not silently pretend graph-grade completeness.

## Tool selection

| Question | Tool |
|---|---|
| "Where is class/method X defined? What's its signature?" | `mcp__pb-codegraph__find_symbol` |
| "What breaks if I change X? Who depends on it (incl. plugins/observers/preferences)?" | `mcp__pb-codegraph__impact` |
| "What surrounds X — callers, callees, wiring neighbors?" | `mcp__pb-codegraph__context` |
| "Which plugins wrap X / observers listen to event E / routes hit controller C?" | `mcp__pb-codegraph__query` (named templates: wired_plugins_on, observers_of_event, routes_to, preferences_for, callers_of, dead_symbols) |
| "What's indexed? Is the project repo loaded?" | `mcp__pb-codegraph__list_repos` |

Pass `repo:` when you know the scope (`m2_<project>`, `mageos`, `hyva`, `deps`); omit it to federate across all registered repos (results are repo-tagged).

## Rules

1. Query the graph BEFORE grep on any structural question. Cite the tool + result in your reply, same citation discipline as the investigation protocol.
2. A staleness banner on `impact` output means the Magento edges lag the index — re-run `pb-codegraph augment` (or `pb-codegraph index`) before trusting wiring results; with `PB_CODEGRAPH_STRICT_STALENESS=1` impact refuses instead.
3. Index vs source conflict → trust SOURCE, note the drift, re-index.
4. Cross-repo call edges do not exist (federation is query-merge): a custom class extending a core class resolves to an `external` placeholder in the project repo. For runtime-resolved truth (enabled-module DI/plugin chains in THIS env), bricklayer is the arbiter — see the bricklayer playbook.

## Banned until the graph has been queried (or unavailability stated)

- "grep shows no callers, so it's unused"
- "I searched the codebase and found nothing referencing X"
- any completeness claim ("all callers", "nothing depends on this") sourced from grep alone
