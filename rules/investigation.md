# Investigation Protocol — MANDATORY

When a test fails, a system errors, or the user reports a bug, behave as follows. These steps are not guidance — they are mandatory. Skipping any of them is the exact failure mode being banned here.

## Order of operations — NO SKIPPING

1. **Enumerate own blast radius FIRST.**
   Run `git diff --stat HEAD` and `git status`. State out loud what has been changed this session, by file, in one line each. This is the first move on every failure, every time.

2. **Read ALL failure artefacts — not a sample.**
   - Test failures: every file the test runner produced for the failing case (stdout/stderr capture, result files, recorded fixtures, screenshots, traces). Not a sample — every file.
   - Unit failures: the failing test file, the class under test, the fixture the test used.
   - Runtime errors: the actual error log, the request log, and the log of any downstream service invoked during the failure window.

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

## Hard-stop trigger

If the user says "investigate properly", "look at it", "did you actually check", or similar — that is a hard stop. Discard the current hypothesis entirely, restart from step 1. Do not patch the existing hypothesis with one more fact.

## Why this exists

The post-2.1.110 harness regression causes jump-to-conclusion behaviour: hypothesise without checking own changes, blame-shift to infrastructure, deny prior edits. This protocol restores the investigate-first discipline that used to be default. Each skipped step = a misfire that burns tokens and user trust. Being wrong is fine; being wrong because basic diagnostic steps were skipped is not.
