#!/bin/bash
# PostToolUse Edit|Write|MultiEdit hook — checks a just-edited *.xml file is
# well-formed, catching a broken file at the point it was broken instead of
# at the next `bin/magento` invocation.
#
# Origin incident: a worker wrote `--` inside an XML comment in a Magento
# config.xml (XML forbids `--` inside comments — it's the sequence that
# terminates `<!--`). Every `bin/magento` call afterward died on the broken
# config.xml, including unrelated commands, until someone tracked it down.
# A malformed XML comment is otherwise invisible in a diff review — it reads
# as ordinary prose inside the comment markers.
#
# Checks with whichever parser is available, in order of preference:
#   1. xmllint --noout         (libxml2 CLI, most precise error output)
#   2. php -r (DOMDocument)    (loadXML with LIBXML_NOERROR off, collects
#                               libxml_get_errors())
#   3. python3 -c (xml.dom.minidom)
# If none of the three is on PATH, exits 0 silently — this hook is a nice-to-
# have early warning, never a hard requirement, and must never block an edit
# just because the environment lacks a parser.
#
# Input: Claude Code sends the tool JSON on stdin. For Edit/Write/MultiEdit
# the file path is at `.tool_input.file_path`.
#
# Per-project opt-out: a line `xml-wellformed-check` in
# <repo>/.claude/rules-disable.
#
# Defensive: no set -e. Non-xml files, missing files, jq missing, or
# unparseable input → silent no-op (exit 0). Only a real parse failure on an
# xml file that was just edited blocks (exit 2).

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

case "$F" in
  *.xml) ;;
  *) exit 0 ;;
esac

[ -f "$F" ] || exit 0

# --- per-project opt-out ------------------------------------------------------
TOPLEVEL=$(cd "$(dirname "$F")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'xml-wellformed-check' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

ERR=""
RC=1

if command -v xmllint >/dev/null 2>&1; then
  ERR=$(xmllint --noout "$F" 2>&1)
  RC=$?
elif command -v php >/dev/null 2>&1; then
  ERR=$(php -r '
    $f = $argv[1];
    libxml_use_internal_errors(true);
    $doc = new DOMDocument();
    $ok = $doc->load($f);
    if ($ok === false) {
      foreach (libxml_get_errors() as $e) {
        fwrite(STDERR, trim($e->message) . " (line " . $e->line . ")\n");
      }
      exit(1);
    }
    exit(0);
  ' "$F" 2>&1 1>/dev/null)
  RC=$?
elif command -v python3 >/dev/null 2>&1; then
  ERR=$(python3 -c '
import sys
import xml.dom.minidom as minidom
try:
    minidom.parse(sys.argv[1])
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
' "$F" 2>&1 1>/dev/null)
  RC=$?
else
  # no parser available — nothing to check with, never block on this
  exit 0
fi

[ "$RC" = 0 ] && exit 0

{
  echo "BLOCKED by xml-wellformed-check.sh: $F is not well-formed XML after this edit."
  echo ""
  echo "Parser error:"
  echo "$ERR" | sed 's/^/  /'
  echo ""
  echo "Common cause: a literal \`--\` inside an XML comment. XML forbids \`--\`"
  echo "anywhere inside <!-- ... --> (it's the sequence that terminates the"
  echo "comment), so a comment like <!-- disable foo -- see TICKET-123 --> is"
  echo "invalid and the file fails to parse from that point on. This has taken"
  echo "down every \`bin/magento\` call against a broken config.xml before —"
  echo "the breakage is invisible in a normal diff review since it reads as"
  echo "ordinary prose inside the comment markers."
  echo ""
  echo "Fix the file and re-check, or replace the -- with a different separator"
  echo "(e.g. a single hyphen, an em dash, or just a space)."
} >&2
exit 2
