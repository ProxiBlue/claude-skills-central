#!/bin/bash
# Test suite for hcf-upstream-watch.sh — sandboxed HOME, file:// upstream,
# stub claude, fake chatroom. Run: bash hcf-upstream-watch.test.sh
SCRIPT="$(cd "$(dirname "$0")" && pwd)/hcf-upstream-watch.sh"
PASS=0; FAIL=0
for bin in jq python3 curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin missing"; exit 0; }
done

H=$(mktemp -d); trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$H"' EXIT
mkdir -p "$H/mirror/.claude-plugin" "$H/up/.claude-plugin" "$H/bin"
set_mirror()   { printf '{"name":"hcf","version":"%s"}\n' "$1" > "$H/mirror/.claude-plugin/plugin.json"; }
set_upstream() { printf '{"name":"hcf","version":"%s"}\n' "$1" > "$H/up/.claude-plugin/plugin.json"; }
printf '# patches\n- agents/tdd-worker.md model inherit\n' > "$H/mirror/PROXIBLUE-PATCHES.md"
printf '# Changelog\n\n## [2.0.1] — 2026-10-01\n\n- local-only-marker\n\n## [2.0.0] — 2026-06-26\n\n- shared-release-marker\n' > "$H/mirror/CHANGELOG.md"
cat > "$H/up/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added
- unreleased-marker-line

## [2.4.0] — 2026-10-08

### Added
- rolling scheduler marker

## [2.1.0] — 2026-07-26

### Fixed
- hook discovery marker

## [2.0.0] — 2026-06-26

### Added
- old-release-marker
EOF

# claude stub: records the prompt it was given, returns a fixed summary
cat > "$H/bin/claude" <<'STUB'
#!/bin/bash
printf '%s' "$2" > "$HOME/claude-prompt"
echo "$*" | grep -o -- '--model [a-z]*' > "$HOME/claude-model"
echo "STUB-IMPACT-SUMMARY"
STUB
chmod +x "$H/bin/claude"

# fake chatroom: POST /api/threads -> {"id":"T<n>"}, logs each request body
cat > "$H/srv.py" <<'PY'
import http.server, json, sys, pathlib
log = pathlib.Path(sys.argv[2])
class Hd(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b"[]")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n)
        if len(json.loads(raw).get("body", "")) > 10000:
            self.send_response(422); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"detail":"String should have at most 10000 characters"}'); return
        with log.open("ab") as f: f.write(raw + b"\n")
        count = len(log.read_bytes().splitlines())
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"id": f"T{count}"}).encode())
srv = http.server.HTTPServer(("127.0.0.1", 0), Hd)
pathlib.Path(sys.argv[1]).write_text(str(srv.server_port))
srv.serve_forever()
PY
python3 "$H/srv.py" "$H/port" "$H/posts" & SRV_PID=$!
for _ in $(seq 50); do [ -s "$H/port" ] && break; sleep 0.1; done
PORT=$(cat "$H/port")

