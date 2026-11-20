#!/bin/bash
# Test suite for infra-uptime-watch.sh — sandboxed HOME (so notify-lib sends
# no email and writes alerts.log under the sandbox), fake HTTP server playing
# Bugsink + the logs proxy + the MCP, stub openssl. Run: bash infra-uptime-watch.test.sh
SCRIPT="$(cd "$(dirname "$0")" && pwd)/infra-uptime-watch.sh"
PASS=0; FAIL=0
for bin in python3 curl flock; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin missing"; exit 0; }
done

H=$(mktemp -d); trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$H"' EXIT
mkdir -p "$H/mode" "$H/bin" "$H/home/.config"

# Fake server. Behaviour per route is read from $H/mode/* on every request:
#   health            "<code> <body>"      GET  /health/ready
#   ingest_<id>       "<code>"             POST /api/<id>/envelope/
#   logs_<token>      "<code> <rows> [<rows30d>]"  POST /select/logsql/query (by bearer);
#                     rows30d answers the 30d pending-window query (default = rows)
#   mcp               "<code>"             GET  /mcp/
# Every request line + auth header is appended to $H/requests.
cat > "$H/srv.py" <<'PY'
import http.server, sys, pathlib, re, urllib.parse
mode = pathlib.Path(sys.argv[2]); reqlog = pathlib.Path(sys.argv[3])
def m(name, default):
    p = mode / name
    return p.read_text().strip() if p.exists() else default
class Hd(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b""):
        self.send_response(int(code)); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log(self, body=b""):
        with reqlog.open("a") as f:
            f.write(f"{self.command} {self.path} auth={self.headers.get('Authorization','')} sentry={self.headers.get('X-Sentry-Auth','')} body={body[:200]!r}\n")
    def do_GET(self):
        self.log()
        if self.path == "/health/ready":
            code, _, body = m("health", "200 OK").partition(" "); return self.reply(code, body.encode())
        if self.path == "/mcp/":
            return self.reply(m("mcp", "200"))
        self.reply(404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))); self.log(body)
        mo = re.match(r"^/api/(\d+)/envelope/$", self.path)
        if mo:
            return self.reply(m(f"ingest_{mo.group(1)}", "200"), b"{}")
        if self.path == "/select/logsql/query":
            tok = self.headers.get("Authorization", "").removeprefix("Bearer ")
            parts = m(f"logs_{tok}", "403 0").split()
            code, rows = parts[0], parts[1]
            q = urllib.parse.parse_qs(body.decode()).get("query", [""])[0]
            if q.startswith("_time:30d") and len(parts) > 2:
                rows = parts[2]
            with (mode / "queries").open("a") as f:
                f.write(q + "\n")
            if not q.startswith("_time:30d"):
                (mode / "lastquery").write_text(q)
            return self.reply(code, f'{{"rows":"{rows}"}}\n'.encode() if code == "200" else b"denied")
        self.reply(404)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Hd).serve_forever()
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 "$H/srv.py" "$PORT" "$H/mode" "$H/requests" & SRV_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health/ready" && break; sleep 0.1; done

# stub openssl: s_client prints nothing; x509 prints the date in $H/mode/tls_end
cat > "$H/bin/openssl" <<STUB
#!/bin/bash
[ "\$1" = x509 ] && [ -f "$H/mode/tls_end" ] && echo "notAfter=\$(cat "$H/mode/tls_end")"
exit 0
STUB
# stub notify-send: never pop up on the real desktop
printf '#!/bin/bash\nexit 0\n' > "$H/bin/notify-send"
chmod +x "$H/bin/openssl" "$H/bin/notify-send"

B="http://127.0.0.1:$PORT"
cat > "$H/bugsink.env" <<EOF
BUGSINK_API_TOKEN=nope
BUGSINK_DSN_PPS_DEV=$B/x/1
BUGSINK_DSN_PPS_PROD="http://keyprod@127.0.0.1:$PORT/2"
BUGSINK_DSN_LCD_UAT=http://keyuat@127.0.0.1:$PORT/6
BUGSINK_DSN_PPS=http://legacy@127.0.0.1:$PORT/1
EOF
cat > "$H/tokens.env" <<'EOF'
LOGS_W_PPS_PROD=writeonly
LOGS_R_PPS_PROD=rprod
LOGS_R_PPS_UAT='ruat'
EOF
write_cfg() {
  cat > "$H/cfg.env" <<EOF
BUGSINK_URL=$B
LOGS_URL=$B
LOGS_MCP_URL=$B/mcp/
BUGSINK_ENV=$H/bugsink.env
LOGS_TOKENS=$H/tokens.env
$1
EOF
}
write_cfg ""
echo "200 5" > "$H/mode/logs_rprod"; echo "200 1" > "$H/mode/logs_ruat"

