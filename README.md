# Hermes-Agent-Helm

Deployment artifact for **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** (Nous Research, MIT)
on Kubernetes: a Helm chart, an image-build pipeline, and the upstream source pinned as a git submodule.

This repo is **not a fork** — the upstream lives untouched at `hermes-agent/` (a submodule pinned to a
release tag). We build its image and ship a chart around it.

## Layout
```
Hermes-Agent-Helm/
├── hermes-agent/                 git submodule → NousResearch/hermes-agent @ v2026.7.1 (MIT)
├── charts/hermes-agent/          Helm chart (derived from the upstream docker-compose.yml)
├── .github/workflows/
│   └── hermes-image.yml          builds hermes-agent/ → ghcr.io/welikecode/hermes-agent
└── README.md
```

## Image
`.github/workflows/hermes-image.yml` builds the image from the submodule's `Dockerfile` and pushes to
**`ghcr.io/welikecode/hermes-agent`** (tag = the submodule's release tag). It runs on submodule bumps or
manually (`workflow_dispatch`). The build uses the repo's built-in `GITHUB_TOKEN` (WeLikeCode-org package,
same org as this repo) — no external PAT. Pin the chart to the printed `@sha256:…` digest for production.

To adopt a newer Hermes release: bump the submodule (`cd hermes-agent && git checkout <newer-tag>`),
commit, push — CI rebuilds.

## Chart — `charts/hermes-agent/`
Derived from the upstream `docker-compose.yml` (services `gateway` + `dashboard`, one image, shared
`/opt/data`). Key properties:
- **Single-replica StatefulSet** — Hermes state is single-writer SQLite/JSON in `/opt/data`; scaling out
  would corrupt it (the template refuses `replicaCount != 1`).
- **Durable storage** — PVC on **Longhorn** (`storageClass: longhorn`, replicated), so `/opt/data`
  (memory, skills, sessions, cron) survives a node loss. A backup CronJob tars `/opt/data` to a separate
  Longhorn PVC as defense-in-depth.
- **gateway + dashboard** containers share the PVC; dashboard binds `0.0.0.0:9119` (so its own auth engages);
  API server `:8642` stays internal.
- **Secrets by reference only** — nothing embedded; every credential is an externally-created Secret
  (`envFrom.secretRef`). See `charts/hermes-agent/README.md` for the required Secrets.
- **UID remap** — initContainer chowns `/opt/data` to uid 10000 (the image starts root, remaps internally).

### LLM provider — self-hosted Ollama over Tailscale
Configured for a **self-hosted Ollama** instance reached over **Tailscale** (cost: €0). Hermes uses Ollama's
OpenAI-compatible endpoint — set `llm.openaiBaseUrl` to the Ollama host's tailnet address and `llm.model`
to one of: `gemma3:12b-it-q8_0` (recommended), a Gemma 12B MLX build (Apple-silicon host), or
`qwen3:4b` / `qwen3:2b`. Two requirements:
1. **Context ≥ 64k** — Hermes requires it; set Ollama `num_ctx` and pick a model that supports it
   (Gemma 3 12B = 128k; verify the Qwen variant).
2. **Reaching the Ollama host over Tailscale** — pods aren't on the tailnet by default (only nodes are).
   Options: a Tailscale sidecar in the Hermes pod, the Tailscale k8s operator, or a subnet router. This is
   the one networking piece to wire before go-live.

## Deploying (SpotUs DEV cluster)
Consumed by the SpotUs cluster via ArgoCD (`clusters/dev/apps/hermes.yaml` in the infra repo), pointing at
this chart. Create the required Secrets (from Mintkey) first, set `llm.openaiBaseUrl` + `image.digest`,
then let ArgoCD sync. Exposure (Cloudflare Tunnel + Access for the dashboard) follows the cluster's existing
ingress pattern.
