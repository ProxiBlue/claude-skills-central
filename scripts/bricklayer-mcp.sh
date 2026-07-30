#!/bin/bash
# Fleet-mounted launcher for the inchoo/magento-bricklayer MCP server.
#
# Registered in ~/claude-skills-central/mcps/.mcp.json as the chrome-devtools
# entry is — the same mount is visible in every DDEV container at
# /var/www/html/.claude/scripts/bricklayer-mcp.sh.
#
# Gate: only fires the actual MCP server when the project ships bricklayer
# as a composer dep (vendor/bin/bricklayer present at project root inside
# the container, /var/www/html). On non-Magento containers (ai_assistant,
# tradingBOT, ihop, ntotankM1) the composer package won't be installed —
# this exits silently so Claude drops the entry without spamming red on
# every session start. Preferred over failing loudly per Option C:
# "gated launcher — Magento projects get it, others silent".
#
# CWD: DDEV sets container working directory to /var/www/html for web
# service exec, so `vendor/bin/bricklayer` here resolves against the
# project's own vendor tree. Don't hard-code the path — a project might
# install to a non-standard vendor-dir via composer config in future.

set -e

# Prefer /var/www/html as the project root (DDEV convention). Fall back to
# CWD for host-side invocation or non-DDEV environments.
PROJECT_ROOT="/var/www/html"
[[ -d "$PROJECT_ROOT" ]] || PROJECT_ROOT="$(pwd)"

BRICKLAYER="${PROJECT_ROOT}/vendor/bin/bricklayer"

if [[ ! -x "$BRICKLAYER" ]]; then
  # Silent exit — Claude will note the server terminated without an error
  # in stderr, then move on. Non-Magento containers see zero noise.
  exit 0
fi

# Bricklayer's mcp subcommand runs the JSON-RPC server on stdio, per
# https://github.com/Inchoo/magento-bricklayer#mcp
exec "$BRICKLAYER" mcp
