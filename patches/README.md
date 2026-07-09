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

### `0001-mcp-discovery-resilience.patch`

**What it does** — fixes a boot-time MCP tool discovery bug where a server
that fails its first few connection attempts (e.g. during a concurrent
startup burst) was permanently abandoned: its tools were never registered
for the gateway's lifetime, even if the backend came up moments later.

- `MCPServerTask.run()`'s initial-connect path now "parks and retries"
  instead of giving up: once the in-boot fast-retry budget
  (`_MAX_INITIAL_CONNECT_RETRIES`) is exhausted, it releases the boot
  barrier (so gateway startup isn't blocked) but keeps retrying with capped
  exponential backoff in the background.
- When a deferred initial connect finally succeeds, `_complete_deferred_registration()`
  performs the registration that would normally have happened at boot
  (storing the server and registering its tools into the global registry).
- Initial MCP server discovery concurrency is now bounded
  (`_MAX_CONCURRENT_INITIAL_CONNECTS`, default 4, override via
  `HERMES_MCP_MAX_CONCURRENT_CONNECTS`) — an unbounded startup burst was
  itself a trigger for the transient `tools/list` failures that used to
  cause permanent give-up.

Ref: SpotUs WP014.

Touches `tools/mcp_tool.py` and `tests/tools/test_mcp_stability.py`.

## Local build / test

To reproduce the patched build locally:

```bash
git -C hermes-agent apply patches/0001-mcp-discovery-resilience.patch
```

To verify a patch still applies cleanly against a pristine submodule
checkout (e.g. after bumping the pinned submodule commit):

```bash
git -C hermes-agent apply --check patches/0001-mcp-discovery-resilience.patch
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