run() {  # run [VAR=val ...] [-- args]
  OUT=$(env HOME="$H" PATH="$H/bin:$PATH" HCF_MIRROR_DIR="$H/mirror" HCF_UPSTREAM_RAW="file://$H/up" \
        HCF_RETRY_SLEEP=0 PB_CHATROOM_REST_URL="http://127.0.0.1:$PORT" "$@" bash "$SCRIPT" $ARGS 2>&1); RC=$?
}
t()   { if printf '%s' "$OUT" | grep -qF -- "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($1): missing '$2' in: $OUT"; fi; }
nt()  { if printf '%s' "$OUT" | grep -qF -- "$2"; then FAIL=$((FAIL+1)); echo "FAIL ($1): unexpected '$2' in: $OUT"; else PASS=$((PASS+1)); fi; }
rc()  { if [ "$RC" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($1): rc=$RC want $2: $OUT"; fi; }
posts() { [ -f "$H/posts" ] && wc -l < "$H/posts" || echo 0; }
np()  { if [ "$(posts)" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($1): posts=$(posts) want $2"; fi; }
STATE="$H/monitor/hcf-watch"

# 1 mirror current -> quiet, no post
ARGS=""; set_mirror 2.4.0; set_upstream 2.4.0; run
t "current" "HCF mirror current (mirror 2.4.0, upstream 2.4.0)"; rc "current rc" 0; np "current no post" 0

# 2 mirror AHEAD of upstream (local patch bump) -> quiet
set_mirror 2.4.1; run
t "mirror ahead is current" "HCF mirror current"; np "ahead no post" 0

# 3 dry run while behind -> full body, nothing posted, no state written
ARGS="--dry-run"; set_mirror 2.0.1; run
t "dry subject"        "DRY RUN: would post 'HCF upstream 2.4.0 released — mirror at 2.0.1 (2 releases behind)'"
t "dry lists releases" "Behind by 2 release(s): 2.4.0 2.1.0"
t "dry delta newest"   "rolling scheduler marker"
t "dry delta middle"   "hook discovery marker"
nt "dry excludes old"  "old-release-marker"
t "dry unreleased"     "unreleased-marker-line"
t "dry impact"         "STUB-IMPACT-SUMMARY"
np "dry no post" 0
[ ! -f "$STATE/last-alert" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (dry run wrote state)"; }
grep -q 'model inherit' "$H/claude-prompt" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (patches not in summary prompt)"; }
grep -q 'local-only-marker' "$H/claude-prompt" && ! grep -q 'shared-release-marker' "$H/claude-prompt" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (mirror-only changelog entries not isolated in summary prompt)"; }
grep -q -- '--model sonnet' "$H/claude-model" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (summary not on sonnet): $(cat "$H/claude-model")"; }

# 4 real run while behind -> posts once, records state
ARGS=""; run
t "alert posted" "alert posted (mirror 2.0.1 -> upstream 2.4.0, 2 releases behind) thread T1"; rc "alert rc" 0; np "one post" 1
grep -q '"to": "host"' "$H/posts" && grep -q 'HCF upstream 2.4.0 released' "$H/posts" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (post payload): $(cat "$H/posts")"; }
[ "$(cut -f1 "$STATE/last-alert" 2>/dev/null)" = "2.4.0" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (state not recorded)"; }

# 5 next day, same gap -> quiet
run
t "quiet after alert" "alerted 0d ago, next nudge at 14d"; np "still one post" 1

# 6 same gap, 15 days later -> reminder
printf '2.4.0\t%s\n' "$(( $(date +%s) - 15*86400 ))" > "$STATE/last-alert"; run
t "renudge posted" "alert posted"; np "two posts" 2
tail -1 "$H/posts" | grep -q 'mirror STILL at 2.0.1' && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (renudge subject): $(tail -1 "$H/posts")"; }

# 7 new upstream release inside the quiet window -> alerts immediately
set_upstream 2.5.0; run
t "new release alerts" "alert posted (mirror 2.0.1 -> upstream 2.5.0"; np "three posts" 3

# 8 mirror synced -> quiet, state cleared
set_mirror 2.5.0; run
t "synced" "HCF mirror current (mirror 2.5.0, upstream 2.5.0)"
[ ! -f "$STATE/last-alert" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (state not cleared after sync)"; }

# 8b oversized changelog + oversized summary -> body still fits the chatroom's 10,000-char limit
cp "$H/up/CHANGELOG.md" "$H/changelog.bak"
python3 -c "
import sys; p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('- rolling scheduler marker', '- rolling scheduler marker\n' + '\n'.join('- filler line %04d ' % i + 'x'*80 for i in range(400))))" "$H/up/CHANGELOG.md"
cat > "$H/bin/claude" <<'STUB'
#!/bin/bash
echo "STUB-IMPACT-SUMMARY"; for i in $(seq 300); do echo "long summary line $i ......................................"; done
STUB
set_mirror 2.0.1; before=$(posts); run
t "oversized still posts" "alert posted"; np "oversized one more post" $((before+1))
tail -1 "$H/posts" | python3 -c "
import json,sys; b=json.loads(sys.stdin.read())['body']
sys.exit(0 if len(b) <= 10000 and 'STUB-IMPACT-SUMMARY' in b and 'truncated — full changelog' in b and 'summary truncated' in b else 1)" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (oversized body not fitted)"; }
cp "$H/changelog.bak" "$H/up/CHANGELOG.md"; rm -f "$STATE/last-alert"

# 9 chatroom down while behind -> rc 1, state NOT recorded (retries next run)
set_mirror 2.0.1; run PB_CHATROOM_REST_URL=http://127.0.0.1:9
t "chatroom down reported" "chatroom post failed"; t "chatroom down says unreachable" "Chatroom unreachable"; rc "chatroom down rc" 1
[ ! -f "$STATE/last-alert" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (state recorded despite failed post)"; }

# 10 upstream unreachable: quiet twice, loud on the third run
run HCF_UPSTREAM_RAW="file://$H/nope"; t "transient 1" "transient, fail 1/3"; rc "transient 1 rc" 0
run HCF_UPSTREAM_RAW="file://$H/nope"; t "transient 2" "transient, fail 2/3"; rc "transient 2 rc" 0
run HCF_UPSTREAM_RAW="file://$H/nope"; t "persistent" "failed 3 runs in a row"; rc "persistent rc" 1

# 11 mirror plugin.json missing -> rc 1 with a clear message
rm "$H/mirror/.claude-plugin/plugin.json"; run
t "mirror unreadable" "HCF mirror version unreadable"; rc "mirror unreadable rc" 1

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
