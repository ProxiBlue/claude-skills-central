#!/usr/bin/env bash
# Gated launcher for the pb-codegraph MCP server (stdio).
# Mirrors bricklayer-mcp.sh: exits 0 silently when the project isn't wired
# (no registry file), so non-wired projects get no MCP error noise.
set -u
REGISTRY="${PB_CODEGRAPH_REGISTRY:-/var/www/html/.ddev/pb-codegraph/registry.json}"
PB_HOME="${PB_CODEGRAPH_HOME:-/var/www/html/.claude/plugins-seed/marketplaces/pb-codegraph}"
[ -f "$REGISTRY" ] || exit 0
[ -d "$PB_HOME/mcp" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
export PB_CODEGRAPH_REGISTRY="$REGISTRY"
cd "$PB_HOME" || exit 0
exec node --import tsx mcp/bin/server.ts
