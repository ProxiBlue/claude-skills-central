---
paths:
  - "**/pyproject.toml"
  - "**/uv.lock"
  - "**/requirements*.txt"
---

# Python dependency upgrade verification — MANDATORY

Twin of `upgrade-verification.md`. Applies to any dependency bump, Python version bump,
new dependency, or framework upgrade (FastAPI, Starlette, pydantic, SQLAlchemy …).

Before ANY "verified" / "all passing" claim:

1. `uv lock` then `uv sync --frozen` succeed; `requirements.txt` re-exported
   (`uv export --no-dev --no-hashes -o requirements.txt`) and the diff reviewed —
   prod installs from that file, not the lock.
2. **Full** test suite (`uv run pytest -q`), not a targeted subset. Paste the summary line.
3. `uv run ruff check src tests` and `uv run basedpyright` — report new findings vs before.
4. `uv run pip-audit` — no new known vulnerabilities, or each one named and accepted by the owner.
5. Read the upstream changelog for every **major/minor** bump of a direct dependency
   (Context7 or the project's CHANGELOG via curl). Cite the breaking-change lines that apply.
6. Boot the app (`ddev restart` or the project's uvicorn hook), hit `/health` and one real
   end-to-end flow by hand or Playwright. Name the flow.
7. Binary/system deps (poppler, potrace, libgl …) on the prod host: list any the bump needs;
   rsync deploys ship code only.

A claim that skips any step must say which step and why.
