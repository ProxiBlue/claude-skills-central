# mcp-victorialogs — fleet log-query MCP (host service)

Stateless `ghcr.io/victoriametrics/mcp-victorialogs:v1.9.0` in streamable-HTTP
mode on the host, `:8766` → `/mcp` (next to graphiti-mcp on `:8765`). Points at
the **public** caddy endpoint `https://logs.proxiblue.com.au`, never at
VictoriaLogs directly, because caddy is what enforces tenancy.

It holds **no token**. `MCP_PASSTHROUGH_HEADERS=Authorization` forwards each
client's own bearer token; caddy maps that token to exactly one project+env
tenant. See `../do-bugsink/README.md` → "Log store".

## Consumers

Fleet `mcps/.mcp.json` entries (mounted into every ddev project):

| entry | header | env var (per project) |
|---|---|---|
| `logs-uat` | `Authorization: Bearer ${LOGS_READ_TOKEN_UAT:-unset}` | set in that project's `.ddev/docker-compose.ai.mounts.yaml` `environment:` |
| `logs-prod` | `Authorization: Bearer ${LOGS_READ_TOKEN_PROD:-unset}` | same |

A project without the vars gets 403 on every call (not onboarded) — harmless.

Onboard a project: mint its tenant tokens (do-bugsink README), then in its
`docker-compose.ai.mounts.yaml`:

```yaml
    environment:
      LOGS_READ_TOKEN_UAT: ${LOGS_R_PPS_UAT}
      LOGS_READ_TOKEN_PROD: ${LOGS_R_PPS_PROD}
```
with the host shell exporting `LOGS_R_*` (source `~/.config/pb-logs/tokens.env`,
same pattern as `BUDDY_TOKEN` from `~/.config/secrets.env`), then `ddev restart`.

## Run / update

```sh
cd ~/claude-skills-central/infra/mcp-victorialogs && docker compose up -d
curl -s http://127.0.0.1:8766/health/liveness   # 200
```
`query` requires a `start` argument (RFC3339 or relative like `1h`).
