---
paths:
  - "**/*.php"
  - "**/*.phtml"
---

# PHP Debugging Protocol — MANDATORY

When debugging PHP runtime behaviour (a value is wrong, a branch is taken that shouldn't be, a request returns the wrong shape, a test asserts the wrong state, a function returns null when it shouldn't), use the **xdebug-mcp** tools. These give real runtime data instead of guesses.

The plugin is `xdebug@xdebug-mcp` (koriym/xdebug-mcp), seeded into every DDEV project via `~/claude-plugins-central/seed/known_marketplaces.json`. Install with `/plugin install xdebug@xdebug-mcp` if not already present in the current project.

## Tool selection — pick by the question being asked

| Question | Tool |
|---|---|
| "What is `$x` at line N? Why is it that value?" | `xstep --break='<file>:<line>'` |
| "How did execution reach this point? What was the call path?" | `xback --break='<file>:<line>'` or `xtrace` |
| "What is the flow of this request / this script?" | `xtrace` |
| "Why is this slow? Where is time spent?" | `xprofile` |
| "Is this line / branch even reached by the test?" | `xcoverage` |
| "Same call, two inputs — what diverges?" | `xcompare --run-a=… --run-b=…` |

If the question doesn't fit any of those, fall back to reading the code — not to `var_dump`.

## Availability — xdebug/pcov default OFF, load on demand (see xdebug-pcov-defaults.md)

Fleet-wide, xdebug and pcov are NOT loaded by default in either PHP-FPM or PHP-CLI (FPM:
crash risk under real request load; CLI: pure speed cost with no benefit). This is not a
reason to fall back to echo-debugging — it self-heals depending on where the bug lives:

- **CLI target** (phpunit, a script, a cron/queue worker invoked directly, any table above):
  nothing to do. Every xdebug-mcp tool already checks whether xdebug is loaded and appends
  `-dzend_extension=xdebug` to that one invocation if not — CLI is a fresh process per call,
  zero restart cost. Just run the tool.
- **FPM/live-request target** (a bug that only reproduces on an actual page load — e.g.
  something a Playwright test is driving over nginx/FPM): FPM is a persistent daemon, so
  loading xdebug there needs a real extension load + restart. You are running INSIDE the
  container being debugged, with no `ddev` binary or Docker socket, so the host-only
  `ddev xdebug on` will not work here. Use the in-container bracket instead — mounted
  fleet-wide, read-only, at `.claude/scripts/xdebug-fpm-session.sh`:
  ```
  .claude/scripts/xdebug-fpm-session.sh on     # loads it, arms a 900s auto-off safety
  # drive the page load, use xdebug-mcp tools against the DBGp connection on port 9003
  .claude/scripts/xdebug-fpm-session.sh off    # turn it back off — do this before any
                                                # real E2E/Playwright batch runs
  ```
  The auto-off timer self-heals even if you forget — but don't rely on it; leaving FPM
  xdebug on into a real E2E batch is the exact condition that caused the original SIGSEGV
  incident this default came from.

## Order of operations

1. **State which xdebug tool fits the question** and why, in one line.
2. **Run that tool** against the failing/suspect script or test. Capture the JSON output.
3. **Cite the JSON output** (path + variable + value, or trace step) as the evidence for your hypothesis. No citation = no claim.
4. Only if xdebug *cannot* answer the question (e.g. the bug is in static analysis, in a build step, in non-PHP code) — then say so explicitly and fall back to reading code or, as a last resort, adding instrumentation.

## Banned phrases — not allowed unless an xdebug tool has been invoked and cited

The following phrases signal echo-debugging instinct and MUST NOT appear in a response unless `xtrace` / `xstep` / `xprofile` / `xcoverage` / `xback` / `xcompare` has already been run and the output cited:

- "let me add a `var_dump`"
- "I'll `print_r` this to see"
- "drop in a temporary `echo`"
- "add an `error_log` call to check"
- "let me log this out"
- "just to see what it contains"
- "add a `die(var_dump(...))`"
- "let's `dd()` it" / "let's `dump()` it"

If the instinct to write one of these comes up *before* an xdebug tool has been run, that instinct itself is the signal: skip it, pick a tool from the table, run it.

## Banned edits — not allowed in any file under version control

Do not add any of the following to PHP source files as a debugging aid:

- `var_dump(`, `print_r(`, `var_export(` (when used for ad-hoc inspection, not as real output)
- `error_log(` added for debugging only
- `echo` / `print` statements added for debugging only
- `dd(`, `dump(`, `ray(`, `xdebug_break()` left in place
- `die(`, `exit(` used to halt-and-inspect

If one of these is genuinely required as production behaviour, say so explicitly. Otherwise, use the xdebug tool that answers the same question without modifying the file.

## Required self-check before sending any PHP debugging diagnosis

- Has an xdebug tool been run, or has it been explicitly justified why none of them fit?
- Does every claim about a runtime value cite the xdebug JSON output (file + line + variable)?
- Is the response hedging with "probably" / "I think" / "should be" where xdebug could have given a definite answer?

If any answer is "no", stop and run the appropriate xdebug tool first.

## Acceptable admissions

- "Xdebug isn't loaded in this container yet — running `ddev xdebug on` before I can use the tools."
- "xstep can't reach this code path because it only runs in a CLI worker / cron / queue I can't trigger from here — explaining why before falling back to logging."
- "I was wrong earlier — `xstep` shows `$user` is actually `['id'=>0]`, not `null` as I assumed."

## Hard-stop trigger

If the user says "use xdebug", "what does xdebug say", "did you actually step through this", or similar — that is a hard stop. Stop reasoning from the code alone. Run the appropriate xdebug tool, cite its output, then continue.

## Why this exists

PHP echo-debugging is fast to type and almost always slower to truth than `xstep`/`xtrace`. It also pollutes diffs, leaks into commits, and trains a habit of guessing-then-checking instead of measuring-then-knowing. The xdebug-mcp plugin gives runtime data on demand — using it is the default, not the fallback.
