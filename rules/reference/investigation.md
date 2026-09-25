---
paths:
  - "**/*.log"
  - "**/var/log/**"
  - "**/test-results/**"
  - "**/playwright-report/**"
---

# Investigation Protocol — MANDATORY

When a test fails, a system errors, or the user reports a bug, behave as follows. These steps are not guidance — they are mandatory. Skipping any of them is the exact failure mode being banned here.

## Order of operations — NO SKIPPING

1. **Enumerate own blast radius FIRST.**
   Run `git diff --stat HEAD` and `git status`. State out loud what has been changed this session, by file, in one line each. This is the first move on every failure, every time.

2. **Read ALL failure artefacts — not a sample.**
   - Test failures: every file the test runner produced for the failing case (stdout/stderr capture, result files, recorded fixtures, screenshots, traces). Not a sample — every file.
   - Unit failures: the failing test file, the class under test, the fixture the test used.
   - Runtime errors: the actual error log, the request log, and the log of any downstream service invoked during the failure window.
   - **Runtime errors, also MANDATORY: ask Bugsink.** `var/log` holds what Magento chose to write; Bugsink holds the captured exception with its chain, frames, request context and release tag — including errors thrown on uat/live and by cron/queue workers you cannot re-run. Grepping logs while ignoring a tracker that already has the stacktrace is the same failure this protocol bans.

     ```bash
     source ~/.pb-hcf/bugsink.env 2>/dev/null || source .claude/bugsink.env
     BS="$BUGSINK_URL_CONTAINER"   # in a ddev container; $BUGSINK_URL_HOST on the host
     curl -s -H "Authorization: Bearer $BUGSINK_API_TOKEN" "$BS/api/canonical/0/issues/?project=<id>"
     curl -s -H "Authorization: Bearer $BUGSINK_API_TOKEN" "$BS/api/canonical/0/events/?issue=<issue-uuid>"
     ```

     One Bugsink project per ENVIRONMENT — dev/ddev, uat and prod are separate projects with separate ids, so a wrong id answers the wrong question rather than erroring. Per-project ids and queries: that project's `.claude/bugsink.md`. Cite `friendly_id` plus the top **in-app** frame `file:line`, never a framework frame. No env file where you are running, or no Bugsink project for this repo → say that plainly and skip; never guess at error state.

3. **Compare to a prior passing run** if artefacts exist. If the same "broken" state existed before this session, say so with the timestamp as evidence. If no prior run exists, say that.

4. **Only NOW form a hypothesis.** State the hypothesis paired with the evidence line that supports it. Every claim must cite a path + line or key. No citation = no claim.

Skipping steps 1–3 and jumping to step 4 is the behaviour being banned.

## Banned phrases — not allowed until a specific artefact has been cited

The following are flagged as blame-shift phrases and MUST NOT appear in a response unless a specific artefact reference has just been cited that supports them:

- "not my code"
- "not caused by my changes"
- "this is environmental"
- "this is a pre-existing issue"
- "not a code bug"
- "infrastructure is down"
- "external service is broken"
- "must be a flake"
- "not my fault"

If the instinct to write one of these comes up *before* steps 1–3 are done, that instinct itself is the signal: steps 1–3 have been skipped. Go do them.

## Required self-check before sending any diagnosis

Before sending a response that contains a diagnosis of a failure, re-read the draft and answer:

- Does every claim cite a specific artefact (file path + line, or key) as evidence?
- Has what was personally changed this session been stated?
- Have own changes been ruled out with evidence, or just by assumption?
- Is the draft hedging with "likely" / "probably" / "seems" where it has not actually checked?

If any answer is "no", go back and do the check. Do not send a speculative diagnosis dressed up as a confident one.

## Mandated failure-report format

Every failure investigation reply must follow this structure:

```
WHAT I CHANGED THIS SESSION (from git diff):
  - <file>: <one line on what>

WHAT THE ARTEFACTS SHOW:
  - <path>: <exact finding>
  - <path>: <exact finding>

COMPARE TO PRIOR RUN:
  - <prior path>: <same state / different state> — or "no prior run"

HYPOTHESIS (with evidence):
  - <claim> — supported by <artefact line/key>

WHAT I HAVE NOT VERIFIED:
  - <gap> — or "nothing, hypothesis is evidence-complete"
```

If "WHAT I HAVE NOT VERIFIED" is empty and certainty is claimed, say so explicitly.

## Acceptable admissions

These are always fine and should be used in place of speculation:

- "I don't know yet — reading the logs now."
- "My change at `<file>:<line>` could plausibly have caused this; ruling out by checking <X>."
- "I was wrong earlier — the evidence says <Y>." (Replaces the earlier wrong claim, does not sit beside it.)

## Hidden issues — the errors nobody reported

Everything above is reactive: something visibly failed. Bugsink also answers the
question nobody asked, which is where the real damage hides — an exception that
throws on every checkout while the page still renders, a queue consumer dying
silently, a fatal only logged-out customers hit. No test asserts it and no user
reports it, so it survives every green suite.

So after landing a change that touches runtime behaviour, sweep for what is NEW
rather than only for what was reported:

```bash
source ~/.pb-hcf/bugsink.env 2>/dev/null || source .claude/bugsink.env
BS="$BUGSINK_URL_CONTAINER"
curl -s -H "Authorization: Bearer $BUGSINK_API_TOKEN" "$BS/api/canonical/0/issues/?project=<id>" \
  | jq -r '.results[] | select(.first_seen > "<when this work started>")
      | [.friendly_id, .calculated_type, .calculated_value[:70], .digested_event_count] | @tsv'
```

Two signals worth naming explicitly, because both read as "fine" at a glance:

- **A regression is an issue marked resolved whose `last_seen` is after its fix
  date.** Report it with both timestamps, not as a new bug.
- **Frequency is severity.** A `digested_event_count` climbing fast on a quiet
  issue outranks a scary-looking exception seen once, and trend is the one thing
  a log grep cannot tell you.

Under HCF this sweep is already automated and must not be duplicated by hand:
the `issue-sentinel` agent runs post-batch (order 30), queries `first_seen` since
its own rolling batch marker filtered by `HCF_RELEASE`, and writes a
`_issue_sentinel.md` verdict to the plan dir. Outside an orchestrated batch —
a one-off fix, a hotfix, a manual verification pass — nothing runs it for you,
and this section is the manual equivalent.

## Hard-stop trigger

If the user says "investigate properly", "look at it", "did you actually check", or similar — that is a hard stop. Discard the current hypothesis entirely, restart from step 1. Do not patch the existing hypothesis with one more fact.

## Why this exists

The post-2.1.110 harness regression causes jump-to-conclusion behaviour: hypothesise without checking own changes, blame-shift to infrastructure, deny prior edits. This protocol restores the investigate-first discipline that used to be default. Each skipped step = a misfire that burns tokens and user trust. Being wrong is fine; being wrong because basic diagnostic steps were skipped is not.
