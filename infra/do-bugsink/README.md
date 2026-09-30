# Bugsink on DigitalOcean — dedicated error-tracker droplet (AP-2)

> **STATUS: LIVE.** Restored 2026-09-25 after the 2026-09-19 park (see incident
> below). Droplet `134.199.172.217` (SYD1), `https://bugsink.proxiblue.com.au`
> (caddy auto-TLS, cert valid to 2026-11-22). Projects `pps` (id 1), `pps-prod`
> (id 2), `pps-lucas-dev` (id 3) — data volume survived the park, DSNs and the
> agent API token are unchanged. **Both leaked secrets rotated 2026-09-25** and
> the old superuser password verified rejected.
>
> The droplet was **512 MB** at restore (bugsink ~405 MB, OOM-killing its own
> `snappea` worker until 1 GB swap was added 2026-09-25). **Resized to 2 GB by
> 2026-09-30** (1967 MB, ~1.3 GB free, 48 GB disk) — it now also runs
> **VictoriaLogs** at `https://logs.proxiblue.com.au` (see "Log store" below).
> Swap stays.
>
> Note: cloud-init user-data was NOT applied at create; setup was executed
> over SSH instead — the user-data.yaml here remains the rebuild recipe.
> Pending: `justbetter/magento2-sentry` on pps live (next deploy train).

One always-on sink for runtime errors. Production sites push to it (Sentry SDK,
outbound only), ddev projects push dev errors to it, agents query its REST API.
No agent ever touches a production server.

```
pps live ──push──▶                       ◀──push── ddev projects
                   bugsink.proxiblue.com.au
host agents ─query▶  (caddy TLS + bugsink)  ◀─query── container agents
```

## Create (one-time, ~5 min of clicking)

1. **DO → Create Droplet**
   - Image: Ubuntu 24.04 LTS · Plan: Basic **1 vCPU / 1 GB** ($6/mo) · Region: SYD1
   - SSH key: your usual key
   - **Advanced → Add Initialization scripts (user data): paste `user-data.yaml`** (this dir)
   - Hostname: `bugsink`
1b. **Secrets — `user-data.yaml` deliberately contains none.** It references
   `${BUGSINK_SECRET_KEY}` and `${BUGSINK_SUPERUSER}`, which docker compose
   substitutes from `/opt/bugsink/.env` on the droplet. Create that file over
   SSH once the droplet is up, before the first `docker compose up`:

   ```sh
   ssh root@<droplet-ip> 'install -m 600 /dev/null /opt/bugsink/.env'
   { printf 'BUGSINK_SECRET_KEY=%s\n' "$(cat .bugsink-secret)"
     printf 'BUGSINK_SUPERUSER=lucas@proxiblue.com.au:%s\n' "$(cat .admin-password)"
   } | ssh root@<droplet-ip> 'cat > /opt/bugsink/.env'
   ```

   The `:?` default in each reference means compose fails loudly with the
   variable name if the file is missing, rather than booting with an empty
   secret. Both values stay in `.bugsink-secret` / `.admin-password` here
   (gitignored, mode 600) and in the password manager — never in a tracked
   file. This split exists because both secrets were previously inline in
   `user-data.yaml` and shipped to a PUBLIC repo; see the incident note below.
2. **ClouDNS**: A record `bugsink.proxiblue.com.au` → droplet IP (TTL low first day)
3. Wait ~3 min (docker install + boot). Caddy auto-issues Let's Encrypt as soon
   as DNS resolves — nothing to configure.
4. Login: `https://bugsink.proxiblue.com.au` — `lucas@proxiblue.com.au`,
   password in `.admin-password` (this dir, gitignored). **Change it / store in
   password manager.**

## After boot (agent does this, needs your go)

1. Create bugsink projects `pps` (dev) + `pps-prod` + API token
2. Update `~/.pb-hcf/bugsink.env`: both URLs → `https://bugsink.proxiblue.com.au`,
   new token + DSNs
3. Retire the workstation bugsink container (compose down in
   `pb-hcf/services/bugsink`; volume kept until confirmed)
4. Prod feed: install `justbetter/magento2-sentry` on pps via the normal deploy
   pipeline (pb-hcf `templates/sentry/README.md`), DSN = `pps-prod`'s, errors
   only (`traces_sample_rate: 0`) — rides the next deploy train post go-live

## Notification model — none, by design

