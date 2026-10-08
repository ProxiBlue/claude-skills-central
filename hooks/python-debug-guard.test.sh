#!/bin/bash
# Test suite for python-debug-guard.sh — feed PreToolUse JSON, assert exit.
# Run: bash python-debug-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/python-debug-guard.sh"
PHPHOOK="$(cd "$(dirname "$0")" && pwd)/php-debug-guard.sh"
PASS=0; FAIL=0
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

REPO=$(mktemp -d); trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q

w() { # w <expected> <desc> <file> <content>  (Write)
  jq -n --arg f "$REPO/$3" --arg c "$4" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}' \
    | bash "${HK:-$HOOK}" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($2): expected $1 got $got"; fi
}
e() { # e <expected> <desc> <file> <old> <new>  (Edit)
  jq -n --arg f "$REPO/$3" --arg o "$4" --arg n "$5" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL ($2): expected $1 got $got"; fi
}

# --- blocked ------------------------------------------------------------------
w 2 "breakpoint()"            src/pkg/a.py $'def f(x):\n    breakpoint()\n    return x'
w 2 "import pdb"              src/pkg/a.py $'import pdb\npdb.set_trace()'
w 2 "pdb.set_trace inline"    src/pkg/a.py 'x = 1; import pdb; pdb.set_trace()'
w 2 "import ipdb"             app/a.py     'import ipdb'
w 2 "from pdb import"         app/a.py     'from pdb import set_trace'
w 2 "print DEBUG"             src/pkg/a.py '    print("DEBUG total", total)'
w 2 "print XXX"               src/pkg/a.py 'print("XXX here")'
w 2 "print f-string {x=}"     src/pkg/a.py '    print(f"{total=}")'
w 2 "print f-string {x=!r}"   src/pkg/a.py 'print(f"got {resp.status=!r} ok")'
e 2 "edit adds breakpoint"    src/pkg/a.py $'    return x' $'    breakpoint()\n    return x'

# --- allowed ------------------------------------------------------------------
w 0 "plain print"             src/pkg/cli.py 'print("Processed", n, "files")'
w 0 "f-string no ="           src/pkg/cli.py 'print(f"{n} files")'
w 0 "f-string comparison"     src/pkg/cli.py 'print(f"{a == b}")'
w 0 "logger.debug"            src/pkg/a.py   'log.debug("DEBUG value", x=x)'
w 0 "commented breakpoint"    src/pkg/a.py   '    # breakpoint()'
w 0 "word containing pdb"     src/pkg/a.py   'import pdbparser'
w 0 "tests/ exempt"           tests/test_a.py 'breakpoint()'
w 0 "scripts/ exempt"         scripts/x.py   'import pdb'
w 0 "experiments/ exempt"     experiments/y.py 'print(f"{x=}")'
w 0 "conftest exempt"         conftest.py    'import pdb'
w 0 "non-py file"             src/notes.md   'breakpoint()'
e 0 "edit keeps existing"     src/pkg/a.py   $'breakpoint()\nreturn 1' $'breakpoint()\nreturn 2'
e 0 "edit removes breakpoint" src/pkg/a.py   $'breakpoint()\nreturn 1' 'return 1'

# --- PHP regression: php-debug-guard untouched, python guard ignores .php ----
w 0 "py guard ignores .php"   app/code/X/Y.php 'var_dump($x);'
HK="$PHPHOOK" w 2 "php guard still blocks var_dump" app/code/X/Y.php 'var_dump($x);'
HK="$PHPHOOK" w 0 "php guard ignores .py" src/pkg/a.py 'breakpoint()'

# --- opt-out ------------------------------------------------------------------
mkdir -p "$REPO/.claude"; echo 'python-debug-guard' > "$REPO/.claude/rules-disable"
w 0 "rules-disable opt-out"   src/pkg/a.py 'breakpoint()'

echo "python-debug-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
