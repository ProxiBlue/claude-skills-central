#!/bin/bash
# UserPromptSubmit hook — reminds the operator to swap to fable before /hcf:plan-create.
#
# Why: plan-create is session-model bound. Fable is high-cost — used sparingly, only
# for main plan authoring. Sub-agents (via Task dispatch) carry their own model
# frontmatter and are unaffected. But when the operator forgets to /model → fable,
# plan-create runs on whatever the session is on (opus / sonnet / haiku), silently
# under-powered.
#
# This hook detects /hcf:plan-create in the submitted prompt and blocks with a
# clear reason — operator must swap the model (/model → fable) and resubmit, OR
# include the bypass token "confirm-fable" anywhere in the prompt to proceed
# (used when the operator has already swapped and knows).
#
# Input: JSON on stdin with { session_id, prompt, ... }
# Output: JSON with hookSpecificOutput.permissionDecision OR decision=block
#
# Fires silently (exit 0, empty stdout) when:
#   - prompt does not match the plan-create pattern
#   - jq missing (best-effort — don't break the session)

set -e

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)
[[ -z "$PROMPT" ]] && exit 0

# Match /hcf:plan-create, hcf:plan-create, or plan-create as a standalone command
# invocation. Case-insensitive.
if ! echo "$PROMPT" | grep -qiE '(^|[[:space:]])/?hcf:plan-create([[:space:]]|$)'; then
  exit 0
fi

# Bypass — operator has confirmed they're on fable
if echo "$PROMPT" | grep -qi 'confirm-fable'; then
  exit 0
fi

# Block with a clear reason. UserPromptSubmit decision=block prevents the prompt
# from being sent to the model; reason is shown to the operator.
cat <<'EOF'
{
  "decision": "block",
  "reason": "FABLE CHECK: /hcf:plan-create should run on fable (high-signal plan authoring — sub-agents carry their own model tier and are unaffected). Two steps to proceed:\n\n  1. Type /model and switch to fable (verify current model — if already fable, step 2 alone).\n  2. Resubmit your prompt with the word 'confirm-fable' anywhere in it (e.g. '/hcf:plan-create 385 confirm-fable') — this bypasses this check for THIS prompt only.\n\nBypass is per-prompt, not per-session — protects against forgetting mid-plan-orchestrate to swap back to opus.\n\nConfigured in ~/claude-skills-central/hooks/fable-reminder.sh. Remove/disable there if the check becomes noise."
}
EOF
