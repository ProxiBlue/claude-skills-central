#!/usr/bin/env bash
# Post a GitHub issue comment then immediately minimize it as off-topic.
# Usage: gh-comment-hidden.sh <repo> <issue_number> <body>
#   repo          e.g. ITToolsAU/LaptopLCDScreen
#   issue_number  e.g. 351
#   body          comment text (quote it)

set -euo pipefail

REPO="${1:?repo required (owner/name)}"
ISSUE="${2:?issue number required}"
BODY="${3:?comment body required}"

# Post the comment and capture the URL
COMMENT_URL=$(gh issue comment "$ISSUE" --repo "$REPO" --body "$BODY")
echo "Posted: $COMMENT_URL"

# Extract the numeric comment ID from the URL (last path segment)
COMMENT_DB_ID=$(echo "$COMMENT_URL" | grep -oE '[0-9]+$')

# Resolve the GraphQL node ID
NODE_ID=$(gh api graphql -f query="{
  repository(owner: \"$(cut -d/ -f1 <<< "$REPO")\", name: \"$(cut -d/ -f2 <<< "$REPO")\") {
    issue(number: $ISSUE) {
      comments(last: 10) {
        nodes { id databaseId }
      }
    }
  }
}" --jq ".data.repository.issue.comments.nodes[] | select(.databaseId == $COMMENT_DB_ID) | .id")

if [[ -z "$NODE_ID" ]]; then
  echo "Warning: could not resolve node ID — comment posted but not minimized" >&2
  exit 0
fi

# Minimize as off-topic
gh api graphql -f query="mutation {
  minimizeComment(input: {subjectId: \"$NODE_ID\", classifier: OFF_TOPIC}) {
    minimizedComment { isMinimized minimizedReason }
  }
}" --jq '.data.minimizeComment.minimizedComment'

echo "Minimized as off-topic (still readable when expanded)"
