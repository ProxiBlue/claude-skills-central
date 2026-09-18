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

# Nested repo worktrees (test harnesses) live INSIDE $WORKTREE_DIR and must
# come out first.
#
# Note git does NOT protect you here (verified 2026-09-18): `git worktree
# remove` on the parent does not refuse just because another repo's checkout
# sits inside it -- not even without --force. It deletes the directory
# happily, and the nested repo is then left with admin data pointing at a
# path that no longer exists: a "prunable" entry that lingers in its
# `git worktree list` until someone notices and prunes it, and which blocks
# re-using that branch name in a future worktree.
#
# So the ordering below is the whole safeguard, not a nicety.
for rel in $(wtd_nested_symlink_repos "$REPO"); do
  # Even when the nested checkout is already gone (an earlier blind rm, or a
  # worktree created before this provisioning existed), prune so no stale
  # "prunable" entry is left behind holding its branch name hostage.
  if [ ! -e "$WORKTREE_DIR/$rel/.git" ]; then
    git -C "$REPO/$rel" worktree prune 2>/dev/null || true
    continue
  fi
  echo "worktree-ddev: removing nested worktree $rel"
  if [ "$force" = 1 ]; then
    git -C "$REPO/$rel" worktree remove --force "$WORKTREE_DIR/$rel" 2>/dev/null \
      || rm -rf "$WORKTREE_DIR/$rel"
  else
    git -C "$REPO/$rel" worktree remove "$WORKTREE_DIR/$rel" \
      || wtd_die "nested worktree $rel has uncommitted changes -- commit them, or re-run with --force"
  fi
  git -C "$REPO/$rel" worktree prune 2>/dev/null || true
done

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
