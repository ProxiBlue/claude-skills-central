#!/usr/bin/env bash
# Spin up an isolated per-ticket checkout: a git worktree + its own ddev
# project (own containers, own DB, own URL), DB seeded from the source
# project's current data. This is the default way to start work on a ticket
# -- not a fallback path alongside branch-switch-in-place on one shared ddev
# instance, that model is retired.
#
# Usage: worktree-ddev-up.sh <repo-path> <ticket-id> [existing-branch-name]
#
#   repo-path           path to the SOURCE repo (the one with .ddev/config.yaml)
#   ticket-id           lowercase alnum+hyphen, e.g. "465". Becomes the branch
#                        name (unless [existing-branch-name] given), the
#                        worktree dir suffix, and the new ddev project-name
#                        suffix: "<source-project-name>-<ticket-id>"
#   existing-branch-name optional: attach to an already-existing branch
#                        instead of creating "<ticket-id>" fresh
#
# Result: sibling directory "<repo-parent>/<source-project-name>-<ticket-id>"
# containing the worktree, a running ddev project of the same name, DB copied
# from the source project's live data via export-db/import-db (works whether
# or not the source project uses ddev snapshots).
#
# Must run on the HOST (see common.sh wtd_require_host) -- ddev-in-ddev is not
# a supported path; there's no imperative "run this on the host" ddev
# primitive to shell out through from inside a container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

