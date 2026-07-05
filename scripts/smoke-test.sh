#!/usr/bin/env bash
#
# Smoke test for the Hermes Agent deployment on the SpotUs DEV cluster.
# Exercises the whole live path end-to-end: pod health, LLM (Ollama), the
# dashboard login flow, WebSocket-ticket auth, and the chat WebSocket upgrade
# (the parts that only fail when actually driven — see docs/OPERATIONS.md).
#
# Usage:
#   export KUBECONFIG=~/.kube/spotus-dev.yaml
#   export HERMES_DASHBOARD_PW='<from Mintkey secret SPOTUS_DEV_HERMES_DASHBOARD>'
#   ./scripts/smoke-test.sh
#
# The password is only needed for the login/WS tests; without it those are
# skipped and the rest still run. Exit code is non-zero if any check FAILS.
#
set -uo pipefail

NS="${HERMES_NS:-hermes}"
POD="${HERMES_POD:-hermes-hermes-agent-0}"
DASH_PORT="${HERMES_DASH_PORT:-9119}"
PUBLIC_URL="${HERMES_PUBLIC_URL:-https://hermes-dev.spotusspaceapi.org}"
DASH_USER="${HERMES_DASHBOARD_USER:-admin}"
PW="${HERMES_DASHBOARD_PW:-}"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; fail=$((fail+1)); }
warn() { printf '  \033[33m[SKIP]\033[0m %s\n' "$1"; skip=$((skip+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 2; }
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace $NS not found (is KUBECONFIG set to the cluster?)"; exit 2; }

# in-pod exec helpers
gx() { kubectl -n "$NS" exec "$POD" -c gateway   -- sh -c "$1" 2>/dev/null; }
dx() { kubectl -n "$NS" exec "$POD" -c dashboard -- sh -c "$1" 2>/dev/null; }

hdr "1. Pod health"
phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
ready=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
[ "$phase" = "Running" ] && [ "$ready" = "true true true" ] \
  && ok "pod $POD Running 3/3 ($ready)" \
  || no "pod $POD not healthy (phase=$phase ready=$ready)"

hdr "2. Storage is Longhorn (survives node loss)"
sc=$(kubectl -n "$NS" get pvc "data-$POD" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
[ "$sc" = "longhorn" ] && ok "data PVC on StorageClass '$sc'" || no "data PVC StorageClass is '$sc' (expected longhorn)"

hdr "3. LLM (self-hosted Ollama) reachable + configured"
model=$(gx 'hermes config show 2>/dev/null' | grep -iA1 "Model:" | grep -oE "'default': '[^']*'" | head -1 | sed "s/.*': '//;s/'//")
[ -n "$model" ] && ok "configured model: $model" || no "could not read configured model"
ver=$(gx 'curl -s -m 8 "$OPENAI_BASE_URL/models" -o /dev/null -w "%{http_code}" 2>/dev/null')
[ "$ver" = "200" ] && ok "Ollama OpenAI endpoint reachable from pod (HTTP 200)" || no "Ollama endpoint not reachable (HTTP $ver)"

hdr "4. LLM chat round-trip (runs the model)"
reply=$(gx 'hermes -z "Reply with exactly one word: PONG" 2>/dev/null' | tr -d "[:space:]")
if printf '%s' "$reply" | grep -qi "pong"; then ok "one-shot chat replied ($reply)"; else no "chat did not reply as expected (got: '${reply:0:40}')"; fi

hdr "5. Public reachability (Cloudflare Tunnel)"
code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$PUBLIC_URL/" 2>/dev/null)
case "$code" in
  302|401|200) ok "public URL reachable (HTTP $code — gated as expected)";;
  000) warn "public URL did not resolve/connect (HTTP 000) — likely a local DNS negative-cache; see docs/OPERATIONS.md";;
  *)   no "public URL unexpected status (HTTP $code)";;
esac

hdr "6. Dashboard auth + chat WebSocket (needs HERMES_DASHBOARD_PW)"
if [ -z "$PW" ]; then
  warn "HERMES_DASHBOARD_PW not set — skipping login/WS tests (get it from Mintkey secret SPOTUS_DEV_HERMES_DASHBOARD)"
else
  result=$(kubectl -n "$NS" exec "$POD" -c dashboard -- sh -c "HERMES_PW='$PW' HERMES_USER='$DASH_USER' DPORT='$DASH_PORT' python3 - <<'PY' 2>/dev/null
import os, json, socket, base64, urllib.request, http.cookiejar
base=f\"http://127.0.0.1:{os.environ['DPORT']}\"
cj=http.cookiejar.CookieJar(); op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def call(path, body=None):
    h={'Origin':base}; data=None
    if body is not None: data=json.dumps(body).encode(); h['Content-Type']='application/json'
    return op.open(urllib.request.Request(base+path, data=data, headers=h), timeout=10)
try:
    r=call('/auth/password-login', {'provider':'basic','username':os.environ['HERMES_USER'],'password':os.environ['HERMES_PW']})
    print('LOGIN', r.status)
    t=json.load(call('/api/auth/ws-ticket', {}))['ticket']; print('TICKET ok')
    cookie='; '.join(f'{c.name}={c.value}' for c in cj)
    key=base64.b64encode(os.urandom(16)).decode()
    req=(f'GET /api/pty?channel=smoke&ticket={t} HTTP/1.1\r\nHost: hermes-dev.spotusspaceapi.org\r\n'
         f'Origin: https://hermes-dev.spotusspaceapi.org\r\nCookie: {cookie}\r\nUpgrade: websocket\r\n'
         f'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n')
    s=socket.create_connection(('127.0.0.1',int(os.environ['DPORT'])),8); s.sendall(req.encode())
    print('WS', s.recv(200).decode(errors='replace').splitlines()[0])
except Exception as e:
    print('ERROR', type(e).__name__, getattr(e,'code',e))
PY")
  echo "$result" | grep -q "LOGIN 200" && ok "dashboard login (admin) succeeded" || no "dashboard login failed ($result)"
  echo "$result" | grep -q "TICKET ok" && ok "WS ticket minted" || no "WS ticket mint failed"
  echo "$result" | grep -q "WS HTTP/1.1 101" && ok "chat WebSocket upgraded (101 Switching Protocols)" || no "chat WebSocket did not upgrade ($(echo "$result" | grep '^WS'))"
fi

hdr "Result"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] && { echo "Hermes smoke test: OK"; exit 0; } || { echo "Hermes smoke test: FAILURES"; exit 1; }
