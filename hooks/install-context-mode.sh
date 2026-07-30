#!/bin/bash
# DDEV post-start hook: install context-mode Claude Code plugin.
#
# context-mode sandboxes MCP/tool output before it enters the context window:
#   ~98% savings with hooks (vs ~60% MCP-only).
# It registers PreToolUse, PostToolUse, PreCompact, SessionStart, and
# UserPromptSubmit hooks that intercept large payloads (Playwright snapshots,
# git logs, file reads, subagent output) and index them in a local SQLite FTS5
# knowledge base. Session state survives compaction.
#
# Prerequisites: Node.js >= 22.5 (DDEV nodejs_version: "22" required).
# Idempotent — fast-path no-op if already installed (~20ms).
#
# To propagate to ALL Magento 2 DDEV projects (central install):
#   1. Copy this file to ~/claude-skills-central/hooks/install-context-mode.sh
#   2. Add context-mode entry to ~/claude-plugins-central/seed/known_marketplaces.json
#   3. In each project's .ddev/config.claude-code.yaml, add:
#        - exec: "bash /var/www/html/.claude/hooks/install-context-mode.sh"
#      (points to central hooks mount, not the project-local .ddev path)
#   4. Ensure each project has nodejs_version: "22" in .ddev/config.yaml

set -e

PLUGIN_CACHE=~/.claude/plugins/cache/context-mode/context-mode
INSTALLED_JSON=~/.claude/plugins/installed_plugins.json
SETTINGS_JSON=~/.claude/settings.json

PLUGIN_CACHE=$(eval echo "$PLUGIN_CACHE")
INSTALLED_JSON=$(eval echo "$INSTALLED_JSON")
SETTINGS_JSON=$(eval echo "$SETTINGS_JSON")

# Fast path: already installed with start.mjs present
if [ -f "$INSTALLED_JSON" ]; then
    ALREADY=$(python3 -c "
import json, os, sys
try:
    d = json.load(open('$INSTALLED_JSON'))
    entries = d.get('plugins', {}).get('context-mode@context-mode', [])
    if entries and os.path.isfile(os.path.join(entries[0].get('installPath', ''), 'start.mjs')):
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")
    if [ "$ALREADY" = "yes" ]; then
        exit 0
    fi
fi

# Require Node 22+
NODE_MAJOR=$(node -e "process.stdout.write(process.versions.node.split('.')[0])" 2>/dev/null || echo "0")
if [ "$NODE_MAJOR" -lt 22 ] 2>/dev/null; then
    echo "  WARNING: context-mode requires Node.js >= 22 (current: $(node --version 2>/dev/null || echo 'unknown'))" >&2
    echo "  Set nodejs_version: \"22\" in .ddev/config.yaml and restart DDEV." >&2
    exit 0
fi

echo "Installing context-mode plugin..."

VERSION=$(npm show context-mode version 2>/dev/null || echo "1.0.146")
INSTALL_DIR="$PLUGIN_CACHE/$VERSION"
TMPDIR_PACK=$(mktemp -d)
trap "rm -rf '$TMPDIR_PACK'" EXIT

mkdir -p "$INSTALL_DIR"

# Download and extract npm tarball
if [ ! -f "$INSTALL_DIR/start.mjs" ]; then
    echo "  Downloading context-mode@$VERSION from npm..."
    npm pack "context-mode@$VERSION" --pack-destination "$TMPDIR_PACK" --silent 2>/dev/null
    TARBALL=$(ls "$TMPDIR_PACK"/context-mode-*.tgz 2>/dev/null | head -1)
    if [ -z "$TARBALL" ]; then
        echo "  ERROR: failed to download context-mode tarball" >&2
        exit 1
    fi
    tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
fi

# Install native dependencies (better-sqlite3 has prebuilts for Node 22)
if [ ! -d "$INSTALL_DIR/node_modules" ]; then
    echo "  Installing native dependencies (better-sqlite3)..."
    (cd "$INSTALL_DIR" && npm install --omit=dev --silent 2>&1) || {
        echo "  Warning: npm install had errors — context-mode FTS5 features may be unavailable" >&2
    }
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SHASUM=$(npm show "context-mode@$VERSION" dist.shasum 2>/dev/null || echo "")

# Register in installed_plugins.json
python3 - <<PYTHON
import json, os

path = '$INSTALLED_JSON'
if os.path.isfile(path):
    with open(path) as f:
        d = json.load(f)
else:
    d = {'version': 2, 'plugins': {}}

key = 'context-mode@context-mode'
if key not in d.get('plugins', {}):
    d.setdefault('plugins', {})[key] = [{
        'scope': 'user',
        'installPath': '$INSTALL_DIR',
        'version': '$VERSION',
        'installedAt': '$NOW',
        'lastUpdated': '$NOW',
        'gitCommitSha': '$SHASUM'
    }]
    with open(path, 'w') as f:
        json.dump(d, f, indent=4)
    print('  Updated installed_plugins.json')
PYTHON

# Wire into settings.json enabledPlugins
python3 - <<PYTHON
import json, os

path = '$SETTINGS_JSON'
if os.path.isfile(path):
    with open(path) as f:
        d = json.load(f)
else:
    d = {}

if 'context-mode@context-mode' not in d.get('enabledPlugins', {}):
    d.setdefault('enabledPlugins', {})['context-mode@context-mode'] = True
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print('  Updated settings.json (enabledPlugins)')
PYTHON

echo "context-mode $VERSION installed. Run /context-mode:ctx-doctor to verify."
exit 0
