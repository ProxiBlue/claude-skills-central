# Security Quorum Team (`team_security`)

## Purpose
Twenty-one specialist agents organised into **seven trios**, each covering one security domain. Every trio reaches an internal 2-of-3 consensus PASS / FAIL / NEEDS-REVIEW verdict on its domain. A moderator then synthesizes the seven trio verdicts into a single overall security report.

Framework: **OWASP Top 10 (2021)** plus cross-cutting concerns. Aligned with the security evaluator prompt at `chiefloopadverserial/embed/security_evaluator_prompt.txt`.

No code is written — output is a security audit + consensus verdict per domain + overall pass/fail.

---

## Existing skills & agents this team draws from

Every agent in this team has the full skill catalogue available. The relevant ones per role are:

### Skills (in `~/claude-skills-central/skills/` and `proxiblue-skills`)
- **`security-scan`** — Magento 2 dependency CVE scan, admin/session/cookie/HTTPS config audit, file-system security. Used by Trios 4, 5, 6.
- **`workflow-security-audit`** — Magento custom-code SQL-injection / XSS / CSRF / authn-bypass / file-upload / command-injection / unserialize / hardcoded-secrets / IDOR / CSP / weak-crypto checks, with `mcp__pb-codegraph__impact` propagation. Used by Trios 1, 2, 3, 7.
- **`server-scan`** — server-level malware, webshell, and post-incident forensics. Used by Trios 4, 5, 6 when an SSH target is in scope.
- **`code-quality-audit`** — PSR-12, phpstan, phpcs, phpmd. Used by the Defensive Auditors as a baseline signal.
- **`database-query-analysis`** — direct DB inspection via the database / magento2-dev MCPs. Used by Trio 1 (verify actual query construction) and Trio 3 (verify ACL state).
- **`magento-diagnostic`** — cache, index, config state. Used by Trio 2 (Defensive Auditor reads CSP/header config) and Trio 6 (session/cookie config).
- **`audit-loop`** — iterative audit pattern. The team output can feed this loop for fix-and-re-audit.
- **`workflow-investigate-bug`** — read-only forensic protocol; matches our read-only stance and the mandatory investigation protocol at `~/claude-skills-central/rules/investigation.md`.
- **`github-analysis`** — when the audit target is a GitHub ticket / PR.

### Agents (in `claude-plugins-central` marketplaces)
- **`devils-advocate`** (hcf, opus) — gap-finder using `mcp__pb-codegraph__impact`. The **Moderator** adopts this mindset for cross-trio synthesis: hunt blind spots, not redesigns.
- **`codegraph-reviewer`** (pb-hcf, opus) — diff-impact reviewer that surfaces indirect callers via the code graph. Every **Static Analyst** in the team inherits this technique to chase data-flow beyond grep.
- **`standards-enforcer`** (hcf, opus) — read-the-rules, verify-compliance worker. Every **Defensive Auditor** in the team inherits this pass-then-verify pattern (don't just spot what's wrong; explicitly walk every control and confirm it is correctly applied).
- **`tdd-worker`** (hcf) — explicitly **NOT used** here; this team is read-only.

### MCPs available
- `mcp__pb-codegraph__impact` / `__find_symbol` / `__query` / `__context` — for code-graph impact analysis (Static Analysts + Moderator).
- `database` / `magento2-dev` — direct DB / Magento config inspection (Trios 1, 3, 6).
- `WebSearch` / `WebFetch` — for Trio 5 online CVE lookup against NVD / OSV / GitHub Advisory DB.

---

## Team Composition (21 specialists + 1 moderator)

The team is **seven trios of three agents** (21 total). Each trio audits one security domain. Within every trio, the three agents take different angles so the consensus has to be earned, not parroted:

| Role within trio | Angle |
|---|---|
| **Static Analyst** | Reads code, traces data flows, hunts vulnerable patterns. Cites file:line for every claim. |
| **Adversarial Tester** | Thinks like an attacker. Builds exploit hypotheses, payload examples, attack chains. No actual exploitation — investigation only. |
| **Defensive Auditor** | Checks framework defenses, configs, headers, libraries, and mitigations *already* present. Verifies they're correctly applied, not just imported. |

### Consensus rule (per trio)
- Each agent independently votes `PASS`, `FAIL`, or `NEEDS-REVIEW` with cited evidence.
- 2/3 = trio verdict. The dissenting agent's position is **preserved** in the report, not discarded.
- A trio cannot report `PASS` if any agent voted `FAIL` without that agent being explicitly overridden with cited rebuttal evidence.
- All three agents must vote — no abstentions.

