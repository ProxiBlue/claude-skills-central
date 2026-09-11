#!/usr/bin/env bash
# Shared helpers for worktree-ddev-{up,down}.sh. Source, don't execute.
#
# Naming convention (permanent, no legacy shim): a ticket's isolated checkout
# lives at "<repo-parent>/<source-ddev-project-name>-<ticket-id>", and its ddev
# project is named identically. Ticket-id must therefore be filesystem- and
# ddev-project-name-safe: lowercase alnum + hyphens only.
set -u

WTD_STATE_DIR="${WTD_STATE_DIR:-$HOME/.claude/worktree-ddev/state}"
mkdir -p "$WTD_STATE_DIR"

wtd_die() { echo "worktree-ddev: $*" >&2; exit 1; }

# Refuses to run from inside a ddev web container. There is no general-purpose
# "run this arbitrary command on the host from inside the container" primitive
# in ddev — `exec-host` only fires as a hook *type* inside a project's own
# hooks.post-start/etc lifecycle, it is not an imperative passthrough. So
# spinning a sibling ddev project has to happen host-side, full stop.
wtd_require_host() {
  if [ -f /var/www/html/.ddev/config.yaml ] || [ -n "${DDEV_PROJECT:-}" ] || [ -f /.dockerenv ]; then
    wtd_die "must run on the HOST, not inside a ddev container (detected DDEV_PROJECT/.dockerenv/var-www-html). SSH or open a host shell/tmux window and re-run there."
  fi
  command -v ddev >/dev/null 2>&1 || wtd_die "ddev not found in PATH (host ddev install required)"
  command -v git >/dev/null 2>&1 || wtd_die "git not found in PATH"
  command -v jq >/dev/null 2>&1 || wtd_die "jq not found in PATH"
}

wtd_valid_ticket_id() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# Reads the `name:` field out of a ddev project's config.yaml.
wtd_ddev_project_name() {
  local repo=$1 name
  name=$(awk -F': *' '/^name:/{print $2; exit}' "$repo/.ddev/config.yaml" 2>/dev/null)
  [ -n "$name" ] || wtd_die "could not read 'name:' from $repo/.ddev/config.yaml"
  printf '%s' "$name"
}

wtd_state_file() { printf '%s/%s.env' "$WTD_STATE_DIR" "$1"; }
