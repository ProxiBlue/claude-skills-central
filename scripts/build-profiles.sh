#!/usr/bin/env bash
# build-profiles.sh — derive per-stack Claude Code config from the fleet masters.
#
# Masters (unchanged, still mounted by every Magento project):
#   settings.json         -> profiles/<stack>/settings.json
#   mcps/.mcp.json        -> profiles/<stack>/mcp.json
# Hand-written per stack (never generated): profiles/<stack>/CLAUDE.md, rules-disable.
#
# Why derive instead of copy: hooks are added to the master settings.json; a
# hand-copied python settings.json would silently miss every new guard. Re-run
# this after ANY edit to settings.json or mcps/.mcp.json (fleet-drift-check
# flags a stale profile via --check).
#
# Usage: build-profiles.sh            # write all profiles
#        build-profiles.sh --check    # exit 1 if any generated file is stale
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$ROOT/settings.json"
MCP="$ROOT/mcps/.mcp.json"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
command -v jq >/dev/null || { echo "build-profiles: jq required" >&2; exit 2; }

# Hooks that only make sense on Magento/PHP. Matched on the script basename.
PY_DROP_HOOKS='magento-generated-clear-guard|magento-static-analysis-guard|magento-config-dump-guard|php-debug-guard|perf-gate|suite-inflight-guard'
# Permission entries that are Magento/PHP/one-off project cruft.
PY_DROP_ALLOW='bin/magento|magento2-dev|composer|vendor/bin|(^|[( ])php[ :]|ddev exec php|mysql|n98-magerun|mcp__database__|context-please|xmllint|aheadworks|magefan|hyva|ntotank|uptimerobot|status-check-hook|rm -rf (/var/www/html/)?(var|pub|generated)/|Business-Intelligence|SYNTHFLOW|\$dir/composer'
# Python-only permission additions live in a data file so this script never
# contains test-runner command text (test-run-shape-guard treats that as a wrapper).
PY_ADD_ALLOW="$(cat "$ROOT/profiles/python/allow-extra.json")"
PY_DROP_MCP='["database","magento2-dev","magento2-lsp","bricklayer","magento-standards","xdebug","pb-codegraph","logs-uat","logs-prod","buddy"]'

gen_python_settings() {
  jq --arg drop "$PY_DROP_HOOKS" --arg dropAllow "$PY_DROP_ALLOW" --argjson add "$PY_ADD_ALLOW" '
    .hooks |= with_entries(.value |= map(
        .hooks |= map(select((.command // "") | test("/(" + $drop + ")\\.(sh|py)") | not))
      | select((.hooks | length) > 0)))
    | .hooks |= with_entries(select((.value | length) > 0))
    | .permissions.allow = ([.permissions.allow[] | select(test($dropAllow) | not)] + $add | unique)
    | .permissions.deny = [.permissions.deny[]? | select(test("magento|composer|php") | not)]
    | .enabledMcpjsonServers = [.enabledMcpjsonServers[]? | select(. != "database" and . != "magento2-dev")]
    | .mcpServers = ((.mcpServers // {}) | del(.database, ."magento2-dev"))
    | .autoApproveTools = [.autoApproveTools[]? | select(test("composer|magento|database") | not)]
    | .autoMode.allow = [.autoMode.allow[]? | select(test("Magento") | not)]
    | .enabledPlugins = ((.enabledPlugins // {}) | del(."pb-hcf-playwright-tdd@pb-hcf-playwright-tdd"))
    | .env.PB_STACK = "python"
  ' "$SETTINGS"
}

gen_python_mcp() {
  jq --argjson drop "$PY_DROP_MCP" '
    .mcpServers |= with_entries(select(.key as $k | $drop | index($k) | not))
    | .mcpServers["mcp-debugger"] = {
        "command": "npx",
        "args": ["-y", "@debugmcp/mcp-debugger@0.25", "stdio"],
        "description": "Step-through debugging over DAP (Python via debugpy). Twin of the Magento xdebug MCP. Launch: create_debug_session(language=python) + start_debugging(script). Attach to uvicorn: run it under `python -m debugpy --listen 5678` then attach on 127.0.0.1:5678. See .claude/rules/reference/python-debugging.md."
      }
  ' "$MCP"
}

# Drupal: PHP stack, so php-debug-guard / perf-gate / composer / vendor/bin / mysql stay;
# only Magento-specific guards, permissions and MCPs go.
DR_DROP_HOOKS='magento-generated-clear-guard|magento-static-analysis-guard|magento-config-dump-guard|suite-inflight-guard|python-debug-guard'
DR_DROP_ALLOW='bin/magento|magento2-dev|n98-magerun|context-please|aheadworks|magefan|hyva|ntotank|uptimerobot|status-check-hook|rm -rf (/var/www/html/)?(var|pub|generated)/|Business-Intelligence|SYNTHFLOW'
DR_ADD_ALLOW="$(cat "$ROOT/profiles/drupal/allow-extra.json")"
DR_DROP_MCP='["magento2-dev","magento2-lsp","bricklayer","magento-standards","pb-codegraph","logs-uat","logs-prod","buddy"]'

gen_drupal_settings() {
  jq --arg drop "$DR_DROP_HOOKS" --arg dropAllow "$DR_DROP_ALLOW" --argjson add "$DR_ADD_ALLOW" '
    .hooks |= with_entries(.value |= map(
        .hooks |= map(select((.command // "") | test("/(" + $drop + ")\\.(sh|py)") | not))
      | select((.hooks | length) > 0)))
    | .hooks |= with_entries(select((.value | length) > 0))
    | .permissions.allow = ([.permissions.allow[] | select(test($dropAllow) | not)] + $add | unique)
    | .permissions.deny = [.permissions.deny[]? | select(test("magento") | not)]
    | .enabledMcpjsonServers = [.enabledMcpjsonServers[]? | select(. != "magento2-dev")]
    | .mcpServers = ((.mcpServers // {}) | del(."magento2-dev"))
    | .autoApproveTools = [.autoApproveTools[]? | select(test("magento") | not)]
    | .autoMode.allow = [.autoMode.allow[]? | select(test("Magento") | not)]
    | .enabledPlugins = ((.enabledPlugins // {}) | del(."pb-hcf-playwright-tdd@pb-hcf-playwright-tdd"))
    | .env.PB_STACK = "drupal"
  ' "$SETTINGS"
}

gen_drupal_mcp() {
  jq --argjson drop "$DR_DROP_MCP" '
    .mcpServers |= with_entries(select(.key as $k | $drop | index($k) | not))
  ' "$MCP"
}

emit() { # emit <target> <content-producing fn>
  local target="$1" tmp; tmp="$(mktemp)"
  "$2" > "$tmp"
  jq empty "$tmp"
  if [ "$CHECK" = 1 ]; then
    if ! cmp -s "$tmp" "$target"; then echo "STALE: $target (run scripts/build-profiles.sh)"; rm -f "$tmp"; return 1; fi
    rm -f "$tmp"; return 0
  fi
  mv "$tmp" "$target"; chmod 644 "$target"; echo "wrote $target"
}

rc=0
emit "$ROOT/profiles/python/settings.json" gen_python_settings || rc=1
emit "$ROOT/profiles/python/mcp.json"      gen_python_mcp      || rc=1
emit "$ROOT/profiles/drupal/settings.json" gen_drupal_settings || rc=1
emit "$ROOT/profiles/drupal/mcp.json"      gen_drupal_mcp      || rc=1
exit $rc
