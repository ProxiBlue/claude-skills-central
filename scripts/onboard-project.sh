#!/usr/bin/env bash
# onboard-project.sh — bring a DDEV project into the fleet AI tooling, per stack profile.
#
#   onboard-project.sh --stack=python [--new --name=<ddev-name> --pkg=<py_pkg>] [--force] [--dry-run] [--allow-branch] <project-dir>
#   onboard-project.sh --stack=magento [--force] [--dry-run] [--allow-branch] <project-dir>
#
# Existing project (no --new): writes only the fleet wiring —
#   .ddev/docker-compose.ai.mounts.yaml  (profile mounts)
#   .ddev/config.claude-code.yaml        (claude home symlinks + seed sync, if missing)
#   .claude/rules-disable                (profile default, if missing)
#   .claude/test-gate.json               (python only, if missing)
#   host/tooling-scope.txt entry         ("<name> <stack>")
# --new (python only): scaffolds the whole ddev_project_template_python tree into an
#   empty/new dir, fills placeholders, runs `uv lock`, `git init -b live`.
#
# Safety: refuses to write into a git repo that is not on live/LIVE/main (fleet rule:
# ddev env changes land on LIVE) unless --allow-branch. Never overwrites a differing
# file without --force; prints the diff instead.
set -euo pipefail

CENTRAL="$HOME/claude-skills-central"
PY_TEMPLATE="$HOME/workspace/proxiblue/ddev_project_template_python"
MAGE_TEMPLATE="$HOME/workspace/proxiblue/ddev_project_template"
SCOPE="${ONBOARD_SCOPE_FILE:-$CENTRAL/host/tooling-scope.txt}"   # override for tests

STACK=""; NEW=0; NAME=""; PKG=""; FORCE=0; DRY=0; ALLOW_BRANCH=0; DIR=""
for a in "$@"; do
  case "$a" in
    --stack=*) STACK="${a#*=}" ;;
    --new) NEW=1 ;;
    --name=*) NAME="${a#*=}" ;;
    --pkg=*) PKG="${a#*=}" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown flag $a" >&2; exit 2 ;;
    *) DIR="$a" ;;
  esac
done
[ -n "$STACK" ] && [ -n "$DIR" ] || { sed -n '2,6p' "$0" >&2; exit 2; }
case "$STACK" in python|magento) ;; *) echo "stack must be python|magento" >&2; exit 2 ;; esac
[ "$NEW" = 1 ] && [ "$STACK" != python ] && { echo "--new is python-only (Magento projects start from composer create-project)" >&2; exit 2; }
DIR="$(realpath -m "$DIR")"

say() { echo "onboard: $*"; }
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

# place <src-content-file> <dest> : write unless identical; diff+skip on conflict without --force
place() {
  local src="$1" dest="$2"
  if [ -f "$dest" ]; then
    if cmp -s "$src" "$dest"; then say "unchanged  ${dest#$DIR/}"; return 0; fi
    if [ "$FORCE" != 1 ]; then
      say "DIFFERS    ${dest#$DIR/} (kept; --force to replace)"; diff -u "$dest" "$src" | sed 's/^/    /' | head -40 || true; return 0
    fi
  fi
  say "write      ${dest#$DIR/}"
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$(dirname "$dest")"; cp "$src" "$dest"
}

