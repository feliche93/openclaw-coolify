#!/usr/bin/env bash
set -euo pipefail

# Coolify Scheduled Task helper (single entrypoint):
# - Ensures Infisical secrets are available even when Coolify runs tasks via
#   `docker exec` (which does NOT inherit the `infisical run ... entrypoint.sh`
#   injected environment).
# - Compares running OpenClaw version vs latest upstream release.
# - Triggers a Coolify deploy only when a newer version exists.

COOLIFY_API_BASE="${COOLIFY_API_BASE:-https://app.coolify.io}"
COOLIFY_FORCE="${COOLIFY_FORCE:-false}"

if [ -z "${COOLIFY_RESOURCE_UUID:-}" ]; then
  echo "[redeploy] ERROR: COOLIFY_RESOURCE_UUID is required"
  exit 2
fi

ensure_coolify_token() {
  if [ -n "${COOLIFY_API_TOKEN:-}" ]; then
    return 0
  fi

  # Avoid loops: if Infisical injection ran but token still missing, fail hard.
  if [ -n "${REDEPLOY_INFISICAL_WRAPPED:-}" ]; then
    echo "[redeploy] ERROR: COOLIFY_API_TOKEN missing even after Infisical injection"
    return 2
  fi

  if [ -z "${INFISICAL_PROJECT_ID:-}" ] || [ -z "${INFISICAL_ENV:-}" ]; then
    echo "[redeploy] ERROR: COOLIFY_API_TOKEN not set, and INFISICAL_* not configured"
    return 2
  fi

  INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"
  INFISICAL_PATH_EFFECTIVE="${INFISICAL_PATH:-/}"

  INFISICAL_RUNTIME_TOKEN=""
  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$INFISICAL_TOKEN"
  elif [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    # Mirror entrypoint.sh: fetch access token via Universal Auth.
    INFISICAL_RUNTIME_TOKEN="$(node -e "
      const api = (process.env.INFISICAL_API_URL || 'https://app.infisical.com/api').replace(/\\/+$/,'');
      const clientId = process.env.INFISICAL_CLIENT_ID;
      const clientSecret = process.env.INFISICAL_CLIENT_SECRET;
      if (!clientId || !clientSecret) process.exit(2);
      fetch(api + '/v1/auth/universal-auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ clientId, clientSecret })
      }).then(async (res) => {
        const txt = await res.text();
        let j;
        try { j = JSON.parse(txt); } catch { throw new Error('non-json response'); }
        const tok = j && (j.accessToken || j.access_token || (j.data && j.data.accessToken));
        if (!res.ok || !tok) process.exit(1);
        process.stdout.write(tok);
      }).catch(() => process.exit(1));
    ")"
  fi

  if [ -z "${INFISICAL_RUNTIME_TOKEN:-}" ]; then
    echo "[redeploy] ERROR: could not acquire Infisical token for scheduled task"
    return 2
  fi

  exec infisical run \
    --domain "$INFISICAL_API_URL" \
    --token "$INFISICAL_RUNTIME_TOKEN" \
    --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV" \
    --path "$INFISICAL_PATH_EFFECTIVE" \
    -- env REDEPLOY_INFISICAL_WRAPPED=1 \
    /app/scripts/redeploy-if-new-openclaw-release.sh
}

ensure_coolify_token

current="$(
  (openclaw --version 2>/dev/null || true) \
    | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/' \
    | head -n 1
)"

latest="$(
  curl -fsSL https://api.github.com/repos/openclaw/openclaw/releases/latest \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.tag_name||"").replace(/^v/,""));});' \
    | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/'
)"

if [ -z "${latest:-}" ]; then
  echo "[redeploy] ERROR: could not determine latest upstream version"
  exit 1
fi
if [ -z "${current:-}" ]; then
  echo "[redeploy] WARN: could not determine current version; will deploy if not forced? deploying anyway."
else
  if [ "${COOLIFY_FORCE}" != "true" ]; then
    cmp="$(
      CURRENT="${current}" LATEST="${latest}" node -e '
        const a = (process.env.CURRENT || "").split(".").map(n => parseInt(n,10));
        const b = (process.env.LATEST || "").split(".").map(n => parseInt(n,10));
        for (let i = 0; i < 3; i++) {
          const av = Number.isFinite(a[i]) ? a[i] : 0;
          const bv = Number.isFinite(b[i]) ? b[i] : 0;
          if (av < bv) { process.stdout.write("-1"); process.exit(0); }
          if (av > bv) { process.stdout.write("1"); process.exit(0); }
        }
        process.stdout.write("0");
      ' 2>/dev/null
    )" || cmp=""
    if [ "${cmp:-}" = "0" ] || [ "${cmp:-}" = "1" ]; then
      echo "[redeploy] Up to date or ahead (current=${current} latest=${latest}); skipping deploy."
      exit 0
    fi
  fi
fi

deploy_url="${COOLIFY_API_BASE%/}/api/v1/deploy?uuid=${COOLIFY_RESOURCE_UUID}&force=${COOLIFY_FORCE}"

echo "[redeploy] Triggering deploy (current=${current:-unknown} latest=${latest} force=${COOLIFY_FORCE})"
curl -fsS -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" "${deploy_url}" >/dev/null
echo "[redeploy] Deploy requested: ${deploy_url}"
