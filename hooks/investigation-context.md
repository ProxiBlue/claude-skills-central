TEST FAILURE DETECTED — investigation protocol now in force (injected by test-failure-context.sh):

ORDER — no skipping:
1. Blast radius FIRST: `git diff --stat HEAD` + `git status`. State own session changes, one line per file.
2. Read ALL failure artefacts — every file the runner produced (stdout/stderr, results, fixtures, screenshots, traces). Not a sample.
3. Compare to prior passing run if artefacts exist; cite timestamp. No prior run → say so.
4. Only NOW hypothesise. Every claim cites path + line/key. No citation = no claim.

BANNED without a cited artefact: "not my code", "not caused by my changes", "environmental", "pre-existing issue", "infrastructure down", "must be a flake". Instinct to say one = signal steps 1–3 skipped.

REPORT FORMAT: WHAT I CHANGED THIS SESSION / WHAT THE ARTEFACTS SHOW / COMPARE TO PRIOR RUN / HYPOTHESIS (with evidence) / WHAT I HAVE NOT VERIFIED.

Fine to say: "don't know yet — reading logs now" / "my change at <file>:<line> could plausibly cause this; ruling out via <X>".

Full protocol: rules/reference/investigation.md (claude-skills-central).