### Final overall verdict
- All 7 trios must report `PASS` for the overall verdict to be `PASS`.
- Any single `FAIL` trio = overall `FAIL`.
- Any `NEEDS-REVIEW` with no `FAIL` = overall `NEEDS-REVIEW`.

---

## The Seven Trios

### Trio 1 — Injection (SQL / NoSQL / Command / Template)
**OWASP**: A03:2021 – Injection
**Models**: opus, opus, sonnet
**Scope**: SQL injection, NoSQL injection, OS command injection, template injection, LDAP injection, header injection, log injection.
**Skills to invoke**: `workflow-security-audit` (SQL/command-injection patterns), `database-query-analysis` (verify the queries that actually run), `code-quality-audit` (phpstan signal for raw query strings).
**Agents/MCPs**: every Static Analyst uses `mcp__pb-codegraph__impact` to chase indirect callers (codegraph-reviewer pattern). Adversarial Tester uses `mcp__pb-codegraph__find_symbol` to locate sinks. Defensive Auditor follows the `standards-enforcer` pass-then-verify rule walk.

Spawn prompt for each of the three agents (substitute `{ANGLE}` with `Static Analyst` / `Adversarial Tester` / `Defensive Auditor`):
```
You are the {ANGLE} on the INJECTION trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for injection vulnerabilities.

OWASP: A03:2021 – Injection.
SCOPE: SQL, NoSQL, OS command, template, LDAP, header, log injection.

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:workflow-security-audit  → pattern-level SQL/command-injection scan with codegraph impact propagation
- /proxiblue-skills:database-query-analysis  → confirm what queries actually run against the DB
- /proxiblue-skills:code-quality-audit       → phpstan signals for raw query construction

ANGLE-SPECIFIC FOCUS:
- Static Analyst: trace every external input to its sink. Use mcp__pb-codegraph__impact on each suspicious symbol to surface indirect callers grep would miss (codegraph-reviewer pattern). Flag concatenated queries, unescaped exec(), unsafe shell calls, raw template interpolation.
- Adversarial Tester: for each user-controllable input, write the exploit payload you'd try (' OR 1=1, $where, $(id), {{7*7}}, etc.) and the file:line where it would land. Use mcp__pb-codegraph__find_symbol to locate sinks.
- Defensive Auditor: walk EVERY identified sink and explicitly confirm parameterised queries / prepared statements / ORM safe-binding / escapeshellarg / template auto-escaping are applied — not just imported. Use the standards-enforcer pass-then-verify discipline.

PROCESS:
1. Enumerate all input sources (HTTP params, headers, body, file uploads, env, queue messages).
2. Trace each to its eventual sink (codegraph impact for indirect paths).
3. Vote PASS / FAIL / NEEDS-REVIEW with evidence.

OUTPUT:
{
  "trio": "injection",
  "angle": "{ANGLE}",
  "vote": "PASS" | "FAIL" | "NEEDS-REVIEW",
  "findings": [{"file": "...", "line": 0, "severity": "critical|high|medium|low", "owasp": "A03:2021", "summary": "..."}],
  "evidence_for_vote": "..."
}

ROUND 2: When shown the other two agents' votes, either reinforce yours with extra evidence or change it explicitly. Do NOT modify code. Investigation only.
```

---

### Trio 2 — XSS & Content Security Policy (CSP)
**OWASP**: A03 (XSS) + A05 (CSP headers)
**Models**: opus, opus, sonnet
**Scope**: Reflected XSS, stored XSS, DOM XSS, CSP header presence + strictness, `unsafe-inline` / `unsafe-eval`, nonce/hash usage, `X-Content-Type-Options`, `Referrer-Policy`.
**Skills to invoke**: `workflow-security-audit` (XSS in .phtml — escapeHtml/escapeUrl scan), `magento-diagnostic` (read served headers + CSP whitelist config), `code-quality-audit`.
**Agents/MCPs**: Static Analyst uses `mcp__pb-codegraph__impact` to trace tainted-source → DOM/HTML sinks across layout XML + block + template chains.

