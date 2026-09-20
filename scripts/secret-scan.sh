#!/usr/bin/env bash
# Credential scanner for the nightly tooling backup push.
#
# Why this exists (2026-09-19/20): claude-skills-central is deliberately
# PUBLIC -- seven blog posts deep-link its hooks and rules. The nightly
# tooling-backup-push.sh does `git add -A` + commit + push with no
# inspection, so anything sitting in that working tree is published within
# the hour. That is exactly how a Bugsink superuser password and Django
# SECRET_KEY reached raw.githubusercontent.com and stayed readable for six
# weeks, and how a scratch file holding those same values got published
# hours later while the first leak was being cleaned up.
#
# Making the repo private is not an option (the blog depends on it), so the
# publish path gets a gate instead.
#
# Usage:
#   secret-scan.sh --worktree <repo>          scan what `git add -A` would stage
#   secret-scan.sh --range <repo> <range>     scan lines ADDED in a commit range
#
# Exit 0 = clean. Exit 1 = findings (caller must not commit/push).
# Exit 2 = usage error.
#
# Findings print as "<file>:<line>: <pattern-name>" and NEVER echo the matched
# text -- this output goes to a log file and a chatroom message, and reprinting
# a live credential into either just moves the leak.
#
# False positives: add an extended-regex per line to <repo>/.secret-scan-allow.
# A line matching any of those is skipped. Keep entries narrow and comment why.
set -u

usage() { echo "usage: secret-scan.sh --worktree <repo> | --range <repo> <range>" >&2; exit 2; }

MODE=${1:-}; REPO=${2:-}
[ -n "$MODE" ] && [ -n "$REPO" ] || usage
[ -d "$REPO/.git" ] || { echo "secret-scan: not a git repo: $REPO" >&2; exit 2; }

# --- patterns: name<TAB>extended-regex ---------------------------------------
# High-signal shapes only. Anything looser drowns in false positives across
# repos that are themselves full of guard scripts and docs ABOUT secrets.
PATTERNS=$(cat <<'PAT'
private-key-block	-----BEGIN ([A-Z]+ )*PRIVATE KEY-----
aws-access-key	AKIA[0-9A-Z]{16}
github-token	gh[pousr]_[A-Za-z0-9]{36,}
slack-token	xox[abprs]-[A-Za-z0-9-]{10,}
dsn-embedded-secret	://[0-9a-f]{32}@
long-hex-secret	[0-9a-f]{48,}
credential-assignment	(pass(word|wd)?|secret(_key)?|api_?key|access_key|auth_token|token|superuser|credentials?)["']?[[:space:]]*[,:=][[:space:]]*["'][^"']{12,}["']
PAT
)

# --- built-in allowlist ------------------------------------------------------
# Placeholders, shell/compose substitutions and redaction markers. These are
# what a CORRECTLY handled secret looks like, so they must never trip the gate.
BUILTIN_ALLOW='(\$\{|\$[A-Z_]{3,}|REDACTED|EXAMPLE|CHANGEME|PLACEHOLDER|<your|your-|dummy|sample|xxxx|\.\.\.|\*\*\*)'

REPO_ALLOW="$REPO/.secret-scan-allow"

# Collect candidate "file:line:content" records for the chosen mode.
collect() {
  case "$MODE" in
    --worktree)
      # Everything `git add -A` would stage: modified, added, untracked.
      # -z/NUL-safe so paths with spaces survive.
      #
      # -uall is load-bearing, not tidiness: without it git collapses an
      # untracked DIRECTORY to a single "dir/" entry, the -f test below
      # rejects it, and every file inside goes unscanned. A new directory is
      # the normal shape of real work, so the gate would have passed almost
      # everything. Caught by the test suite 2026-09-20.
      git -C "$REPO" status --porcelain -uall -z 2>/dev/null \
        | tr '\0' '\n' \
        | sed -E 's/^.{3}//' \
        | while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ -f "$REPO/$f" ] || continue
            # Skip binaries: they cannot be reviewed line-wise anyway.
            grep -Iq . "$REPO/$f" 2>/dev/null || continue
            grep -n '' "$REPO/$f" 2>/dev/null | sed "s|^|$f:|"
          done
      ;;
    --range)
      local range=${3:-}
      [ -n "$range" ] || usage
      # Only ADDED lines. Existing history is not this gate's problem.
      git -C "$REPO" diff -U0 "$range" 2>/dev/null \
        | awk '
            /^\+\+\+ b\// { f=substr($0,7); next }
            /^@@/ { split($3,a,","); ln=a[1]; sub(/^\+/,"",ln); next }
            /^\+/ && !/^\+\+\+/ { print f ":" ln ":" substr($0,2); ln++ }
          '
      ;;
    *) usage ;;
  esac
}

FOUND=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  file=${rec%%:*}; rest=${rec#*:}
  line=${rest%%:*}; content=${rest#*:}
  [ -n "$content" ] || continue

  # The explicit per-repo allowlist wins over everything -- it is a human
  # decision about a specific known-safe line or file.
  #
  # Two entry forms:
  #   path:<extended-regex>   skip the whole file when its path matches
  #   <extended-regex>        skip any line whose content matches
  #
  # The path form exists because a credential scanner's own test suite is
  # necessarily full of credential-shaped fixtures. Without it this gate
  # blocks every backup forever the moment its tests land -- a guard that
  # cannot coexist with its own tests is not deployable.
  if [ -f "$REPO_ALLOW" ]; then
    skip=0
    while IFS= read -r allow; do
      case "$allow" in
        ''|'#'*) continue ;;
        path:*)
          echo "$file" | grep -qE -- "${allow#path:}" && { skip=1; break; }
          ;;
        *)
          echo "$content" | grep -qE -- "$allow" && { skip=1; break; }
          ;;
      esac
    done < "$REPO_ALLOW"
    [ "$skip" = 1 ] && continue
  fi

  while IFS=$'\t' read -r name regex; do
    [ -n "$name" ] || continue
    # grep -- : several patterns start with "-" (private key banners) and
    # would otherwise be parsed as grep options.
    if echo "$content" | grep -qiE -- "$regex"; then
      # The built-in placeholder allowlist applies ONLY to the loose
      # credential-assignment pattern, which is the one that legitimately
      # fires on `PASSWORD="CHANGEME"` and `KEY="${VAR}"`.
      #
      # It must NOT suppress the high-confidence patterns. A line can carry
      # a live secret AND a placeholder word at once -- the scratch file that
      # leaked during the 2026-09-19 incident was literally
      # "<64-hex-secret>==>REDACTED-KEY", which an allowlist-first design
      # waves straight through. Precedence was inverted here for that reason.
      if [ "$name" = credential-assignment ] \
         && echo "$content" | grep -qE -- "$BUILTIN_ALLOW"; then
        break
      fi
      echo "$file:$line: $name"
      FOUND=$((FOUND+1))
      break
    fi
  done <<< "$PATTERNS"
done <<< "$(collect "$@")"

[ "$FOUND" -gt 0 ] && exit 1
exit 0
