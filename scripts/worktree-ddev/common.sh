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

# Prints the repo-relative paths of nested git repos that the parent repo's
# TRACKED symlinks point into, one per line.
#
# Why this rule rather than "every nested repo": a linked worktree only
# materialises the parent repo's own tracked content. A nested repo (the
# Playwright harness, say) is not part of that, so any tracked symlink
# pointing into it dangles the moment the worktree is created -- and
# everything downstream (test runners, tsconfig path mapping, the post-start
# npm hook) fails on a path that simply isn't there. A nested repo that
# nothing tracked points into has no such breakage, so it is left alone;
# blanket-provisioning every nested repo would drag in wikis, vendored
# module checkouts and report repos nobody asked for.
#
# So the parent's own index tells us which nested repos are load-bearing.
# Nothing is hardcoded and the answer stays correct as projects change.
#
# Absolute symlink targets (e.g. ~/.gitconfig in .ddev/homeadditions) are
# host files, not repo content -- skipped.
wtd_nested_symlink_repos() {
  local repo=$1 link target resolved dir
  # ls-files -s emits "<mode> <sha> <stage>\t<path>"; 120000 is a symlink.
  git -C "$repo" ls-files -s 2>/dev/null \
    | sed -n 's/^120000 [0-9a-f]* [0-9]\t//p' \
    | while IFS= read -r link; do
        target=$(readlink "$repo/$link" 2>/dev/null) || continue
        case "$target" in /*) continue ;; esac
        resolved=$(realpath -m "$repo/$(dirname "$link")/$target" 2>/dev/null) || continue
        case "$resolved" in "$repo"/*) ;; *) continue ;; esac
        # Walk up to the nearest enclosing git repo below $repo.
        dir=$(dirname "$resolved")
        while [ "$dir" != "$repo" ] && [ "$dir" != "/" ]; do
          if [ -e "$dir/.git" ]; then printf '%s\n' "${dir#"$repo"/}"; break; fi
          dir=$(dirname "$dir")
        done
      done | sort -u
}

# Copies the ignored-but-present payload of <src-dir> into <dst-dir>:
# the files git deliberately does not track but which a working checkout
# cannot run without -- config.private.json credentials, untracked app
# directories, gitignored symlinks.
#
# Skips build output and dependency trees (node_modules is ~100MB and is
# rebuilt by the post-start npm hook; test-results/playwright-report are
# previous runs' artefacts and actively misleading if inherited -- a stale
# trace.zip would trip playwright-trace-guard in the new worktree).
#
# cp -a to preserve symlinks as symlinks: some of this payload IS a symlink.
wtd_copy_ignored_payload() {
  local src=$1 dst=$2 rel
  git -C "$src" ls-files --others --ignored --exclude-standard --directory 2>/dev/null \
    | while IFS= read -r rel; do
        case "$rel" in
          node_modules/*|*/node_modules/*|node_modules/) continue ;;
          test-results/*|*/test-results/*|test-results/) continue ;;
          playwright-report/*|*/playwright-report/*|playwright-report/) continue ;;
          .git/*) continue ;;
        esac
        rel=${rel%/}
        [ -e "$src/$rel" ] || continue
        # NOTE: no "skip anything containing .git" guard here. Some of this
        # payload IS a git clone -- m2-hyva-playwright's src/apps/{checkout,
        # luma,nto} are separate gitignored checkouts, and skipping them
        # leaves the harness unable to resolve three of its test apps. They
        # are small and independent, so a plain copy is correct. Only the
        # PARENT-level sweep skips nested repos, because there they are
        # either worktree-provisioned already or deliberately out of scope.
        # Never overwrite: on a repair run the worktree's copy may carry the
        # ticket's own edits, and trunk's version is not newer, just different.
        [ -e "$dst/$rel" ] && continue
        mkdir -p "$dst/$(dirname "$rel")"
        cp -a "$src/$rel" "$dst/$rel" 2>/dev/null || true
      done
}

# Provisions everything a linked worktree needs that git does not carry:
# nested-repo checkouts, their gitignored credential/app payload, and the
# project's own Claude gate configs.
#
# Split out of worktree-ddev-up.sh so it can also REPAIR an existing worktree
# that predates this provisioning (the five pvcpipesupplies ticket worktrees
# created before 2026-09-18 all shipped a dead Playwright harness). Every step
# is idempotent and skips anything already present, so re-running is safe.
#
# Usage: wtd_provision_worktree <repo> <worktree-dir> <branch> <project-name>
wtd_provision_worktree() {
  local repo=$1 worktree_dir=$2 branch=$3 new_project=$4
  local nested rel src_nested dst_nested nested_branch top done_tops f d base copied p
  # --- nested repos (test harnesses etc) ---------------------------------------
  # Must happen BEFORE `ddev start`. A project's post-start hooks typically run
  # `npm install` inside the harness directory; if the directory isn't there yet
  # the hook hard-fails and `ddev start` reports a post-start failure on every
  # new worktree. Provisioning first means the hook finds what it expects and
  # does the install for us, so there is no separate install step here.
  #
  # See wtd_nested_symlink_repos for why only symlink-referenced nested repos
  # are provisioned. Set WTD_SKIP_NESTED=1 to skip this entirely.
  if [ "${WTD_SKIP_NESTED:-0}" != 1 ]; then
    nested=$(wtd_nested_symlink_repos "$repo")
    for rel in $nested; do
      src_nested="$repo/$rel"
      dst_nested="$worktree_dir/$rel"

      # Idempotent: on a repair run the checkout may already be there. Still
      # fall through to the payload copy, which fills in anything missing.
      if [ -e "$dst_nested/.git" ]; then
        echo "worktree-ddev: nested repo $rel already present, topping up payload"
        wtd_copy_ignored_payload "$src_nested" "$dst_nested"
        continue
      fi
      echo "worktree-ddev: provisioning nested repo $rel"

      # Name the nested branch after the ticket too, but keep it distinct from
      # the parent's branch namespace -- these are different repos and a ticket
      # branch may already exist upstream in one and not the other.
      nested_branch="$branch"
      if git -C "$src_nested" show-ref --verify --quiet "refs/heads/$nested_branch"; then
        # Already checked out in another worktree? Then we can't attach to it.
        if git -C "$src_nested" worktree list --porcelain 2>/dev/null \
             | grep -qx "branch refs/heads/$nested_branch"; then
          nested_branch="${branch}-${new_project}"
          echo "worktree-ddev:   branch '$branch' already checked out in $rel, using '$nested_branch'"
          git -c core.hooksPath=/dev/null -C "$src_nested" \
            worktree add "$dst_nested" -b "$nested_branch" >/dev/null
        else
          git -c core.hooksPath=/dev/null -C "$src_nested" \
            worktree add "$dst_nested" "$nested_branch" >/dev/null
        fi
      else
        git -c core.hooksPath=/dev/null -C "$src_nested" \
          worktree add "$dst_nested" -b "$nested_branch" >/dev/null
      fi

      # Credentials, untracked app dirs and gitignored symlinks -- present in
      # the trunk checkout, absent from any worktree because git ignores them.
      wtd_copy_ignored_payload "$src_nested" "$dst_nested"
    done

    # Same treatment for the parent repo's own ignored payload, but scoped to
    # the directories that actually contain those nested repos (typically
    # tests/). Sweeping the whole project would drag in vendor/, var/,
    # generated/ and pub/static -- all rebuilt by ddev/composer anyway.
    # Submodules are the other way a project pulls in a nested repo (ntotank
    # mounts its whole tests/ tree that way rather than via symlinks).
    # `git worktree add` does not populate them, so a worktree gets empty
    # directories where the harness should be. Same breakage, different
    # mechanism -- and the fix is git's own, not ours.
    if [ -f "$worktree_dir/.gitmodules" ]; then
      echo "worktree-ddev: initialising submodules"
      git -C "$worktree_dir" submodule update --init --recursive >/dev/null 2>&1 \
        || echo "worktree-ddev: WARNING submodule init failed -- run 'git submodule update --init' in $worktree_dir"
    fi

    done_tops=""
    for rel in $nested; do
      top=${rel%%/*}
      [ -d "$repo/$top" ] || continue
      case " $done_tops " in *" $top "*) continue ;; esac
      done_tops="$done_tops $top"
      echo "worktree-ddev: provisioning untracked payload under $top/"
      (cd "$repo" && git ls-files --others --ignored --exclude-standard --directory -- "$top/" 2>/dev/null) \
        | while IFS= read -r p; do
            case "$p" in
              *node_modules*|*test-results*|*playwright-report*) continue ;;
            esac
            p=${p%/}
            [ -e "$repo/$p" ] || continue
            [ -e "$repo/$p/.git" ] && continue
            [ -e "$worktree_dir/$p" ] && continue
            mkdir -p "$worktree_dir/$(dirname "$p")"
            cp -a "$repo/$p" "$worktree_dir/$p" 2>/dev/null || true
          done
    done
  fi

  # --- project-local Claude gate configs ---------------------------------------
  # .claude/ holds two different kinds of thing. The prose and central tooling
  # are bind-mounted into the container (see ai.mounts.yaml), so they need
  # nothing here. The project's own gate/config files are NOT mounted and are
  # gitignored, so a worktree silently runs with different gates than trunk --
  # test-gate disabled here but not there, a guard hook firing here that trunk
  # opted out of. That divergence is invisible until it costs a session.
  #
  # Copied, not symlinked: a ticket may legitimately need to tweak its own gate
  # config without mutating trunk's.
  #
  # Excluded by name (not by drift-prone allowlist):
  #   settings.json - a 0-byte bind-mount stub for the central settings
  #   wires.json    - already bind-mounted read-only from trunk
  if [ "${WTD_SKIP_CLAUDE_CONFIG:-0}" != 1 ] && [ -d "$repo/.claude" ]; then
    mkdir -p "$worktree_dir/.claude"
    copied=""
    for f in "$repo"/.claude/*.json "$repo"/.claude/rules-disable \
             "$repo"/.claude/bugsink.env "$repo"/.claude/settings.local.json; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      case "$base" in settings.json|wires.json) continue ;; esac
      # 0-byte files here are bind-mount stubs, never real config.
      [ -s "$f" ] || continue
      [ -e "$worktree_dir/.claude/$base" ] && continue
      cp -a "$f" "$worktree_dir/.claude/$base"
      copied="$copied $base"
    done
    for d in commands skills; do
      if [ -d "$repo/.claude/$d" ] && [ ! -e "$worktree_dir/.claude/$d" ]; then
        cp -a "$repo/.claude/$d" "$worktree_dir/.claude/$d"
        copied="$copied $d/"
      fi
    done
    [ -n "$copied" ] && echo "worktree-ddev: .claude gate configs:$copied"
  fi

}