Spawn prompt (substitute `{ANGLE}`):
```
You are the {ANGLE} on the XSS-AND-CSP trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for XSS vulnerabilities and Content Security Policy weaknesses.

OWASP: A03:2021 (XSS) + A05:2021 (security misconfiguration / missing headers).

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:workflow-security-audit  → unescaped .phtml output + escapeHtml/escapeUrl absence
- /proxiblue-skills:magento-diagnostic       → read served headers + Magento CSP whitelist config (Magento_Csp etc.)

ANGLE-SPECIFIC FOCUS:
- Static Analyst: hunt every place user input reaches HTML/JS/attribute/URL/CSS contexts. Check escaping per-context (HTML body vs attribute vs JS string vs URL — they differ). Use mcp__pb-codegraph__impact on each block/template to surface where data enters the rendering chain.
- Adversarial Tester: for each output sink, write the XSS payload (<script>, <img onerror>, javascript: URI, SVG, mxss). State what context bypass it relies on.
- Defensive Auditor: read the actual CSP header value served (curl -I against a representative URL or read Magento_Csp config). Flag unsafe-inline, unsafe-eval, wildcard sources, missing nonces. Check X-Content-Type-Options: nosniff, Referrer-Policy, X-Frame-Options or frame-ancestors. Walk every header per standards-enforcer pass-then-verify rule.

PROCESS:
1. Identify every output sink that includes untrusted data.
2. Inspect served security headers (look at middleware/.htaccess/nginx config/framework defaults).
3. Vote PASS / FAIL / NEEDS-REVIEW.

OUTPUT: same JSON shape as Trio 1, "trio": "xss-csp".

ROUND 2: as Trio 1. Investigation only.
```

---

### Trio 3 — Access Control & Authorization (IDOR, privilege escalation)
**OWASP**: A01:2021 – Broken Access Control
**Models**: opus, opus, sonnet
**Scope**: Missing authorization, IDOR (insecure direct object reference), horizontal/vertical privilege escalation, path traversal, CORS misconfig, missing function-level access control.
**Skills to invoke**: `workflow-security-audit` (admin controllers missing `_isAllowed`; IDOR through route params reaching `$resource->load`), `database-query-analysis` (verify ACL tables / role assignments), `magento-diagnostic` (read admin URL secret-key + 2FA config).
**Agents/MCPs**: Static Analyst uses `mcp__pb-codegraph__impact` on every controller `execute()` method to chase what the request can touch.

Spawn prompt:
```
You are the {ANGLE} on the ACCESS-CONTROL trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for broken access control.

OWASP: A01:2021 – Broken Access Control.

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:workflow-security-audit  → admin controllers missing _isAllowed; IDOR via route params reaching $resource->load
- /proxiblue-skills:database-query-analysis  → verify ACL / role assignments + secret-key config
- /proxiblue-skills:magento-diagnostic       → admin URL secret-key + 2FA config

ANGLE-SPECIFIC FOCUS:
- Static Analyst: for every controller/route/handler, identify the authn + authz gates. Use mcp__pb-codegraph__impact on each controller execute() to map what resources the request can reach. Flag any handler that reads/writes a resource by ID without verifying ownership against the session user.
- Adversarial Tester: enumerate IDOR scenarios — "user A sends user B's resource ID, does it leak?". Write the attack request. Check for vertical escalation (user role hitting admin endpoint).
- Defensive Auditor: review middleware ordering, ACL/RBAC config (acl.xml + di.xml + adminhtml routes.xml), CORS allowlist, path-traversal guards (path.resolve / realpath / Magento File component). Confirm gates fire BEFORE the action, not after. Walk every controller per standards-enforcer pass-then-verify rule.

PROCESS:
1. Map all endpoints + their auth requirements.
2. For each, identify what authorization check protects which resource.
3. Vote.

OUTPUT: same JSON shape, "trio": "access-control".

ROUND 2: as before. Investigation only.
```

---

### Trio 4 — Cryptography & Secrets
**OWASP**: A02:2021 – Cryptographic Failures
**Models**: opus, opus, sonnet
**Scope**: Hardcoded secrets, weak algorithms (MD5/SHA1 for passwords, ECB mode, static IVs), insecure RNG, missing TLS, exposed `.env`, secrets in logs, key rotation, JWT signing.
**Skills to invoke**: `workflow-security-audit` (hardcoded credentials, weak crypto), `security-scan` (HTTPS enforcement, cookie security, admin session config), `server-scan` (exposed `.env`, `.git/` accessible on web root, secrets in `var/log/`).

