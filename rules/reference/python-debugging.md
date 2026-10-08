---
paths:
  - "**/*.py"
---

# Python Debugging Protocol — MANDATORY

Twin of `php-debugging.md`. When debugging Python runtime behaviour (wrong value,
wrong branch, None where a value was expected, a test asserting the wrong state),
get **real runtime data** instead of guessing.

## Order of tools

1. **Bugsink first** for anything that already happened outside your shell (uvicorn
   request, background job, prod). It holds the exception chain, frames and locals.
   Protocol: `investigation.md`.
2. **Failing test** → re-run that one test with `-x -l --tb=long` (`-l` prints locals
   per frame). Often enough.
3. **mcp-debugger MCP** (debugpy over DAP) when you need to step or inspect state:
   - Script / test: `create_debug_session(language="python")` → `set_breakpoint(file, line)`
     → `start_debugging(scriptPath=".venv/bin/pytest", args=["-x","tests/a/test_b.py::test_c"])`
     → `get_stack_trace` / `get_variables` / `evaluate_expression` → `step_*` / `continue_execution`.
   - Running uvicorn: start it under `uv run python -m debugpy --listen 127.0.0.1:5678 -m uvicorn <app> --port 8001`
     (separate port; never attach to the `--reload` dev server, the reloader forks), then attach
     on 127.0.0.1:5678.
   - Logpoints (`set_breakpoint` with `logMessage`) for watching a hot path without pausing.
4. `structlog` debug lines are acceptable **only** when committed as permanent, useful logs.

## Banned

- `print()` debugging, `breakpoint()`, `pdb`/`ipdb` in `src/` — `python-debug-guard.sh`
  blocks the edit. Scripts, tests and experiments are exempt.
- Claiming a runtime cause from reading code alone when a debugger or Bugsink could show it.
