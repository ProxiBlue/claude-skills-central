#!/bin/bash
# Test suite for php-debug-guard.sh — feed PreToolUse JSON, assert exit code.
# Run: bash php-debug-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/php-debug-guard.sh"
PASS=0; FAIL=0

t() { # t <expected-exit> <desc> <new_string> [file]
  local expect="$1" desc="$2" body="$3" file="${4:-/tmp/x/Foo.php}"
  printf '{"tool_input":{"file_path":"%s","new_string":%s}}' "$file" "$(printf '%s' "$body" | jq -Rs .)" \
    | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — body: $body"; fi
}

# --- blocked (exit 2) --------------------------------------------------------
t 2 "var_dump"            'var_dump($x);'
t 2 "print_r"             'print_r($x);'
t 2 "bare ray"            'ray($x);'
t 2 "indented ray"        '    ray($foo)->die();'
t 2 "method ray"          '$this->ray($x);'
t 2 "dd"                  'dd($x);'
t 2 "dump"                'dump($x);'
t 2 "phtml"               '<?php var_dump($block) ?>' /tmp/x/t.phtml

# --- allowed (exit 0): chat 30d3e781 false positives ---------------------------
t 0 "toOptionArray"       'public function toOptionArray(): array'
t 0 "in_array"            'if (in_array($a, $b, true)) {'
t 0 "is_array"            'is_array($x)'
t 0 "Array.isArray"       'Array.isArray(x)'
t 0 "method dump"         '$collection->dump($x);'
t 0 "non-php file"        'var_dump($x);' /tmp/x/notes.md

echo "php-debug-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
