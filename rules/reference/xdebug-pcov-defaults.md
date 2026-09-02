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
   `.ddev/config.yaml` — don't auto-enable on every start.
2. Add `.ddev/web-build/Dockerfile.fpm-debug-ext-disable` (exact filename doesn't matter, ddev
   concatenates `.ddev/web-build/Dockerfile.*` in build):
   ```dockerfile
   RUN rm -f /etc/php/*/fpm/conf.d/*xdebug*.ini /etc/php/*/fpm/conf.d/*pcov*.ini \
              /etc/php/*/cli/conf.d/*xdebug*.ini /etc/php/*/cli/conf.d/*pcov*.ini || true
   ```
   This only removes the SAPI-scoped conf.d symlinks — the `.so` files and
   `mods-available/*.ini` stay intact, so `XdebugFinder::detectXdebugPath()` still finds the
   extension and injects it on demand. Runs after the package-install layer, so it always wins
   over the apt postinst.
3. `ddev xdebug on` remains available as a manual, rare-case toggle for live-request
   step-debugging over FPM (requires a supervisor restart, unlike CLI — CLI never needs it) —
   but that's a **host** command. A Claude session running inside the container being
   debugged has no `ddev` binary or Docker socket and cannot call it. For that case, use
   `.claude/scripts/xdebug-fpm-session.sh on|off|status` instead (mounted fleet-wide,
   read-only, at `~/claude-skills-central/scripts/` — same mechanism, in-container: scoped
   `phpenmod`/`phpdismod -s fpm` + `supervisorctl restart php-fpm`, with a 900s auto-off
   safety so a forgotten session self-heals before it can bleed into a real E2E batch). See
   `php-debugging.md`'s "Availability" section for the full workflow.

## Applied fleet-wide (2026-09-02)

pvcpipesupplies (originated the fix, FPM crash was the trigger), lcdscreen_mageos, ai_assistant
(webhooks) — all three had the identical `phpX.Y-pcov` + `ddev xdebug on` hook exposure. Any
new DDEV PHP project should get this Dockerfile + hook removal as part of onboarding, not
after a crash finds it.
