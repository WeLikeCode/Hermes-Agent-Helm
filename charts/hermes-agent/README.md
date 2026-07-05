# hermes (Helm chart)

Hermes Agent (Nous Research, MIT) — single-writer SQLite/JSON agent state in
`/opt/data`. See `openspec/changes/011-hermes-agent.md` (architecture and
decisions) and `openspec/changes/012-hermes-image-and-chart.md` (this WP's
task list, WP012 task 4) for full context.

**Status: authored + static-validated only.** This chart is not live-deployed
from WP012 — `clusters/dev/apps/hermes.yaml` pins `enabled: false` as a safe
non-serving default until the WP011 LLM provider/budget decision lands.

## Shape

- One `StatefulSet`, `replicas: 1` (enforced at template render time — SQLite
  is single-writer, do not scale out), one Pod, two containers sharing one
  PVC at `/opt/data`:
  - `gateway` — agent core, cron scheduler, messaging adapters, internal API
    (`:8642`, container port name `api`).
  - `dashboard` — web dashboard (`:9119`, container port name `dashboard`).
- The primary PVC (`volumeClaimTemplates: data`) is on the **Longhorn**
  StorageClass (`values.persistence.storageClass`, default `longhorn`) so a
  single node loss keeps a healthy replica — `local-path` is node-pinned and
  would lose Hermes' memory/skills/sessions/cron with the node.
- A **separate** Longhorn PVC + daily `CronJob` (`values.backup.*`) tars
  `/opt/data` for defense-in-depth against logical corruption. Never wired to
  S3 (off-cluster backup is deferred to WP008 until Object Storage exists).
- `ClusterIP` Service (`:9119`, `:8642`) + a headless Service for the
  StatefulSet's `serviceName`. No `hostNetwork` — replaces the upstream
  compose's `network_mode: host`.
- `values.nodeSelector` pins Hermes (and the backup CronJob, which must
  co-locate to mount the same Longhorn RWO volume) to a predictable node.

## Root-start UID remap

The upstream image starts as root and remaps to `HERMES_UID`/`HERMES_GID`
internally on boot. An `initContainer` (`chown-data`, running as root
deliberately) chowns `/opt/data` to `values.hermes.uid`/`gid` (default
`10000`/`10000`) before the app containers start; the pod also sets
`securityContext.fsGroup` to the same GID. The `gateway`/`dashboard`
containers do **not** set `runAsNonRoot`/`runAsUser` — forcing that would
break the image's own root-to-uid handoff before the chown has even run on
first boot.

## Image

`values.image.repository` defaults to the placeholder
`ghcr.io/PLACEHOLDER/hermes-agent`; `values.image.digest` is an empty
placeholder. **WP012 task 3** (image build+push, `ci/hermes-image/**`)
supplies the real GHCR namespace and the digest. Do not point this chart at
a real workload until that lands — the chart tolerates an empty digest only
so it can be authored/validated ahead of task 3.

## Required Secrets (create out-of-band — never commit these)

This chart never embeds credentials; every `values.secrets.*.secretName`
is a **reference** to a Secret that must already exist in the `hermes`
namespace, created the same way as `cloudflared-token` in
`clusters/dev/cloudflared/deployment.yaml` — i.e. sourced from Mintkey and
applied imperatively, never checked into this repo:

| Chart value | Default Secret name | Consumed by | Must define (env vars) |
|---|---|---|---|
| `secrets.llm.secretName` | `hermes-llm-secret` | `gateway`, `dashboard` | The chosen LLM provider's API key env var, e.g. `ANTHROPIC_API_KEY` or `OPENROUTER_API_KEY` (WP011 open question 1 — provider/budget not yet decided). |
| `secrets.dashboardAuth.secretName` | `hermes-dashboard-auth-secret` | `dashboard` | `HERMES_DASHBOARD_BASIC_AUTH_USER`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`, `HERMES_DASHBOARD_BASIC_AUTH_SECRET` (session-signing secret so sessions survive pod restarts — see openspec 011 "Exposure & auth"). |
| `secrets.mcpMintkey.secretName` | `hermes-mcp-mintkey-secret` | `gateway` | `MCP_MINTKEY_AUTHORIZATION` — the full `Bearer mk_agent_...` header value for Hermes' `config.yaml` `mcp_servers[].headers.Authorization`, pointed at the Mintkey MCP HTTP endpoint. |
| `secrets.sshTerminal.secretName` | `hermes-ssh-terminal-secret` | `gateway` | `TERMINAL_SSH_*` (host/user/key/port, per allowed host). Exact host scope (NUC fleet + which `k8s-dev*` nodes) is WP011 open question 5 — not yet confirmed. |

Each is wired in as `envFrom.secretRef` (whole-Secret injection), not
per-key `secretKeyRef`s, precisely because the exact key set for the LLM
and SSH secrets depends on decisions WP011 left open. Any of the four can
be disabled via `secrets.<name>.enabled: false` if that integration isn't
wired up yet (the corresponding env vars are simply absent from the pod).

Example (do not run against a real Secret without knowing what you're
enabling):

```
kubectl -n hermes create secret generic hermes-llm-secret \
  --from-literal=ANTHROPIC_API_KEY=<value from Mintkey, never pasted in chat>
```

## Validating this chart (static only — see WORKFLOW.md, no live deploy)

```
helm lint charts/hermes
helm template charts/hermes | kubeconform -strict -ignore-missing-schemas -summary
helm template charts/hermes | grep -c 'secretKeyRef\|secretRef'   # > 0
helm template charts/hermes | grep -Ei 'api[_-]?key|password:|BEGIN [A-Z ]*PRIVATE KEY'   # must be empty
```

## Out of scope (this WP)

- Live Hermes run against an LLM (WP011 open decisions).
- GHCR namespace + push creds (WP012 task 3).
- Off-cluster S3 backup of `/opt/data` (WP008).
- Cloudflare Tunnel/Access exposure of the dashboard (follows the
  `clusters/dev/cloudflared` pattern once WP011's exposure decision lands).


## Dashboard authentication (nginx Basic Auth)
The dashboard binds `127.0.0.1` inside the pod; an **nginx** sidecar
(`dashboard-proxy`) in front provides HTTP **Basic Auth** and is the only
reachable entrypoint (the Service targets it). Cloudflare Access is the
intended outer layer once Zero Trust is enabled.

Create the htpasswd Secret before deploying:
```
htpasswd -nbB <user> <pass> > htpasswd
kubectl -n hermes create secret generic hermes-dashboard-auth --from-file=htpasswd=./htpasswd
```

## Required Secrets (create in the `hermes` namespace, sourced from Mintkey)
| Secret | Consumed by | Must define |
|---|---|---|
| `hermes-dashboard-auth` | nginx proxy | `htpasswd` (a bcrypt htpasswd file) |
| `hermes-llm-secret` | gateway/dashboard | the OpenAI-compatible key (any non-empty value for Ollama), e.g. `OPENAI_API_KEY` |
| `hermes-mcp-mintkey-secret` | gateway | `MCP_MINTKEY_AUTHORIZATION` (Bearer header for the Mintkey MCP endpoint) |
| `hermes-ssh-terminal-secret` | gateway | `TERMINAL_SSH_*` (host/user/key/port) |
