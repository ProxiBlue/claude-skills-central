---
paths:
  - "**/*.spec.ts"
  - "**/*.spec.js"
  - "**/playwright.config.ts"
  - "**/test-results/**"
  - "**/playwright-report/**"
---

# Background tasks — never hand-roll the wait

## The rule

**Do not detach work you need the answer to, and never write your own
loop to find out whether it finished.**

Banned outright:

```sh
npx playwright test ... &                        # detached run
nohup vendor/bin/phpunit ... &                   # same thing, louder
while pgrep -f playwright >/dev/null; do sleep 10; done
until [ -f /tmp/run.done ]; do sleep 5; done
while kill -0 "$PID" 2>/dev/null; do sleep 5; done
```

Do this instead:

```sh
npx playwright test tests/vt-billing.spec.ts     # foreground, Bash tool
                                                 # timeout: 600000 (10min cap)
```

Too slow for 10 minutes? **Narrow the run** — one spec, `--filter`,
`--bail` — and only widen once it is green. Narrowing is the fix.
Detaching is not.

## Why

A detached process outlives the tool call that spawned it, so its exit
code dies with the call. Everything you can reach for afterwards is a
proxy, and every proxy fails in the same direction:

| Proxy | How it lies |
|---|---|
| `pgrep -f <pattern>` | Matches your own grep, matches an unrelated reuse of the name, and reports "gone" the instant the process exits — which is also what a crash looks like. |
| `kill -0 $PID` | Tells you alive/dead. Never tells you pass/fail. |
| marker file | Written when the writer decides, not when the work ended. A crash writes nothing, so you wait forever. |
| output-file tail | Partial writes read as "still going"; a truncated file reads as a clean finish. |

None of them carry an exit code. So the agent guesses, and a wrong guess
here is invisible: it sits idle believing it is still waiting. From the
outside — `ListAgents`, `ps`, file mtimes — that is byte-for-byte
identical to a hung worker. Nobody can tell the difference without
asking the agent directly.

## Subagents: structurally unable to recover

Most subagent definitions grant `Read, Write, Edit, Bash, Glob, Grep`
and nothing else — **no `Monitor`, no `BashOutput`, no `TaskOutput`**.
For such an agent a detached process is unrecoverable by construction:
there is no legal tool that can read its result, so the *only* thing it
can write is a banned poll loop. If a run genuinely cannot be done in
the foreground, the subagent must not own it — report back to the
orchestrator (`TASK_FAILED: <reason>`) and let the parent, which has
`Monitor`, run it.

## If you really are launching a daemon

Starting a long-lived server (not a run you need the result of) is the
one legitimate detach. Prefix `CLAUDE_BG_WAIT_ALLOWED=1`, and still do
not poll for liveness with `pgrep` — probe the thing itself
(`curl --retry-connrefused`, `ddev describe`, a port check), which tells
you it is *ready*, not merely *present*.

## Enforcement

`background-wait-guard.sh` (PreToolUse, Bash) blocks both shapes. Per-project
opt-out: add `background-wait-guard` to `<repo>/.claude/rules-disable`.

## Provenance

2026-09-18, chatroom thread `2f0d65cf`, worktree `pvcpipesupplies-491`,
ticket #491. Two `hcf:tdd-worker` subagents in one batch each burned
~50 minutes of wall-clock on self-authored `pgrep` wait loops. The
Playwright run had exited 0 minutes earlier. From the team-lead session:
no node process running, zero file mtimes newer than batch start for 108
minutes — a textbook hung worker, except nothing was hung. Recovered
only when a human asked "how we doing here". tdd-004's own words:

> the background Playwright run had actually finished (exit 0) minutes
> before your status check — my Monitor's pgrep-based wait check was
> buggy and timed out without noticing, so I looked stalled.

See also: `playwright-debugging.md` (trace-first), `investigation.md`
(artefact-before-hypothesis).
