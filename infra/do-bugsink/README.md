# Bugsink on DigitalOcean — dedicated error-tracker droplet (AP-2)

> **STATUS: LIVE.** Restored 2026-09-25 after the 2026-09-19 park (see incident
> below). Droplet `134.199.172.217` (SYD1), `https://bugsink.proxiblue.com.au`
> (caddy auto-TLS, cert valid to 2026-11-22). Projects `pps` (id 1), `pps-prod`
> (id 2), `pps-lucas-dev` (id 3) — data volume survived the park, DSNs and the
> agent API token are unchanged. **Both leaked secrets rotated 2026-09-25** and
> the old superuser password verified rejected.
>
> The droplet is **512 MB, not the 1 GB this doc originally specified** — bugsink
> alone sits at ~405 MB and was OOM-killing its own `snappea` ingest worker on
> every restart. 1 GB swap added 2026-09-25 (`/swapfile`, in `/etc/fstab`,
> `vm.swappiness=20`). Resize to the 1 GB plan if ingest volume grows.
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

## Ops notes

- SQLite in the `bugsink_data` docker volume — **backups DONE 2026-08-03:**
  operator enabled droplet backups in the DO panel (covers the volume)
- OS security patches: unattended-upgrades enabled by cloud-init
- **Swap is load-bearing on this 512 MB droplet** — without it the snappea
  ingest worker is OOM-killed and events silently stop being digested.
  Check with `swapon --show` after any rebuild; a rebuild from
  `user-data.yaml` does NOT create it.
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
