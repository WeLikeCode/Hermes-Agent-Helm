# Operations — Hermes Agent on the SpotUs DEV cluster

How the deployment is wired, how to access it, the non-obvious things that will
bite you, and how to test it. Companion: `scripts/smoke-test.sh`.

## Access

- **URL:** https://hermes-dev.spotusspaceapi.org (Cloudflare Tunnel — no open ports on the nodes).
- **Login:** a **login page** (form), *not* a browser Basic-Auth popup. User `admin`, password in
  Mintkey secret `SPOTUS_DEV_HERMES_DASHBOARD`.
- **Tailnet / local:** `kubectl -n hermes port-forward svc/hermes-hermes-agent 9119:9119` → http://localhost:9119.

## Architecture

```
 ns hermes ── StatefulSet hermes-hermes-agent (replicas: 1, single-writer)
   pod (3 containers, one image, shared PVC /opt/data on Longhorn):
     ├─ gateway          : agent core + cron scheduler + LLM calls  (args: gateway run)
     ├─ dashboard        : FastAPI+SPA admin/chat UI, bound 0.0.0.0, GATED auth  (args: dashboard --no-open)
     └─ dashboard-proxy  : nginx, plain WS-capable reverse proxy (NOT an auth gate)
   PVC data (Longhorn, 2 replicas) ── survives node loss
   PVC backup (Longhorn) ── nightly tar of /opt/data (CronJob)
 Service (ClusterIP) :9119 → nginx → dashboard ; :8642 API (internal)
 Cloudflare Tunnel: hermes-dev.spotusspaceapi.org → svc:9119
```

- **LLM:** self-hosted **Ollama** over Tailscale (`http://100.126.196.47:11434/v1`, model `gemma4:12b-mlx`),
  cost €0. Pods reach the tailnet directly (nodes route pod egress) — no sidecar.
- **Durability:** `/opt/data` (SQLite sessions, memory, skills, cron, config) is on Longhorn, so a node
  loss keeps a healthy replica. Hermes cannot use an external DB — see the SpotUs WP011 spec.

## Auth model (and why it is what it is)

This Hermes version has **no unauthenticated public-bind option** (`--insecure` is a deprecated no-op).
A non-loopback bind *requires* the dashboard's own auth provider. So:

- The dashboard binds **`0.0.0.0`** with **`dashboard.basic_auth`** configured (login page + session cookie
  + short-lived WebSocket "tickets"). This is "gated" mode.
- **nginx does NOT do auth.** An external Basic-Auth proxy cannot work here for two reasons: (1) browsers
  can't attach Basic-Auth to a WebSocket handshake; (2) the dashboard's WS Host/Origin guard only accepts a
  *loopback* Host/Origin when bound to `127.0.0.1`, so a public hostname fails `4403` — binding `0.0.0.0` is
  the only way it accepts `hermes-dev…`, and that bind forces gated auth.

Credentials live in `config.yaml` on the PVC (`dashboard.basic_auth.username` / `password_hash` / `secret`),
mirrored in Mintkey. To rotate:

```bash
kubectl -n hermes exec hermes-hermes-agent-0 -c gateway -- sh -c '
  cd /opt/hermes
  H=$(python3 -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password(\"NEWPASS\"))")
  hermes config set dashboard.basic_auth.username admin
  hermes config set dashboard.basic_auth.password_hash "$H"'
# then update the Mintkey secret SPOTUS_DEV_HERMES_DASHBOARD and restart the pod
```

## LLM configuration

The provider/model live in `config.yaml` (NOT the chart env — the chart only sets `OPENAI_BASE_URL`):

```bash
kubectl -n hermes exec hermes-hermes-agent-0 -c gateway -- sh -c '
  hermes config set model.provider ollama
  hermes config set model.base_url http://100.126.196.47:11434/v1
  hermes config set model.default  gemma4:12b-mlx'   # or gemma4:12b-it-qat / qwen3.5:4b-mlx-bf16
```

Requirement: the model must support **≥64k context** (set Ollama `num_ctx`). Provider id is **`ollama`**
(local, OpenAI-compatible) — *not* `openai`.

## Known gotchas (hard-won)

| Symptom | Cause | Fix |
|---|---|---|
| `exec "gateway": not found`, crashloop | chart used `command:` → overrode the image's s6-overlay `/init` entrypoint | use `args:` (chart does) |
| Dashboard `400 Invalid Host header` | dashboard validates Host against its bind | bind `0.0.0.0` + set `HERMES_DASHBOARD_PUBLIC_URL` |
| Chat WS fails `4403` / `NS_ERROR_WEBSOCKET` | WS Host/Origin guard rejects public origin on loopback bind | bind `0.0.0.0` + gated `dashboard.basic_auth` (mints WS tickets) |
| `Unknown provider 'openai'` | wrong provider id for Ollama | provider is `ollama` |
| Browser "Server Not Found" but `dig` works | stale **negative-DNS cache** (looked up before the record existed) | flush DNS / restart browser / try mobile data |
| Config lost after a fresh (new-PVC) deploy | ~~config on PVC only~~ **FIXED**: a `seed-config` initContainer seeds `config.yaml` from values (LLM) + the `hermes-dashboard-auth` Secret (password→hashed, session-secret) every start | ensure the Secret has `password` + `session-secret` keys |

## Testing — `scripts/smoke-test.sh`

Runs the whole live path (pod health, Longhorn PVC, Ollama reachability + a real chat round-trip, public
reachability, and the login → WS-ticket → WebSocket-upgrade chain). Run it after any change to the chart,
the image, or the LLM/auth config.

```bash
export KUBECONFIG=~/.kube/spotus-dev.yaml
export HERMES_DASHBOARD_PW="$(: fetch from Mintkey secret SPOTUS_DEV_HERMES_DASHBOARD)"
./scripts/smoke-test.sh
```

Without `HERMES_DASHBOARD_PW` the login/WS checks are skipped and the rest still run. Exit code is non-zero
on any failure, so it's CI-friendly. Overridable via `HERMES_NS`, `HERMES_POD`, `HERMES_PUBLIC_URL`,
`HERMES_DASH_PORT`, `HERMES_DASHBOARD_USER`.

## Still open

- **Cloudflare Access** (email SSO in front): pending the one-time Zero Trust enablement on the CF account.
  Hermes' own login is the gate until then.
- **MCP-to-Mintkey + SSH terminal backend:** disabled in v1 (need a dedicated Hermes Mintkey agent bearer +
  the SSH host allowlist).
