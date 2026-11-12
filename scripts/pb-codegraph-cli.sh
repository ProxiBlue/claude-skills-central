#!/usr/bin/env bash
# pb-codegraph CLI shim for ddev web containers.
#
# Puts `pb-codegraph` on the container PATH (via the ~/.ddev/homeadditions/bin
# stub, which execs this file) so pb-hcf's pre-flight probe
# `pb-codegraph health --registry ...` and the codegraph playbook commands work
# as written. Before this shim the CLI only ran as
# `cd <seed> && node --import tsx bin/pb-codegraph.ts`, so every container
# reported "pb-codegraph: command not found".
#
# Uses the seed checkout's own tsx binary, so the caller's cwd is preserved and
# relative args (e.g. --registry .ddev/pb-codegraph/registry.json) resolve
# against the project, not the seed dir.
set -u
PB_HOME="${PB_CODEGRAPH_HOME:-/var/www/html/.claude/plugins-seed/marketplaces/pb-codegraph}"
TSX="$PB_HOME/node_modules/.bin/tsx"
ENTRY="$PB_HOME/bin/pb-codegraph.ts"
if [ ! -f "$ENTRY" ] || [ ! -x "$TSX" ]; then
  echo "pb-codegraph: seed checkout not usable at $PB_HOME (need bin/pb-codegraph.ts + node_modules/.bin/tsx)" >&2
  exit 127
fi
command -v node >/dev/null 2>&1 || { echo "pb-codegraph: node not on PATH" >&2; exit 127; }
exec "$TSX" "$ENTRY" "$@"
