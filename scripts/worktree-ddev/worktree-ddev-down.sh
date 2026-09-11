#!/usr/bin/env bash
# Tear down a per-ticket worktree+ddev instance created by worktree-ddev-up.sh.
#
# Usage: worktree-ddev-down.sh <project-name> [--delete-branch] [--force]
#
#   project-name    the full ddev project name printed by worktree-ddev-up.sh
#                    ("<source-project>-<ticket-id>"), used as the state-file
#                    key -- not just the bare ticket-id, since state is keyed
#                    by project name.
#   --delete-branch  also delete the git branch after removing the worktree
#                    (default: branch is kept, e.g. for an already-open PR)
#   --force          remove the worktree even if it has uncommitted changes
#                    (git worktree remove --force). Default refuses on dirty.
#
# Deletes the ddev project (containers + its db volume; no snapshot is taken
# -- run `ddev snapshot` yourself first if you want one), then removes the
# git worktree, then the state file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

[ $# -ge 1 ] || wtd_die "usage: worktree-ddev-down.sh <project-name> [--delete-branch] [--force]"
project=$1; shift
delete_branch=0
force=0
for arg in "$@"; do
  case "$arg" in
    --delete-branch) delete_branch=1 ;;
    --force) force=1 ;;
    *) wtd_die "unknown flag: $arg" ;;
  esac
done

wtd_require_host

state_file=$(wtd_state_file "$project")
[ -f "$state_file" ] || wtd_die "no state file for '$project' ($state_file) -- was it created by worktree-ddev-up.sh?"
# shellcheck disable=SC1090
source "$state_file"
: "${REPO:?state file missing REPO}" "${WORKTREE_DIR:?state file missing WORKTREE_DIR}" "${PROJECT_NAME:?}" "${BRANCH:?}"

[ -d "$WORKTREE_DIR" ] || wtd_die "worktree dir gone ($WORKTREE_DIR) but state file remains -- clean up manually: $state_file"

if [ "$force" != 1 ]; then
  if [ -n "$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null)" ]; then
    wtd_die "$WORKTREE_DIR has uncommitted changes -- commit/stash first, or re-run with --force to discard"
  fi
fi

echo "worktree-ddev: deleting ddev project $PROJECT_NAME"
ddev delete -Oy "$PROJECT_NAME" 2>&1 | grep -v '^$' || true

echo "worktree-ddev: removing worktree $WORKTREE_DIR"
if [ "$force" = 1 ]; then
  git -C "$REPO" worktree remove --force "$WORKTREE_DIR"
else
  git -C "$REPO" worktree remove "$WORKTREE_DIR"
fi

if [ "$delete_branch" = 1 ]; then
  echo "worktree-ddev: deleting branch $BRANCH"
  git -C "$REPO" branch -D "$BRANCH" || echo "worktree-ddev: WARNING could not delete branch $BRANCH (merged upstream? check manually)"
fi

rm -f "$state_file"
echo "worktree-ddev: done ($PROJECT_NAME torn down)"