Spawn prompt:
```
You are the {ANGLE} on the CRYPTOGRAPHY trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for cryptographic failures and secret exposure.

OWASP: A02:2021 – Cryptographic Failures.

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:workflow-security-audit  → hardcoded secrets + weak crypto patterns
- /proxiblue-skills:security-scan            → HTTPS enforcement, cookie security, admin session
- /proxiblue-skills:server-scan              → only if SSH target given; checks .env / .git / log secrets

ANGLE-SPECIFIC FOCUS:
- Static Analyst: grep for hardcoded secrets (API keys, tokens, passwords, private keys, AWS keys, GitHub tokens), weak primitives (md5, sha1 for passwords, DES, ECB, mt_rand/Math.random for security), and missing TLS enforcement (http:// in code, missing Secure cookie flag).
- Adversarial Tester: identify what an attacker who reads the repo / a log line / a memory dump could extract. Estimate impact: account takeover? Forged tokens? Decrypted backups?
- Defensive Auditor: verify secret management approach (env vars, app/etc/env.php, secret stores, KMS), key rotation strategy, TLS settings, password hashing (bcrypt/argon2/scrypt with proper cost; Magento default is fine but verify cost factor), JWT signing algorithm (no "none", no symmetric where asymmetric expected). Walk every secret per standards-enforcer pass-then-verify rule.

PROCESS:
1. Scan for hardcoded secrets and weak crypto primitives.
2. Check secret-loading mechanisms (env, vault, etc.).
3. Vote.

OUTPUT: same JSON shape, "trio": "cryptography".

ROUND 2: as before. Investigation only.
```

---

### Trio 5 — Vulnerable & Outdated Components (CVE Inspection)
**OWASP**: A06:2021 – Vulnerable and Outdated Components
**Models**: opus, opus, sonnet
**Scope**: Dependency CVE lookup using **online resources** (GitHub Advisory DB, NVD, OSV.dev, language-specific advisories — composer audit, npm audit, pip-audit). This is the trio the user named: *"CVE inspection from online resources"*.
**Skills to invoke**: `security-scan` (Magento core CVE + security patches + outdated third-party modules), `server-scan` (server packages / PHP version EOL).
**MCPs / tools**: `WebSearch` + `WebFetch` for online CVE DB queries (NVD, OSV, GitHub Advisory DB, Snyk). `Bash` for `composer audit` / `npm audit` / `pip-audit` / `bundle audit` / `govulncheck`.

Spawn prompt:
```
You are the {ANGLE} on the VULNERABLE-COMPONENTS trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for known-vulnerable dependencies (CVE inspection).

OWASP: A06:2021 – Vulnerable and Outdated Components.

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:security-scan  → Magento core CVE + outdated third-party modules + applied patches
- /proxiblue-skills:server-scan    → only if SSH target given; OS package + PHP version EOL

ANGLE-SPECIFIC FOCUS:
- Static Analyst: enumerate every dependency manifest in scope — composer.json + composer.lock, package.json + package-lock.json / yarn.lock, requirements.txt / Pipfile.lock, go.mod / go.sum, Gemfile.lock, etc. List each package + pinned version.
- Adversarial Tester: for the riskiest packages (high blast radius, internet-facing, parsers, deserialization), query online CVE sources — GitHub Advisory DB (https://github.com/advisories), NVD (https://nvd.nist.gov), OSV.dev (https://osv.dev), Snyk DB. Match installed versions against published CVE ranges. Use WebSearch / WebFetch.
- Defensive Auditor: run the language-native audit tools available — `composer audit`, `npm audit --json`, `pip-audit`, `bundle audit`, `govulncheck`. Cross-check their output against what the Adversarial Tester found manually. Flag mismatches.

PROCESS:
1. List ALL dependencies + locked versions.
2. Query online CVE databases for each material dependency.
3. Run native audit tools as a second source.
4. Vote.

CVE THRESHOLD:
- Any unpatched CRITICAL CVE on a production-facing dependency → FAIL.
- HIGH CVE with available patch → FAIL.
- HIGH CVE with no patch yet → NEEDS-REVIEW (note mitigation).
- MEDIUM/LOW → note but do not fail unless exploit conditions match the codebase usage.

OUTPUT: same JSON shape, "trio": "cve-components", plus a "dependencies": [{"name": "...", "version": "...", "cves": ["CVE-..."], "severity": "..."}] array.

ROUND 2: as before. Investigation only.
```

---

