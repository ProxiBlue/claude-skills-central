#!/bin/bash
# Fleet-mounted launcher for Midhun-edv/magento-coding-standard-mcp.
#
# Registered in ~/claude-skills-central/mcps/.mcp.json, same live-bind-mount
# pattern as bricklayer-mcp.sh — visible in every DDEV container at
# /var/www/html/.claude/scripts/magento-standards-mcp.sh.
#
# Unlike bricklayer, this server is Magento-domain-generic (rule/pattern
# knowledge, not tied to a specific project's installed code) so it is
# vendored ONCE centrally under scripts/vendor/ instead of per-project via
# composer. No gate needed — safe to run in every container, Magento or not
# (it just answers rule-lookup questions, doesn't touch the project tree).
#
# Source: https://github.com/Midhun-edv/magento-coding-standard-mcp
# Vendored + built (npm install && npm run build) 2026-08-12. To update:
# cd scripts/vendor/magento-coding-standard-mcp && git pull && npm install
# && npm audit fix && npm run build (re-run npm audit fix — 1.2.0 shipped
# with 8 vulns in transitive HTTP-transport deps unused by stdio mode;
# fixed once at vendor time, recheck on every update).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "${SCRIPT_DIR}/vendor/magento-coding-standard-mcp/dist/index.js"