**Bugsink sends no mail and is not a notification system.** It is an error store
that AI agents query (operator decision 2026-09-25: "bugsink purpose is pure ai
access", no report emails).

Consequences, so nobody treats these as faults:

- `EMAIL_HOST` is deliberately unset, so bugsink runs
  `bugsink.email_backends.QuietConsoleEmailBackend`
  (`conf_templates/docker.py.template` picks the SMTP backend only when
  `EMAIL_HOST` is non-empty).
- Each project still has `alert_on_new_issue: true`, so bugsink queues an alert
  task per new issue and then discards it, logging
  `Email is not set up, the following was not sent: "..." in "pps-uat" (New issue)`.
  **That line is expected.** The flags are left on so a future webhook needs no
  data change.
- The UI shows a "no email backend" system warning. Ignore it, or dismiss it as
  superuser (the link posts to `silence_email_system_warning`).

Who actually gets told, then:

| path | when |
|---|---|
| `issue-sentinel` agent (pb-hcf, post-batch, order 30) | after every HCF batch — queries issues `first_seen` since its batch marker, PASS or structured PUSHBACK |
| `rules/reference/investigation.md` | any runtime error / bug report — querying bugsink is a mandatory artefact step |
| `hooks/php-debug-guard.sh` block message | the moment someone reaches for `var_dump` on an error that already happened |
| `rules/reference/investigation.md` → Hidden issues | manual sweep after a runtime change outside an HCF batch |

**Open question against pps #366:** that ticket's requirement list says "Alert via
email/Slack when new or recurring errors spike". This design satisfies the intent
(errors no longer go unnoticed) through agent polling rather than push
notification. Whether that closes the requirement or leaves it open is the
operator's call — do not silently mark #366 done on the strength of capture
alone.

## Log store — VictoriaLogs (added 2026-09-30)

Server/app logs (not exceptions — those stay in bugsink) pushed from Hypernode
by Vector (pps plan `.claude/plans/log-shipping/`), queried by agents through
the fleet `logs-uat` / `logs-prod` MCP entries (host service
`../mcp-victorialogs/`). Agents never SSH to live to read logs.

- `victorialogs:v1.52.0`, `mem_limit 600m`, `-retentionPeriod=30d`,
  `-retention.maxDiskSpaceUsageBytes=20GiB`, volume `vlogs_data`. Not published;
  only reachable through caddy.
- **Tenancy is enforced by caddy from the bearer token.** Each token maps to
  exactly one tenant (`AccountID:ProjectID`); caddy overwrites the tenant
  headers, so a client cannot pick another tenant. Write tokens only match
  `/insert/*`, read tokens only `/select/logsql/*`; everything else is 403
  (VMUI, `/select/tenant_ids`, `/metrics` included).

  | tenant | project/env | write token var | read token var |
  |---|---|---|---|
  | 1:2 | pps uat | `LOGS_W_PPS_UAT` | `LOGS_R_PPS_UAT` |
  | 1:3 | pps prod | `LOGS_W_PPS_PROD` | `LOGS_R_PPS_PROD` |
  | 1:1 | (reserved: pps dev, not shipped) | – | – |

- **Tokens** live in `/opt/bugsink/.env` (compose `:?` refs → caddy env →
  `{$VAR}` in the Caddyfile) and on the host in `~/.config/pb-logs/tokens.env`
  (0600). Never in this public repo. Mint for a new tenant:
  `echo "LOGS_W_X=$(openssl rand -hex 32)"` (+ `LOGS_R_X`), append to both
  files, add the two matchers/handles to the Caddyfile block, validate, `up -d`.
  Write tokens go into that project's deploy config (pps:
  `app/etc/env.{uat,live}.php` `log_shipping.ingest_token`); read tokens into
  that project's `.ddev/docker-compose.ai.mounts.yaml` as
  `LOGS_READ_TOKEN_UAT` / `LOGS_READ_TOKEN_PROD`.
- **Apply safely** (a bad Caddyfile takes bugsink down with it): validate
  first — `docker run --rm --env-file .env -v $PWD/Caddyfile.new:/etc/caddy/Caddyfile:ro caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`
  — then swap in and `docker compose up -d`.
- **Gotcha:** `/insert/jsonline` needs `Content-Type: application/stream+json`.
  With curl's default form content-type VictoriaLogs answers **200 and ingests
  nothing** (`vl_bytes_ingested_total` stays 0).
- Verified 2026-09-30: uat token sees only 1:2, prod only 1:3, spoofed
  `AccountID`/`ProjectID` headers ignored both ways, write↛read, read↛write,
  no/wrong token 403 — via curl and via the MCP.

## Ops notes

- SQLite in the `bugsink_data` docker volume — **backups DONE 2026-08-03:**
  operator enabled droplet backups in the DO panel (covers the volume)
- OS security patches: unattended-upgrades enabled by cloud-init
- **Swap** was load-bearing at 512 MB (snappea OOM); kept at 2 GB as headroom
  for bugsink + VictoriaLogs. `user-data.yaml` runcmd creates it on rebuild;
  check with `swapon --show`.
- `quietbookcut.com` vhost + `/run/pdftovec` mount also live on this box
  (pdftovec uvicorn service is managed outside this repo).
- Secrets: `.bugsink-secret` (Django SECRET_KEY) + `.admin-password` live here
  gitignored, mode 600 — copy to password manager
- Retention: bugsink defaults keep event counts bounded per project
  (`retention_max_event_count`) — revisit if volume grows

## Incident 2026-09-19 — secrets were committed to a public repo

`user-data.yaml` carried the Django `SECRET_KEY` and the superuser
`email:password` inline from the original AP-2 commit (`5cee385`,
2026-08-03). `ProxiBlue/claude-skills-central` is PUBLIC, and
`raw.githubusercontent.com` served that file to an unauthenticated request
(HTTP 200). The superuser password was verified still valid against the live
service on 2026-09-19 (login returned 302 + a session cookie).

Both values must be treated as compromised. Rewriting git history does not
un-publish them — forks, clones and third-party caches may retain them.
Rotation is the fix; history rewriting is cleanup.

- [x] Secrets removed from the tracked file (env substitution, above)
- [x] Git history rewritten to redact both values
- [x] **Rotated the Django SECRET_KEY** 2026-09-25 (existing sessions invalidated)
- [x] **Rotated the superuser password** 2026-09-25 — `.admin-password` updated;
      new password logs in (302 + session), leaked one rejected (200, no session).
      Previous values kept at `.admin-password.leaked.bak` / `.bugsink-secret.leaked.bak`
      (gitignored) purely so a future audit can prove which value was burned.
      **Still to do by hand: put the new password in the password manager.**
- [ ] Consider whether this repo should be public at all