[ $# -ge 2 ] || wtd_die "usage: worktree-ddev-up.sh <repo-path> <ticket-id> [existing-branch-name]"
repo_arg=$1
ticket_id=$2
existing_branch=${3:-}

wtd_require_host

repo=$(cd "$repo_arg" 2>/dev/null && pwd) || wtd_die "no such repo path: $repo_arg"
[ -f "$repo/.ddev/config.yaml" ] || wtd_die "$repo has no .ddev/config.yaml -- not a ddev project"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || wtd_die "$repo is not a git repo"

wtd_valid_ticket_id "$ticket_id" || wtd_die "ticket-id must be lowercase alnum/hyphen (got: $ticket_id)"

src_project=$(wtd_ddev_project_name "$repo")
new_project="${src_project}-${ticket_id}"
worktree_dir="$(dirname "$repo")/${new_project}"
branch="${existing_branch:-$ticket_id}"

[ -e "$worktree_dir" ] && wtd_die "already exists: $worktree_dir"

state_file=$(wtd_state_file "$new_project")
[ -e "$state_file" ] && wtd_die "state file already exists for $new_project ($state_file) -- run worktree-ddev-down.sh first if this is stale"

echo "worktree-ddev: creating worktree $worktree_dir"
# Hooks disabled for this checkout: a fresh worktree has no vendor/ yet, so any
# composer-bin-driven hook (e.g. captainhook's post-checkout) fails before
# `ddev start`/composer install even run. Project hooks belong post-setup, not
# during worktree creation.
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  git -c core.hooksPath=/dev/null -C "$repo" worktree add "$worktree_dir" "$branch"
else
  git -c core.hooksPath=/dev/null -C "$repo" worktree add "$worktree_dir" -b "$branch"
fi

echo "worktree-ddev: configuring ddev project '$new_project'"
# Do NOT use `ddev config --project-name=` here -- it rewrites the TRACKED
# .ddev/config.yaml, and `update-index --skip-worktree` to hide that from git
# is NOT reliable protection: a later merge or branch checkout run inside
# this same worktree (e.g. merging the finished ticket into uat/live from
# here instead of from trunk) can silently overwrite the file back to
# whatever the new branch tracks, snapping the project name back to the
# TRUNK's name. Found 2026-09-12 (#462) -- ddev then refuses to
# restart/reconfigure ("a project already exists ... created at <trunk
# path>"), and `ddev claude`/exec behavior in that state is unreliable.
# ddev's own config.local.yaml is the robust mechanism: untracked (already in
# .ddev/.gitignore by ddev's own convention), never touched by any git
# operation, and overlaid on top of config.yaml automatically.
mkdir -p "$worktree_dir/.ddev"
cat > "$worktree_dir/.ddev/config.local.yaml" <<EOF
name: ${new_project}
EOF

# A linked worktree's .git is just a pointer file --
# "gitdir: <repo>/.git/worktrees/<name>" -- to the TRUNK repo's git dir on
# host. ddev only bind-mounts the worktree's own directory, so without this,
# every git command inside the container (status/diff/commit) fails with
# "not a git repository": the path the pointer names doesn't exist in there.
# Mount the trunk's .git at the identical absolute host path so it resolves.
#
# extra_hosts: *.ddev.site DNS resolution INSIDE a ddev container is not
# reliable -- it can resolve to 127.0.0.1 (correct, direct to this
# container's own nginx) or to ddev-router's actual container IP on the
# shared docker network (wrong -- the router only has this project's vhost
# registered on its external/host-facing port, so anything hitting it
# on-network gets a router-level 404 that never reaches the app at all).
# Observed non-deterministically across restarts 2026-09-12 (#462) -- static
# extra_hosts removes the DNS lookup entirely, so it can't flip.
cat > "$worktree_dir/.ddev/docker-compose.git-worktree.yaml" <<EOF
services:
  web:
    volumes:
      - "${repo}/.git:${repo}/.git"
    environment:
      - CURRENT_TICKET=${ticket_id}
      # DDEV_PROJECT here is ticket-suffixed (e.g. pvcpipesupplies-465), but
      # the graphiti knowledge graph must stay unified under the trunk's real
      # project name -- see ~/claude-skills-central/rules/graphiti-usage.md.
      - GRAPHITI_GROUP_ID=${src_project}
    extra_hosts:
      - "${new_project}.ddev.site:127.0.0.1"
      - "novarnish.${new_project}.ddev.site:127.0.0.1"
EOF

# Fix at the source rather than reactively: .ddev/claude-code/.claude/ is
# gitignored, so it doesn't exist yet in a fresh worktree -- whichever
# container-init step creates it first "wins" ownership, and some root-context
# step beats the ddev-user post-start hooks to it, leaving it root-owned and
# silently breaking every hook that writes there (OAuth credential
# persistence, plugin-marketplace sync, etc.) with no visible error. Since
# the host user's uid matches the container user's uid 1:1 (ddev convention),
# pre-creating it from the HOST before `ddev start` ever runs means it
# already exists with correct ownership when the container starts, so
# nothing else ever gets the chance to create-and-own it wrong.
mkdir -p "$worktree_dir/.ddev/claude-code/.claude"

echo "worktree-ddev: starting $new_project"
(cd "$worktree_dir" && ddev start)

# A brand-new ddev project name gets a fresh, empty npm global-package cache
# (ddev keys it by project name under /mnt/ddev-global-cache/n_prefix/), so
# any project's install-claude-code.sh-style hook that assumes a fixed path
# like /usr/local/bin/claude silently installs somewhere PATH doesn't cover.
# Symlink whatever actually got installed into ~/bin and ~/.local/bin (both
# already on PATH in a login shell) so `ddev claude`/`ddev . claude` works.
if ddev describe "$new_project" >/dev/null 2>&1; then
  (cd "$worktree_dir" && ddev exec '
    root=$(npm root -g 2>/dev/null)
    bin="${root%/lib/node_modules}/bin/claude"
    if [ -x "$bin" ]; then
      mkdir -p ~/bin ~/.local/bin
      ln -sf "$bin" ~/.local/bin/claude
      ln -sf "$bin" ~/bin/claude
    fi
  ' >/dev/null 2>&1) || true

  # A fresh worktree's .ddev/claude-code/ (where Claude Code's own OAuth
  # credentials persist, via the ~/.claude and ~/.claude.json symlinks) gets
  # created root-owned by some root-context container init step, before the
  # ddev-user post-start hooks that populate it ever run -- silently
  # blocking every future write, including auth, with no visible error.
  # `docker exec -u root` fixes it without needing host sudo. A couple of
  # individually read-only bind-mounted seed files (CLAUDE.md, mcp.json) may
  # still fail to chown here -- that's fine, they're meant to be immutable;
  # only the directory itself needs to be writable.
  docker exec -u root "ddev-${new_project}-web" chown -R "$(id -un)":"$(id -gn)" /var/www/html/.ddev/claude-code >/dev/null 2>&1 || true
fi

db_seeded=0
if ddev describe "$src_project" >/dev/null 2>&1; then
  echo "worktree-ddev: seeding DB from $src_project"
  dump="$(mktemp -u /tmp/wtd-dbseed-XXXXXX.sql.gz)"
  if ddev export-db "$src_project" -f "$dump" >/dev/null 2>&1; then
    (cd "$worktree_dir" && ddev import-db "$new_project" --file="$dump" >/dev/null 2>&1) && db_seeded=1
    rm -f "$dump"
  fi
  [ "$db_seeded" = 1 ] || echo "worktree-ddev: WARNING db seed failed, new project has ddev's default empty/init db"
else
  echo "worktree-ddev: WARNING source project '$src_project' is not running, skipped DB seed (start it and re-run 'ddev import-db' manually if needed)"
fi

{
  printf 'REPO=%q\n' "$repo"
  printf 'WORKTREE_DIR=%q\n' "$worktree_dir"
  printf 'PROJECT_NAME=%q\n' "$new_project"
  printf 'BRANCH=%q\n' "$branch"
  printf 'DB_SEEDED=%q\n' "$db_seeded"
} > "$state_file"

url=$(cd "$worktree_dir" && ddev describe -j 2>/dev/null | jq -r '.raw.primary_url // empty')
echo "worktree-ddev: ready"
echo "  project:   $new_project"
echo "  branch:    $branch"
echo "  dir:       $worktree_dir"
echo "  url:       ${url:-'(run: ddev describe)'}"
echo "  db seeded: $([ "$db_seeded" = 1 ] && echo yes || echo NO -- see warning above)"