ALERTS="$H/home/monitor/alerts.log"
run() {  # run [ENV=VAL ...]
  OUT=$(env HOME="$H/home" PATH="$H/bin:$PATH" PB_UPTIME_CFG="$H/cfg.env" \
        PB_UPTIME_STATE="$H/state" TLS_EVERY_SECS=999999 "$@" bash "$SCRIPT" 2>&1); RC=$?
}
ok()  { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  out: $OUT"; fi; }
alerts() { cat "$ALERTS" 2>/dev/null; }
nalerts() { alerts | wc -l; }
reset() { rm -rf "$H/state" "$ALERTS" "$H/requests"; }

# --- 1. all healthy ---------------------------------------------------------
reset; run
ok "healthy: rc 0"                     '[ "$RC" -eq 0 ]'
ok "healthy: 8 checks ok"              'grep -q "uptime: 8/8 ok" <<<"$OUT"'
ok "healthy: no alert"                 '[ "$(nalerts)" -eq 0 ]'
ok "probes PROD+UAT DSNs only"         '[ "$(grep -c "envelope" "$H/requests")" -eq 2 ]'
ok "no probe of dev or legacy alias"   '! grep -q "/api/1/envelope" "$H/requests"'
ok "envelope carries sentry_key"       'grep -q "/api/2/envelope/.*sentry_key=keyprod" "$H/requests"'
ok "quoted DSN parsed"                 'grep -q "body=b.{\"dsn\":\"http://keyprod@" "$H/requests"'
ok "header-only envelope (no items)"   '[ "$(grep "/api/2/envelope" "$H/requests" | grep -o "\\\\n" | wc -l)" -eq 1 ]'
ok "reads with read tokens only"       '! grep -q "auth=Bearer writeonly" "$H/requests"'
ok "single-quoted token parsed"        'grep -q "auth=Bearer ruat" "$H/requests"'
ok "state files written"               '[ "$(cat "$H/state/logs-pps-prod")" = "ok 0 0 0" ]'

# --- 2. one failure = no alert; second = alert; third = no re-alert ---------
reset; echo "503 down" > "$H/mode/health"
run
ok "1st fail: reported in summary"     'grep -q "failing: bugsink-http" <<<"$OUT"'
ok "1st fail: no alert yet"            '[ "$(nalerts)" -eq 0 ]'
ok "health down skips ingest probes"   '! grep -q envelope "$H/requests"'
run
ok "2nd fail: one alert"               '[ "$(nalerts)" -eq 1 ]'
ok "alert is critical + names check"   'alerts | grep -q "critical	infra DOWN: bugsink-http"'
ok "alert body carries HTTP code"      'alerts | grep -q "health/ready HTTP 503"'
run
ok "3rd fail: no re-alert in window"   '[ "$(nalerts)" -eq 1 ]'
run RENOTIFY_SECS=0
ok "re-alert after RENOTIFY window"    '[ "$(nalerts)" -eq 2 ]'
rm "$H/mode/health"; run
ok "recovery: normal alert"            'alerts | tail -1 | grep -q "normal	infra recovered: bugsink-http"'
ok "recovery: state reset"             '[ "$(cat "$H/state/bugsink-http")" = "ok 0 0 0" ]'
run
ok "recovery sent once"                '[ "$(alerts | grep -c recovered)" -eq 1 ]'

# --- 3. blip (fail then ok) never alerts --------------------------------------
reset; echo "500 x" > "$H/mode/health"; run; rm "$H/mode/health"; run
ok "blip: no down, no recovery alert"  '[ "$(nalerts)" -eq 0 ]'

# --- 4. ingest quota 429 ----------------------------------------------------
reset; echo 429 > "$H/mode/ingest_2"; run; run
ok "429 alerts quota exhausted"        'alerts | grep -q "bugsink-ingest-pps-prod.*429 quota exhausted"'
ok "429 only on that project"          '! alerts | grep -q "lcd-uat"'
rm "$H/mode/ingest_2"

# --- 5. logs: silent tenant, 403 tenant, store down -------------------------
reset; echo "200 0 7" > "$H/mode/logs_ruat"; run; run
ok "0 rows = shipper stalled alert"    'alerts | grep -q "logs-pps-uat: 0 log lines in the last 6h"'
ok "queries exclude pb_probe rows"     'grep -q -- "-source:pb_probe" "$H/mode/lastquery"'
reset; echo "200 0 0" > "$H/mode/logs_ruat"; run; run; run
ok "never shipped = pending, no alert" '[ "$(nalerts)" -eq 0 ]'
ok "pending listed in summary"         'grep -q "pending (never shipped): logs-pps-uat" <<<"$OUT"'
ok "pending leaves no state"           '[ ! -f "$H/state/logs-pps-uat" ]'
ok "pending checks 30d window"         'grep -q "^_time:30d -source:pb_probe" "$H/mode/queries"'
echo "200 3" > "$H/mode/logs_ruat"; run
ok "first real rows = watched"         '[ "$(cat "$H/state/logs-pps-uat")" = "ok 0 0 0" ]'
ok "prod tenant still ok"              '[ "$(cat "$H/state/logs-pps-prod")" = "ok 0 0 0" ]'
reset; echo "403 0" > "$H/mode/logs_ruat"; run; run
ok "403 = tenant mapping alert"        'alerts | grep -q "logs-pps-uat: HTTP 403"'
reset; echo "502 0" > "$H/mode/logs_rprod"; run; run
ok "5xx = store down"                  'alerts | grep -q "logs-pps-prod: log store unreachable (HTTP 502"'
ok "store down skips other tenants"    '! alerts | grep -q "logs-pps-uat"'
ok "skipped tenant keeps state"        '[ ! -f "$H/state/logs-pps-uat" ]'
echo "200 5" > "$H/mode/logs_rprod"; echo "200 1" > "$H/mode/logs_ruat"

# --- 6. maxage: env default, per-env override, per-tenant override ----------
reset; run; ok "PROD default 30m"      'true'
write_cfg "LOGS_MAXAGE_PROD=45m"; reset; echo "200 0 7" > "$H/mode/logs_ruat"; run
ok "per-env override (UAT default 6h)" 'grep -q "_time:6h" "$H/mode/lastquery"'
write_cfg "LOGS_MAXAGE_PPS_UAT=24h"; reset; run
ok "per-tenant override wins"          'grep -q "_time:24h" "$H/mode/lastquery"'
echo "200 1" > "$H/mode/logs_ruat"; write_cfg ""

# --- 7. batching: several down in one run = ONE alert -----------------------
reset; echo 429 > "$H/mode/ingest_2"; echo 429 > "$H/mode/ingest_6"; echo 500 > "$H/mode/mcp"; run; run
ok "batched into one alert"            '[ "$(nalerts)" -eq 1 ]'
ok "batched alert names all three"     'alerts | grep -q "infra DOWN: bugsink-ingest-lcd-uat, bugsink-ingest-pps-prod, logs-mcp"'
rm "$H/mode/ingest_2" "$H/mode/ingest_6" "$H/mode/mcp"

# --- 8. misconfig = failing check through the state machine, rc 0 -----------
reset; OLD_CFG="$H/cfg.env"; mv "$H/cfg.env" "$H/cfg.off"
run; run
ok "missing config: rc still 0"        '[ "$RC" -eq 0 ]'
ok "missing config: alerts once"       '[ "$(nalerts)" -eq 1 ] && alerts | grep -q "BUGSINK_URL not set"'
mv "$H/cfg.off" "$OLD_CFG"
reset; printf 'LOGS_W_X=1\n' > "$H/tokens.only-write"; write_cfg "LOGS_TOKENS=$H/tokens.only-write"; run; run
ok "no read tokens = config alert"     'alerts | grep -q "logs-config: no LOGS_R_"'
write_cfg ""
reset; write_cfg "LOGS_MCP_URL="; run
ok "MCP check skipped when unset"      'grep -q "uptime: 7/7 ok" <<<"$OUT"'
write_cfg ""

# --- 9. TLS (hourly gate, expiry threshold) ---------------------------------
# point the urls at https so the TLS check runs; HTTP checks then fail — only
# the tls-* state matters here
mk_tls_cfg() { write_cfg "BUGSINK_URL=https://bugsink.example.invalid
LOGS_URL=https://logs.example.invalid"; }
reset; mk_tls_cfg; date -d '+60 days' -u '+%b %e %H:%M:%S %Y GMT' > "$H/mode/tls_end"
run TLS_EVERY_SECS=0 CURL_MAX=2
ok "TLS 60d left = ok"                 '[ "$(cat "$H/state/tls-bugsink")" = "ok 0 0 0" ] && [ -f "$H/state/tls-logs" ]'
date -d '+3 days' -u '+%b %e %H:%M:%S %Y GMT' > "$H/mode/tls_end"
run TLS_EVERY_SECS=0 CURL_MAX=2; run TLS_EVERY_SECS=0 CURL_MAX=2
ok "TLS 3d left = alert"               'alerts | grep -q "tls-bugsink: TLS cert expires in [23]d"'
rm -f "$H/state/tls-bugsink"; run TLS_EVERY_SECS=999999 CURL_MAX=2
ok "TLS gated to once per interval"    '[ ! -f "$H/state/tls-bugsink" ]'
rm -f "$H/mode/tls_end"; reset; run TLS_EVERY_SECS=0 CURL_MAX=2
ok "unreadable cert = fail"            'grep -q "^fail 1" "$H/state/tls-bugsink"'
write_cfg ""

# --- 10. overlapping runs ---------------------------------------------------
reset; mkdir -p "$H/state"; exec 8>"$H/state/.lock"; flock -n 8
run
ok "overlap: second run skips"         'grep -q "previous run still going" <<<"$OUT" && [ "$RC" -eq 0 ]'
exec 8>&-

# --- 11. corrupt state file is tolerated -------------------------------------
reset; mkdir -p "$H/state"; echo "garbage x y" > "$H/state/bugsink-http"; run
ok "corrupt state: treated as fresh"   '[ "$(cat "$H/state/bugsink-http")" = "ok 0 0 0" ] && [ "$(nalerts)" -eq 0 ]'

echo "infra-uptime-watch: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
