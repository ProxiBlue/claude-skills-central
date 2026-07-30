# Gitnexus-First Protocol — MANDATORY

For any task involving planning, investigation, refactor scoping, impact analysis, "find where X is used", "what calls Y", "what does Z touch", or completeness-of-code questions: **query gitnexus first**. Code-graph data is the floor, not the ceiling. Reading files and grepping are valid follow-ups; they are not valid substitutes.

This rule pairs with `investigation.md` (which mandates checking own blast radius first) and `php-debugging.md` (which mandates xdebug for runtime questions). Gitnexus is the *static-structure* counterpart: it answers "what is connected to what" before any code is read.

## When this rule fires

Fire on any of:

- Planning a change ("how should we approach refactoring `Foo`?", "what would adding `bar` touch?")
- Investigation that needs code structure (a bug report that names a class/method, "why does `X` happen when `Y` runs?")
- Completeness checks ("did we cover all call sites?", "are there other consumers of this?")
- Symbol lookup ("where is `SomeClass::doThing` defined / used?")
- Impact analysis before a deletion, rename, signature change, interface change, observer/event removal
- Onboarding to a part of the codebase ("walk me through how `X` flows")

Skip only when the question is genuinely non-structural: pure styling, single-file local edits the user already pinpointed, runtime-value questions (those go to xdebug), or non-PHP code outside any indexed repo.

## Order of operations — NO SKIPPING

1. **Detect availability.** Check whether `mcp__gitnexus*__*` tools are present in this session. If not present, see *Availability fallback* below — do not silently skip to grep.
2. **Identify the repo.** Run `list_repos` once per session (cache the answer) to confirm the index name for the current project. Memory may name it (e.g. `ai_assistant`, `@mageos-project`) but verify, because indexes get renamed.
3. **Query gitnexus FIRST** with the tool that fits the question (table below). Capture the output.
4. **Cite the gitnexus result** (symbol id, file:line from the graph, edge type) as the evidence for the next step. No citation = no claim about structure.
5. **Then, and only then,** open files / grep / read to fill gaps gitnexus can't answer (literal string matches, comments, config values, non-indexed paths).

Jumping to `grep` / `find` / `Read` for a structural question before step 3 is the behaviour being banned.

## Tool selection — pick by the question being asked

| Question | Tool |
|---|---|
| "Where is symbol `X` defined? What's its shape?" | `find_symbol` |
| "What would break if I change/remove `X`?" | `impact` |
| "What's the surrounding code-graph context of `X` (callers, callees, neighbours)?" | `context` |
| "Free-form structural query across the graph" | `query` |
| "Which repos / indexes are available?" | `list_repos` |

Pass `repo: <name>` on every call. Federated queries (`@mageos-project`) only when the question genuinely spans repos — otherwise scope down to keep noise low.

## Banned phrases — not allowed unless gitnexus has been queried and cited

These signal grep-first instinct and MUST NOT appear in a response until a gitnexus tool has been invoked and its output cited:

- "let me grep for"
- "I'll search the codebase for"
- "let me find all usages of"
- "let me look for callers of"
- "I'll check where this is used"
- "let me trace the call sites"
- "scanning the repo for"
- "let me search for references to"

If the instinct to write one of these comes up *before* gitnexus has been queried, that instinct itself is the signal: pick a tool from the table above and run it first.

## Availability fallback — when gitnexus is NOT mounted

If `mcp__gitnexus*__*` tools are NOT visible in the current session, do this — do NOT silently grep:

1. State explicitly: "Gitnexus MCP is not mounted in this project — structural queries will be grep-based and may miss indirect callers / DI wiring / dynamic dispatch."
2. Offer to wire it: `/pb-gitnexus:wire` for Mage-OS projects, or the hand-wire pattern (ddev-addon + `.gitnexusignore` + hand-written `.claude/gitnexus.md`) for non-Mage-OS PHP projects. See memory `project_ai_assistant_gitnexus.md` for the bypass recipe.
3. Proceed with grep/read but flag the limitation in the diagnosis: structural claims are best-effort, not graph-verified.

If the project is genuinely non-PHP (no PHP source tree at all), say so and skip gitnexus entirely — that's the one acceptable silent skip.

## Required self-check before sending any planning / investigation / impact claim

- Was a gitnexus tool run (or its absence explicitly justified)?
- Does every structural claim ("X calls Y", "Z is only used here", "nothing else depends on this") cite a gitnexus result?
- Is the response hedging with "I think nothing else uses this" / "probably no other callers" where `impact` could give a definite answer?
- If gitnexus was unavailable, was that flagged to the user, not glossed over?

If any answer is "no", stop and run the appropriate tool (or flag the absence) before sending.

## Acceptable admissions

- "Gitnexus isn't indexed for this part of the tree yet — running `list_repos` to confirm, then falling back to grep with the limitation flagged."
- "`impact` on `Foo::bar` returned zero edges, which is suspicious — double-checking with grep before trusting it."
- "I was wrong earlier — `find_symbol` shows `Foo` is defined in `vendor/` not `src/`, so the refactor scope is different."

## Hard-stop trigger

If the user says "use gitnexus", "what does gitnexus say", "did you actually graph this", "check impact", or similar — that is a hard stop. Stop reasoning from grep/read alone. Run the appropriate gitnexus tool, cite its output, then continue.

## Why this exists

Grep finds literal strings. Gitnexus finds *structure*: callers, implementers, observers, DI bindings, interface graphs — the things that grep misses by definition. A "complete" investigation that skipped the graph is incomplete by construction. Using gitnexus first is the default, not the fallback; reverse the habit.
