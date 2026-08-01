#!/bin/bash
# changed-line-coverage.sh <project_root> <clover_xml> <min_pct> <base_ref>
#
# Checks that the lines CHANGED vs <base_ref> (default HEAD) are actually
# executed by the test suite, using a clover coverage report. This is the
# hollow-test catcher: a green suite that never executes the changed lines
# fails here.
#
# Exit codes:
#   0 — changed executable lines covered at or above <min_pct> (or nothing to check)
#   1 — below threshold
#   3 — cannot check: clover missing, stale (older than a changed file), or no python3
#
# Only PHP files are checked (clover is a PHP-ecosystem format). A changed file
# entirely absent from the report counts ALL its changed lines as uncovered —
# that absence is precisely the smell being hunted.
#
# Mutation testing (Infection) is the stronger form of this check; see
# hooks/TEST-GATE.md for the per-project recipe.

ROOT="$1"
CLOVER="$2"
MIN="${3:-60}"
BASE="${4:-HEAD}"

[ -d "$ROOT" ] || { echo "coverage: bad project root"; exit 3; }
cd "$ROOT" || exit 3
[ -f "$CLOVER" ] || { echo "coverage: clover report not found: $CLOVER"; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "coverage: python3 not available"; exit 3; }

DIFF_FILES=$(git diff --name-only "$BASE" -- '*.php' 2>/dev/null)
[ -z "$DIFF_FILES" ] && exit 0

# staleness: report must postdate every changed file
NEWEST=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  M=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ "$M" -gt "$NEWEST" ] && NEWEST=$M
done <<< "$DIFF_FILES"
CMTIME=$(stat -c %Y "$CLOVER" 2>/dev/null || echo 0)
if [ "$NEWEST" -gt 0 ] && [ "$CMTIME" -lt "$NEWEST" ]; then
  echo "coverage: clover report is older than changed files — regenerate (run suite with coverage)"
  exit 3
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/tg-cov.XXXXXX") || exit 3
git diff -U0 "$BASE" -- '*.php' > "$TMP" 2>/dev/null

python3 - "$CLOVER" "$MIN" "$TMP" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

clover, minpct, diffp = sys.argv[1], float(sys.argv[2]), sys.argv[3]

changed = {}
cur = None
for line in open(diffp, encoding="utf-8", errors="replace"):
    m = re.match(r"^\+\+\+ b/(.*)$", line)
    if m:
        cur = m.group(1)
        changed.setdefault(cur, set())
        continue
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
    if m and cur:
        start = int(m.group(1))
        n = int(m.group(2)) if m.group(2) is not None else 1
        changed[cur].update(range(start, start + n))

changed = {f: l for f, l in changed.items() if l and f != "dev/null"}
if not changed:
    sys.exit(0)

try:
    tree = ET.parse(clover)
except ET.ParseError as e:
    print(f"coverage: clover parse error: {e}")
    sys.exit(3)

cov = {}
for fe in tree.iter("file"):
    p = fe.get("path") or fe.get("name") or ""
    lines = {}
    for le in fe.iter("line"):
        if le.get("type") in (None, "stmt", "cond", "method"):
            try:
                lines[int(le.get("num"))] = int(le.get("count") or 0)
            except (TypeError, ValueError):
                pass
    if p:
        cov[p] = lines

def lookup(rel):
    for p, l in cov.items():
        if p == rel or p.endswith("/" + rel):
            return l
    return None

total = hit = 0
missing, uncovered = [], []
for rel, lns in sorted(changed.items()):
    fl = lookup(rel)
    if fl is None:
        total += len(lns)
        missing.append(rel)
        continue
    for n in sorted(lns):
        if n in fl:  # lines absent from clover are non-executable — skipped
            total += 1
            if fl[n] > 0:
                hit += 1
            else:
                uncovered.append(f"{rel}:{n}")

if total == 0:
    sys.exit(0)

pct = 100.0 * hit / total
print(f"changed-line coverage: {hit}/{total} = {pct:.1f}% (min {minpct:.0f}%)")
if missing:
    print("changed files absent from the coverage report (all changed lines counted uncovered): "
          + ", ".join(missing[:10]))
if uncovered:
    print("uncovered changed lines: " + ", ".join(uncovered[:20]))
sys.exit(0 if pct >= minpct else 1)
PY
RC=$?
rm -f "$TMP"
exit $RC
