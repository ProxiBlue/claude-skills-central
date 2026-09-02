#!/bin/bash
# xdebug-fpm-session.sh — bracket a live FPM xdebug debug session, from INSIDE the container.
#
# Why this exists: xdebug/pcov default OFF fleet-wide in both FPM and PHP-CLI
# (see rules/reference/xdebug-pcov-defaults.md — xdebug loaded in FPM crashes
# worker processes with SIGSEGV under real request load, confirmed 2026-09-02).
# CLI debugging (xstep/xtrace/xprofile/xcoverage via xdebug-mcp) self-heals —
# each invocation is a fresh process, no toggle needed. FPM is a persistent
# daemon: loading xdebug for a live page load (e.g. debugging something a
# Playwright test is driving) requires an actual extension load + FPM
# restart, which `ddev xdebug on/off` normally handles — but that's a HOST
# command. The Claude session that wants to set a breakpoint on a page load
# is running INSIDE the ddev container it's debugging, with no `ddev` binary
# and no Docker socket — it cannot call `ddev xdebug on` itself. This script
# is the in-container equivalent: phpenmod/phpdismod scoped to the fpm SAPI
# only (never touches CLI) + a supervisorctl restart, runnable with the
# passwordless sudo every ddev web container already has.
#
# Mounted read-only fleet-wide at /var/www/html/.claude/scripts/ (see
# docker-compose.ai.mounts.yaml on every project) — nothing project-specific
# to install, works the moment a project has the xdebug-pcov-defaults.md
# Dockerfile fix (i.e. mods-available/xdebug.ini still present, only the
# fpm/conf.d symlink was removed).
#
# Usage:
#   xdebug-fpm-session.sh on [--timeout SECONDS]   # default 900s (15 min) auto-off safety
#   xdebug-fpm-session.sh off
#   xdebug-fpm-session.sh status
#
# The auto-off safety exists because leaving FPM xdebug on is exactly the
# state that caused the original SIGSEGV incident if a real Playwright/E2E
# batch runs against it before someone remembers to turn it back off. `off`
# always runs even if you forget; `on` without ever calling `off` self-heals
# within the timeout window.
#
# Xdebug's default here is `xdebug.start_with_request=yes` on port 9003 —
# once ON, every request hitting FPM (not just the one you care about)
# attempts a DBGp connection. Harmless if nothing's listening, but don't
# run unrelated traffic through the site while a debug client has a
# connection latched — finish one breakpoint session before starting another.

set -u

STATE_DIR="/tmp/.xdebug-fpm-session"
PID_FILE="$STATE_DIR/timer.pid"
DEFAULT_TIMEOUT=900

log() { echo "[xdebug-fpm-session] $*"; }
err() { echo "[xdebug-fpm-session] $*" >&2; }

require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        err "passwordless sudo not available — cannot phpenmod/phpdismod or restart php-fpm."
        exit 1
    fi
}

cancel_timer() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
}

do_on() {
    local timeout="$DEFAULT_TIMEOUT"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) timeout="${2:-$DEFAULT_TIMEOUT}"; shift 2 ;;
            *) err "unknown arg: $1"; exit 1 ;;
        esac
    done

    require_sudo
    mkdir -p "$STATE_DIR"
    cancel_timer

    sudo phpenmod -v ALL -s fpm xdebug
    sudo supervisorctl restart php-fpm >/dev/null

    log "xdebug ON for FPM (all installed PHP versions enabled; only the active one matters)."
    log "Auto-off safety armed: will self-heal to OFF in ${timeout}s unless you call '$0 off' first."

    nohup bash -c "sleep '$timeout'; sudo phpdismod -v ALL -s fpm xdebug; sudo supervisorctl restart php-fpm >/dev/null 2>&1; rm -f '$PID_FILE'; echo '[xdebug-fpm-session] auto-off fired after ${timeout}s' " \
        >"$STATE_DIR/autooff.log" 2>&1 &
    disown
    echo $! > "$PID_FILE"

    log "Debug client: port 9003, mode=debug,develop, start_with_request=yes."
    log "Drive the page load via Playwright now. Call '$0 off' as soon as you're done — don't leave this on into a real E2E batch."
}

do_off() {
    require_sudo
    cancel_timer
    sudo phpdismod -v ALL -s fpm xdebug
    sudo supervisorctl restart php-fpm >/dev/null
    log "xdebug OFF for FPM."
}

do_status() {
    local loaded="no"
    if find /etc/php/*/fpm/conf.d -iname "*xdebug*.ini" 2>/dev/null | grep -q .; then
        loaded="yes"
    fi
    log "xdebug loaded in FPM conf.d: $loaded"
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            log "auto-off timer active (pid $pid)"
        else
            log "auto-off timer file present but process gone — stale, run 'off' to clean up"
        fi
    else
        log "no auto-off timer armed"
    fi
}

case "${1:-}" in
    on) shift; do_on "$@" ;;
    off) do_off ;;
    status) do_status ;;
    *)
        err "usage: $0 on [--timeout SECONDS] | off | status"
        exit 1
        ;;
esac
