# xdebug / pcov defaults — off by default, load on demand

## The rule

Every DDEV PHP project: xdebug and pcov OFF by default in **both** PHP-FPM and PHP-CLI.
Never a blanket "always on" for either SAPI. Load on demand only.

## Why

**FPM**: xdebug loaded in FPM crashes worker processes with SIGSEGV under real request load
(confirmed 2026-09-02 on pvcpipesupplies via `docker logs` — signal 11, core dumped. Bisected:
xdebug ALONE is sufficient, not an xdebug+pcov pairing). No legitimate reason to have it loaded
for a webserver SAPI serving real Playwright/E2E/admin traffic.

**CLI**: no crash risk, but a real speed cost — every `phpunit`/CLI invocation pays the
instrumentation tax if xdebug or pcov is loaded, even when neither is requested. Not needed:
xdebug-mcp (`koriym/xdebug-mcp`, this fleet's debug/plan-layer tooling — xstep/xtrace/xprofile/
xcoverage) already self-heats. `XdebugFinder::getXdebugFlag()` in the plugin checks
`extension_loaded('xdebug')` and appends `-dzend_extension=<path>` to that one child-process
invocation when it's not loaded. CLI is a fresh process per invocation, so there is zero
restart/reload cost to loading on demand — this is not a gap that needs fleet-side plumbing,
it already works. `xcoverage` additionally never uses pcov at all — it passes
`-dxdebug.mode=coverage -dpcov.enabled=0` and drives coverage through xdebug's own coverage
mode via the same auto-inject flag.

## Two known DDEV gotchas that silently re-enable both

1. `webimage_extra_packages: [..., phpX.Y-pcov]` in `.ddev/config.yaml` installs pcov via apt,
   whose postinst enables it for **all** SAPIs unconditionally (cli + fpm together) — no
   per-SAPI split available through this mechanism.
2. A `post-start` hook of `exec-host: ddev xdebug on` (or `xdebug_enabled: true`) runs
   `phpenmod xdebug` unscoped on every `ddev start` — also affects all SAPIs together, and
   silently undoes any per-SAPI conf.d fix on the next start.

Neither DDEV mechanism supports "load pcov but not for FPM" or "off by default, on when asked"
— hence the explicit build-time fix below.

## The fix

1. Remove any `exec-host: ddev xdebug on` / `xdebug_enabled: true` post-start hook from
   `.ddev/config.yaml` — don't auto-enable on every start. **This hook is the actual regression
   vector** — even with conf.d symlinks stripped, this hook unconditionally re-enables xdebug
   on the very next `ddev start`/`restart`, silently undoing the fix. It must go, not just be
   supplemented.
2. Add a `post-start` hook (not a build-time Dockerfile fragment — see postmortem below) that
   self-heals every start:
   ```yaml
   - exec: sudo bash -c 'rm -f /etc/php/*/fpm/conf.d/*-xdebug.ini /etc/php/*/fpm/conf.d/*pcov*.ini /etc/php/*/cli/conf.d/*-xdebug.ini /etc/php/*/cli/conf.d/*pcov*.ini; supervisorctl restart php-fpm* >/dev/null 2>&1 || true'
   ```
   Deliberately matches `*-xdebug.ini` (e.g. `20-xdebug.ini`), not `*xdebug*.ini` — leaves
   `xdebug_trigger.ini`/`30_xdebug_trigger.ini` stubs alone, those are a separate lightweight
   trigger mechanism, not the full instrumented loader. Runs on every `ddev start`, so it wins
   even if something else re-enables the ini between restarts.
3. `ddev xdebug on` remains available as a manual, rare-case toggle for live-request
   step-debugging over FPM (requires a supervisor restart, unlike CLI — CLI never needs it) —
   but that's a **host** command. A Claude session running inside the container being
   debugged has no `ddev` binary or Docker socket and cannot call it. For that case, use
   `.claude/scripts/xdebug-fpm-session.sh on|off|status` instead (mounted fleet-wide,
   read-only, at `~/claude-skills-central/scripts/` — same mechanism, in-container: scoped
   `phpenmod`/`phpdismod -s fpm` + `supervisorctl restart php-fpm`, with a 900s auto-off
   safety so a forgotten session self-heals before it can bleed into a real E2E batch). See
   `php-debugging.md`'s "Availability" section for the full workflow. Any next-start `ddev
   start`/`restart` re-applies step 2 and resets to off — this is intended, matches the
   "off by default, on demand" rule.

## Postmortem: the 2026-09-02 fix never actually landed (found + corrected 2026-09-05)

The original fix (chatroom thread `c75c0e43`, 2026-09-02) was applied **live, inside the
running containers only** (editing conf.d and claiming a `Dockerfile.fpm-debug-ext-disable`
fragment was added) — that Dockerfile fragment was never written to disk on pvcpipesupplies,
ai_assistant, or lcdscreen_mageos, and the `ddev xdebug on` post-start hook was never actually
removed from pvcpipesupplies or ai_assistant's `.ddev/config.yaml`. Verified 2026-09-05: both
projects still had `xdebug.ini` + `pcov.ini` live in FPM conf.d and the forced-on hook still
present — the "fix" silently evaporated on the first `ddev start` after the chat closed. This
is exactly the failure class this rule exists to prevent, happening to the rule's own fix.
Lesson: a claimed fix inside a running container is not a fix — verify the persisted
`.ddev/config.yaml` / build files on disk, not just current runtime state.

## Applied fleet-wide (corrected 2026-09-05)

Real, persisted fix (hook removed + self-healing post-start hook added per above) now live in
`.ddev/config.yaml` for: pvcpipesupplies, mageos, ai_assistant (webhooks), lcdscreen_mageos
(all four had `phpX.Y-pcov`), plus hook-only removal (no pcov exposure) on hyva, ntotankM1,
ihop. Config edits only — restart deferred to the project owner per-project, so runtime state
won't reflect this until each project's next `ddev restart`. Any new DDEV PHP project should
get this hook as part of onboarding, not after a crash finds it — `core-triggers.md` already
triggers this rule on `webimage_extra_packages` with pcov or a `ddev xdebug on` hook.
