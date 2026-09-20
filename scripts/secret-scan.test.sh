#!/usr/bin/env bash
# Test suite for secret-scan.sh. Builds throwaway git repos, plants content,
# asserts exit code and finding count. Run: bash secret-scan.test.sh
#
# The two regression cases at the top are the actual 2026-09-19 incident:
# the Bugsink SECRET_KEY / superuser password inline in cloud-init, and the
# scratch replacements file that the backup cron published while the first
# leak was being cleaned up. Both must be caught in --worktree mode, which
# is the mode that runs before `git add -A`.
set -u

SCAN="$(cd "$(dirname "$0")" && pwd)/secret-scan.sh"
PASS=0; FAIL=0

mkrepo() { local d; d=$(mktemp -d); git -C "$d" init -q .; printf '%s' "$d"; }

# t <expected-exit> <desc> <filename> <content>
t() {
  local expect="$1" desc="$2" fname="$3" content="$4"
  local d; d=$(mkrepo)
  mkdir -p "$d/$(dirname "$fname")"
  printf '%s\n' "$content" > "$d/$fname"
  bash "$SCAN" --worktree "$d" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got"; fi
  rm -rf "$d"
}

echo "--- regressions: the 2026-09-19 incident ---"
t 1 "bugsink SECRET_KEY inline" infra/user-data.yaml \
  '            SECRET_KEY: "da132355f3201976a667fc035f0560fc53707e571b369b4608f2c640ad3e7f1d"'
t 1 "bugsink superuser password inline" infra/user-data.yaml \
  '            CREATE_SUPERUSER: "lucas@corp.internal:ZKmb71lAH41w4iei"'
t 1 "scratch replacements file" .git-secret-replacements.txt \
  'da132355f3201976a667fc035f0560fc53707e571b369b4608f2c640ad3e7f1d==>REDACTED-KEY'

echo "--- the FIXED forms must pass (this is the desired end state) ---"
t 0 "compose env substitution" infra/user-data.yaml \
  '            SECRET_KEY: "${BUGSINK_SECRET_KEY:?create /opt/bugsink/.env first}"'
t 0 "superuser via substitution" infra/user-data.yaml \
  '            CREATE_SUPERUSER: "${BUGSINK_SUPERUSER:?create /opt/bugsink/.env first}"'
t 0 "redaction marker" infra/user-data.yaml \
  '            SECRET_KEY: "REDACTED-ROTATED-SECRET-KEY"'

echo "--- other credential shapes ---"
t 1 "private key block" deploy/id_rsa \
  '-----BEGIN OPENSSH PRIVATE KEY-----'
t 1 "rsa private key block" deploy/key.pem \
  '-----BEGIN RSA PRIVATE KEY-----'
t 1 "aws access key" config/aws.env \
  'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLQ'
t 1 "github token" .env \
  'GH_TOKEN=ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
t 1 "slack token" .env \
  'SLACK=xoxb-123456789012-abcdefghijkl'
t 1 "dsn with embedded secret" config/dsn.txt \
  'BUGSINK_DSN=https://9d8c80fb4ed54d0c96bf8e0b705b751d@bugsink.example.com/1'
t 1 "password assignment" app/config.php \
  "define('DB_PASSWORD', 'hunter2hunter2hunter2');"

echo "--- false positives that MUST pass (these repos are full of secret-ish text) ---"
t 0 "40-char git sha in a doc" docs/notes.md \
  'Fixed in commit 5cee385a1b2c3d4e5f60718293a4b5c6d7e8f900 last week.'
t 0 "guard script describing a pattern" hooks/some-guard.sh \
  "PATTERN='(password|secret|token)[[:space:]]*[:=]'"
t 0 "env var reference" .ddev/config.yaml \
  'BUGSINK_URL_HOST=$BUGSINK_URL_CONTAINER'
t 0 "placeholder in a runbook" README.md \
  'Set API_KEY="<your-api-key-here>" before running.'
t 0 "changeme placeholder" .env.example \
  'ADMIN_PASSWORD="CHANGEME"'
t 0 "prose about passwords" docs/runbook.md \
  'Copy the admin password into your password manager, then rotate it.'
t 0 "empty repo" README.md ''

echo "--- per-repo allowlist ---"
D=$(mkrepo)
printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLQ\n' > "$D/fixture.env"
bash "$SCAN" --worktree "$D" >/dev/null 2>&1
[ $? = 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (allowlist precondition): expected a finding first"; }
printf '# test fixture, not a live key\nAKIAIOSFODNN7EXAMPLQ\n' > "$D/.secret-scan-allow"
bash "$SCAN" --worktree "$D" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (allowlist suppression): expected clean after allowlisting"; }
rm -rf "$D"

echo "--- findings never echo the secret itself ---"
D=$(mkrepo)
printf 'SECRET_KEY: "da132355f3201976a667fc035f0560fc53707e571b369b4608f2c640ad3e7f1d"\n' > "$D/x.yaml"
OUT=$(bash "$SCAN" --worktree "$D" 2>&1)
if echo "$OUT" | grep -q 'da132355f3201976a667fc035f'; then
  FAIL=$((FAIL+1)); echo "FAIL (leak in output): scanner printed the matched secret"
else PASS=$((PASS+1)); fi
echo "$OUT" | grep -q 'x.yaml:1: long-hex-secret' && PASS=$((PASS+1)) \
  || { FAIL=$((FAIL+1)); echo "FAIL (finding format): expected 'x.yaml:1: long-hex-secret', got: $OUT"; }
rm -rf "$D"

echo "--- --range mode (already-committed but unpushed) ---"
D=$(mkrepo)
git -C "$D" config user.email t@t; git -C "$D" config user.name t
echo "clean line" > "$D/a.txt"; git -C "$D" add -A; git -C "$D" commit -q -m base
BASE=$(git -C "$D" rev-parse HEAD)
printf 'GH_TOKEN=ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8\n' >> "$D/a.txt"
git -C "$D" add -A; git -C "$D" commit -q -m bad
bash "$SCAN" --range "$D" "$BASE..HEAD" >/dev/null 2>&1
[ $? = 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (--range detects added secret)"; }
bash "$SCAN" --range "$D" "$BASE..$BASE" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (--range empty range is clean)"; }
rm -rf "$D"

echo "--- usage errors ---"
bash "$SCAN" >/dev/null 2>&1; [ $? = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (no args -> exit 2)"; }
bash "$SCAN" --worktree /nonexistent-xyz >/dev/null 2>&1; [ $? = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (bad repo -> exit 2)"; }

echo
echo "secret-scan tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

echo "--- path: allowlist form (a scanner must tolerate its own tests) ---"
D=$(mkrepo)
mkdir -p "$D/scripts"
printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLQ\n' > "$D/scripts/thing.test.sh"
bash "$SCAN" --worktree "$D" >/dev/null 2>&1
[ $? = 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (path allow precondition)"; }
printf 'path:^scripts/.*\\.test\\.sh$\n' > "$D/.secret-scan-allow"
bash "$SCAN" --worktree "$D" >/dev/null 2>&1
[ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (path allow suppression)"; }
# a path allow must NOT leak into other files
printf 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLQ\n' > "$D/live.env"
bash "$SCAN" --worktree "$D" >/dev/null 2>&1
[ $? = 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (path allow over-reached to other files)"; }
rm -rf "$D"

echo
echo "secret-scan tests (with path form): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
