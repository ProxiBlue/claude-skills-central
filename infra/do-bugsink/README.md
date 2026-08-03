# Bugsink on DigitalOcean — dedicated error-tracker droplet (AP-2)

> **STATUS: LIVE since 2026-08-03.** Droplet `134.199.172.217` (SYD1, 1GB),
> `https://errors.proxiblue.com.au` (caddy auto-TLS). Projects `pps` (id 1) +
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
                   errors.proxiblue.com.au
host agents ─query▶  (caddy TLS + bugsink)  ◀─query── container agents
```

## Create (one-time, ~5 min of clicking)

1. **DO → Create Droplet**
   - Image: Ubuntu 24.04 LTS · Plan: Basic **1 vCPU / 1 GB** ($6/mo) · Region: SYD1
   - SSH key: your usual key
   - **Advanced → Add Initialization scripts (user data): paste `user-data.yaml`** (this dir)
   - Hostname: `bugsink`
2. **ClouDNS**: A record `errors.proxiblue.com.au` → droplet IP (TTL low first day)
3. Wait ~3 min (docker install + boot). Caddy auto-issues Let's Encrypt as soon
   as DNS resolves — nothing to configure.
4. Login: `https://errors.proxiblue.com.au` — `lucas@proxiblue.com.au`,
   password in `.admin-password` (this dir, gitignored). **Change it / store in
   password manager.**

## After boot (agent does this, needs your go)

1. Create bugsink projects `pps` (dev) + `pps-prod` + API token
2. Update `~/.pb-hcf/bugsink.env`: both URLs → `https://errors.proxiblue.com.au`,
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