### Trio 6 — Authentication & Session Management
**OWASP**: A07:2021 – Identification and Authentication Failures
**Models**: opus, opus, sonnet
**Scope**: Login flows, password policies, MFA, session fixation, session timeout, secure/HttpOnly/SameSite cookies, JWT expiry + refresh, credential stuffing protections, rate-limiting on auth endpoints.
**Skills to invoke**: `security-scan` (admin 2FA + session config + cookie security), `magento-diagnostic` (session backend Redis/file/db + admin URL secret-key), `workflow-security-audit` (admin controllers).
**MCPs**: `database` MCP to inspect admin user table for weak/disabled 2FA accounts and stale sessions.

Spawn prompt:
```
You are the {ANGLE} on the AUTHENTICATION trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for authentication and session management failures.

OWASP: A07:2021 – Identification and Authentication Failures.

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:security-scan        → admin 2FA + session + cookie config
- /proxiblue-skills:magento-diagnostic   → session backend + admin secret-key

ANGLE-SPECIFIC FOCUS:
- Static Analyst: read the login, logout, password-reset, session-issue, and token-refresh code paths. Verify session IDs regenerate on auth-state change; passwords are compared in constant time; reset tokens are single-use + time-bound.
- Adversarial Tester: build credential-stuffing, brute-force, session-fixation, and password-reset-poisoning attack chains. State which endpoints have no rate limit and which let you enumerate users via error messages.
- Defensive Auditor: confirm cookies use Secure + HttpOnly + SameSite=Lax/Strict, JWT has short expiry + refresh, MFA is enforced where expected, password hashing uses bcrypt/argon2/scrypt with appropriate cost, rate-limiter is in front of login.

PROCESS:
1. Map all auth-related endpoints.
2. Walk through each as an attacker.
3. Vote.

OUTPUT: same JSON shape, "trio": "authentication".

ROUND 2: as before. Investigation only.
```

---

### Trio 7 — CSRF, SSRF & Request Integrity
**OWASP**: A10:2021 (SSRF) + cross-cutting CSRF + A08 (Software & Data Integrity Failures)
**Models**: opus, opus, sonnet
**Scope**: CSRF token presence + validation, SameSite cookies, SSRF in outbound requests, allowlist for external URLs, deserialization safety, request smuggling, webhook signature verification.
**Skills to invoke**: `workflow-security-audit` (CSRF — `form_key`, `unserialize` on user data, command-injection patterns also catch SSRF curl/file_get_contents usage).
**Agents/MCPs**: Static Analyst uses `mcp__pb-codegraph__impact` on every state-changing controller + every outbound HTTP utility to chase user-controlled-URL paths.

Spawn prompt:
```
You are the {ANGLE} on the CSRF-SSRF-INTEGRITY trio of a 21-agent security quorum team.

TASK: Audit {AUDIT_TARGET} for CSRF, SSRF, and request/data integrity failures.

OWASP: A10:2021 (SSRF) + cross-cutting CSRF + A08:2021 (integrity).

SKILLS TO INVOKE (use Skill tool):
- /proxiblue-skills:workflow-security-audit  → CSRF (form_key absence), unserialize on user input, SSRF via curl/file_get_contents/Magento Curl

ANGLE-SPECIFIC FOCUS:
- Static Analyst: identify every state-changing POST/PUT/DELETE endpoint and verify it requires a CSRF token or relies on SameSite cookies + JSON content-type defense. Find every outbound HTTP call (curl, file_get_contents, fetch, http.Get, requests.get) where the URL is even partially user-controlled.
- Adversarial Tester: write the CSRF attack page payload for each unprotected state-changing endpoint. For SSRF, attempt to redirect to 169.254.169.254 (cloud metadata), localhost services, file://, gopher://. For deserialization, identify gadget chains.
- Defensive Auditor: confirm CSRF middleware is wired correctly, outbound URL allowlists exist + are strict (not regex-bypassable), deserialization uses safe libraries / strict types, webhook signatures are HMAC-verified with constant-time comparison.

PROCESS:
1. Map state-changing endpoints + outbound request points.
2. Check defenses for each.
3. Vote.

OUTPUT: same JSON shape, "trio": "csrf-ssrf-integrity".

ROUND 2: as before. Investigation only.
```

---

## The Moderator (Team Lead — not counted in the 21)

