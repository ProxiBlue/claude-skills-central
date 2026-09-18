# Bugsink on DigitalOcean — dedicated error-tracker droplet (AP-2)

> **STATUS: LIVE since 2026-08-03.** Droplet `134.199.172.217` (SYD1, 1GB),
> `https://bugsink.proxiblue.com.au` (caddy auto-TLS). Projects `pps` (id 1) +
> `pps-prod` (id 2), agent token active, `~/.pb-hcf/bugsink.env` repointed.
> Workstation bugsink retired (volume `bugsink_bugsink_data` retained).
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

## Ops notes

- SQLite in the `bugsink_data` docker volume — **backups DONE 2026-08-03:**
  operator enabled droplet backups in the DO panel (covers the volume)
- OS security patches: unattended-upgrades enabled by cloud-init
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
- [ ] **Rotate the Django SECRET_KEY** (invalidates existing sessions)
- [ ] **Rotate the superuser password**, update `.admin-password` + password manager
- [ ] Consider whether this repo should be public at all