free_ports() { # next free pair above every host_*_port in sibling ddev projects
  local max=8300 p
  for p in $(grep -hoE 'host_(webserver|https)_port: *"?[0-9]+' "$HOME"/workspace/*/*/.ddev/config.yaml "$HOME"/workspace/*/.ddev/config.yaml 2>/dev/null | grep -oE '[0-9]+$'); do
    [ "$p" -lt 10000 ] && [ "$p" -gt "$max" ] && max=$p
  done
  echo "$((max + 1)) $((max + 2))"
}

# ---- branch guard -----------------------------------------------------------
if [ -d "$DIR/.git" ] || git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  BR="$(git -C "$DIR" branch --show-current 2>/dev/null || true)"
  case "$BR" in
    live|LIVE|main) ;;
    *) if [ "$ALLOW_BRANCH" != 1 ]; then
         echo "onboard: REFUSED — $DIR is on branch '$BR', not live/LIVE/main. ddev env changes must land on LIVE." >&2
         echo "onboard: switch to live first, or pass --allow-branch to proceed knowingly." >&2; exit 3
       fi; say "WARNING proceeding on branch '$BR' (--allow-branch)" ;;
  esac
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- --new scaffold (python) ------------------------------------------------
if [ "$NEW" = 1 ]; then
  [ -n "$NAME" ] && [ -n "$PKG" ] || { echo "--new needs --name and --pkg" >&2; exit 2; }
  [[ "$PKG" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "--pkg must be a valid lowercase python identifier" >&2; exit 2; }
  if [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then echo "--new target $DIR is not empty" >&2; exit 2; fi
  read -r HTTP HTTPS < <(free_ports)
  PIN="$(jq -r '.fleet_target // empty' "$CENTRAL/host/pin-decision.json" 2>/dev/null)"; PIN="${PIN:-latest}"
  ENVPREFIX="$(echo "$PKG" | tr '[:lower:]' '[:upper:]')"
  say "scaffold $DIR  name=$NAME pkg=$PKG ports=$HTTP/$HTTPS claude=$PIN"
  run mkdir -p "$DIR"
  if [ "$DRY" != 1 ]; then
    (cd "$PY_TEMPLATE" && tar --exclude=README.md -cf - .) | (cd "$DIR" && tar -xf -)
    mv "$DIR/src/__PKG__" "$DIR/src/$PKG"
    grep -rlZ -e '__PKG__' -e '__PROJECT__' -e '__ENVPREFIX__' -e '__HTTP_PORT__' -e '__HTTPS_PORT__' -e '__CLAUDE_PIN__' "$DIR" \
      | xargs -0 sed -i -e "s/__PKG__/$PKG/g" -e "s/__PROJECT__/$NAME/g" -e "s/__ENVPREFIX__/$ENVPREFIX/g" \
                        -e "s/__HTTP_PORT__/$HTTP/g" -e "s/__HTTPS_PORT__/$HTTPS/g" -e "s/__CLAUDE_PIN__/$PIN/g"
    if command -v uv >/dev/null; then (cd "$DIR" && uv lock --python 3.13 >/dev/null 2>&1 && say "uv.lock generated") || say "uv lock failed — run it inside the container after ddev start"; fi
    git -C "$DIR" init -q -b live && say "git init (branch live)"
  fi
else
  [ -d "$DIR/.ddev" ] || { echo "$DIR has no .ddev/ — run 'ddev config' first, or use --new" >&2; exit 2; }
  NAME="$(awk -F': *' '/^name:/{print $2; exit}' "$DIR/.ddev/config.yaml")"
  # ---- wiring for an existing project ---------------------------------------
  if [ "$STACK" = python ]; then
    place "$PY_TEMPLATE/.ddev/docker-compose.ai.mounts.yaml" "$DIR/.ddev/docker-compose.ai.mounts.yaml"
    [ -f "$DIR/.ddev/config.claude-code.yaml" ] || place "$PY_TEMPLATE/.ddev/config.claude-code.yaml" "$DIR/.ddev/config.claude-code.yaml"
    [ -f "$DIR/.claude/rules-disable" ] || place "$CENTRAL/profiles/python/rules-disable" "$DIR/.claude/rules-disable"
    [ -f "$DIR/.claude/test-gate.json" ] || place "$PY_TEMPLATE/.claude/test-gate.json" "$DIR/.claude/test-gate.json"
    grep -q 'PB_STACK=python' "$DIR/.ddev/config.yaml" || say "NOTE add '- PB_STACK=python' to web_environment in .ddev/config.yaml"
  else
    place "$MAGE_TEMPLATE/.ddev/docker-compose.ai.mounts.yaml" "$DIR/.ddev/docker-compose.ai.mounts.yaml"
    [ -f "$DIR/.ddev/config.claude-code.yaml" ] || place "$MAGE_TEMPLATE/.ddev/config.claude-code.yaml" "$DIR/.ddev/config.claude-code.yaml"
  fi
fi

# ---- tooling scope ------------------------------------------------------------
if grep -vE '^\s*(#|$)' "$SCOPE" | awk '{print $1}' | grep -qxF "$NAME"; then
  say "tooling-scope already lists $NAME"
else
  say "tooling-scope += '$NAME $STACK'"
  [ "$DRY" = 1 ] || echo "$NAME $STACK" >> "$SCOPE"
fi

say "done. Next: cd $DIR && ddev restart && ddev claude"
say "  inside claude: /hcf:project-setup  then  /pb-hcf:wire --stack=$STACK --enable=<set from pb-hcf README>"
