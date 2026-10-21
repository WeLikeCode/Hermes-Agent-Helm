# Build-time patches for the `hermes-agent` submodule

`hermes-agent/` is a third-party git submodule (`NousResearch/hermes-agent`, MIT,
pinned at a tagged release) — we cannot merge fixes upstream into it directly.
Instead, fixes we need before the next upstream release land here as plain
`git diff` patches and are applied to the submodule's working tree at
image-build time (see `.github/workflows/hermes-image.yml`, step "Apply
Hermes-Agent-Helm build patches to the pinned submodule").

The submodule itself stays pinned at its tagged commit and is **never**
modified in git — only its working tree is patched inside the CI runner (and
optionally your local checkout) before the Docker build.

## Patches

### Dropped: `0001-mcp-discovery-resilience.patch` (WP019, 2026-10-21)

Removed when the submodule was bumped from `v2026.7.1` to `v2026.9.24`
(Hermes v0.21.5). Upstream has absorbed the fix. Parking a server after 3
failed initial connects, re-probing it (every 300 s), and registering its tools
on recovery arrived in v2026.7.7; the startup discovery concurrency cap
(`mcp.discovery_concurrency`, default 4) only arrived in v2026.9.21.

Known residual gap: a backend that **hangs** beyond `connect_timeout` (60 s) is
cancelled and is not parked or self-probed. It still recovers on its own: the
gateway's MCP config-reconcile chore (`gateway/run.py`, 60 s tick) re-attempts
any configured-but-not-live server once its per-server connect cooldown lapses
(30 s doubling up to 600 s, `tools/mcp_tool.py`;
`reconcile_mcp_servers_with_config` in `tools/mcp_tool_discovery.py`), so the
worst case is roughly 12 min. A `CancelledError` for an MCP server in the
gateway log does not by itself require a pod restart.

### `0002-add-sshpass.patch`

**What it does** — adds `sshpass` to the image's apt install line so the agent can
supply the Mintkey brokered-SSH JWT as the SSH password non-interactively
(`sshpass -p "$token" ssh -p 2222 <ssh_user>@<bastion> …`). The gateway already
ships `git` + `openssh-client` but **not** `sshpass`, so brokered SSH via the
Mintkey bastion (username = `ssh_connect.ssh_user`, password = the `request_token`
JWT) had no way to inject the password without a controlling tty — every attempt
failed with `Permission denied`. (`SSH_ASKPASS` also works, but `sshpass` matches
the documented recipe / service descriptions.)

Touches `Dockerfile` (one apt package: `sshpass`, inserted after `openssh-client`
on the base apt install line).

Rebased onto, and verified against, `v2026.9.24` only (WP019). It does **not**
apply as-is to other tags (seven other tags checked, including v2026.9.21,
v0.21.6, v0.21.7 and v0.22.x; the Dockerfile apt line drifts between releases),
so re-rebase it on every submodule bump.

Ref: SpotUs — Mintkey brokered-SSH from Hermes.

## Local build / test

To reproduce the patched build locally:

```bash
for p in patches/*.patch; do git -C hermes-agent apply "../$p"; done
```

Revert the working tree afterwards with `git -C hermes-agent checkout -- .`
(the submodule must stay clean at its pinned tag; CI applies the patches only
inside the runner). With any patch present the CI image tag is
`<submodule tag>-spotus1` (e.g. `v2026.9.24-spotus1`).

To verify a patch still applies cleanly against a pristine submodule
checkout (e.g. after bumping the pinned submodule commit):

```bash
for p in patches/*.patch; do git -C hermes-agent apply --check "../$p" && echo "OK $p"; done
```

## Adding a new patch

1. Make the fix directly in the submodule's working tree (`hermes-agent/`).
   Do **not** commit inside the submodule — it stays pinned.
2. Generate the patch: `git -C hermes-agent diff > patches/000N-description.patch`.
3. Verify it applies cleanly from a clean submodule tree (stash your
   changes, `apply --check`, then restore).
4. Document it in this README.
5. Commit only `patches/**` (and the workflow, if you changed it) in the
   parent repo — never the submodule gitlink.