**Model**: opus
**Mode**: default
**Role**: Coordinates the 7 trios, collects per-trio consensus, produces the final report.
**Mindset**: Adopts the **`devils-advocate`** agent stance (`hcf/agents/devils-advocate.md`) — hunt gaps and blind spots across trio boundaries, especially compound vulnerabilities (e.g. a Trio 4 secret-leak that becomes a Trio 6 account-takeover).

Spawn prompt:
```
You are the MODERATOR of a 21-agent security quorum team (7 trios × 3 specialists).
You adopt the devils-advocate stance: hunt blind spots between trios, not redesigns.

TASK: Coordinate a full security audit of: {AUDIT_TARGET}

PROCESS:
1. Spawn all 7 trios in parallel. Within each trio spawn 3 agents (Static Analyst, Adversarial Tester, Defensive Auditor) — see trio sections in team_security.md.
2. Round 1: each agent posts an independent vote + findings JSON.
3. Round 2: within each trio, share the three votes; agents either reinforce or change with evidence.
4. Collect each trio's consensus verdict (PASS / FAIL / NEEDS-REVIEW) per the 2-of-3 rule. Preserve dissents.
5. If any trio cannot reach 2-of-3 (e.g. 3-way split), escalate: ask the trio for one more round with explicit evidence citations.
6. Devils-advocate sweep: look for CROSS-TRIO compound issues — a Trio 4 hardcoded JWT secret amplifies any Trio 3 IDOR; a Trio 5 unpatched CVE in a deserializer compounds Trio 7 integrity findings. Surface these explicitly even if no individual trio failed.
7. Synthesize the FINAL REPORT.

OVERALL VERDICT RULES:
- All 7 trios PASS → overall PASS.
- Any trio FAIL → overall FAIL.
- Any NEEDS-REVIEW + no FAIL → overall NEEDS-REVIEW.

FINAL REPORT STRUCTURE:
- Audit target + scope
- Per-trio table: trio | verdict | dissents
- Per-trio findings list (critical/high first), each with file:line + OWASP ref
- Overall verdict
- Top 5 priority remediations
- Dependencies-with-CVEs table (from Trio 5)
- Dissenting positions across the team

RULES:
- You do NOT audit code yourself — you synthesize what the trios find.
- Minimum 2 rounds of communication within each trio before finalizing.
- Output is a recommendation, not implemented code. No agent in this team writes code.
```

---

## Communication Flow

```
Round 1: All 21 agents investigate independently in parallel (3 per trio × 7 trios).
         Each posts vote + findings JSON via task completion.

Round 2: Within each trio, the three votes are cross-shared.
         Each agent reinforces or revises with new evidence.

Round 3: Moderator collects 7 trio verdicts.
         Escalates any 3-way splits for one more round.

Final:   Moderator produces the consolidated security report.
         Presents to the user with overall verdict + dissent log.
```

## File Ownership
- ALL 22 teammates: **READ-ONLY**. No file modifications by anyone.
- The Adversarial Testers identify exploit *paths* and *payloads* — they do not execute exploits.

## Token / Cost Note
21 opus/sonnet agents in parallel is **expensive**. Use this skill when:
- A release candidate needs a thorough security sign-off, **or**
- A known-incident retrospective requires multi-angle root-cause coverage, **or**
- A compliance audit needs documented per-domain verdicts with dissent.

For everyday spot checks, use the lighter `audit` team (4 agents) instead.

## Usage
To invoke:
1. Run `/agent-teams team_security` with `{AUDIT_TARGET}` = path or scope (e.g. `app/code/Uptactics/SomeModule`, or `the whole project`).
2. The Moderator spawns all 7 trios; each trio spawns its 3 specialist agents.
3. Or pre-create the team and have the Moderator orchestrate.

Required variable:
- `{AUDIT_TARGET}` — the code path, module, branch diff, or scope to audit.

Optional:
- `{STORY_CONTEXT}` — story/ticket context if auditing a specific change (matches the chiefloopadverserial security_evaluator_prompt convention).

## Post-audit hand-offs

- **To fix findings**: feed the report into `/proxiblue-skills:audit-loop` — it spawns parallel performance + security + code-quality auditors, fixes Critical/High findings, and re-audits until clean.
- **For per-finding deep-dive**: each finding has file:line — invoke `/proxiblue-skills:workflow-investigate-bug` for forensic root-cause on that specific path.
- **For GitHub ticket-based audit**: use `/proxiblue-skills:github-analysis` upstream — it reproduces the issue locally first, then this team audits the reproduction context.
