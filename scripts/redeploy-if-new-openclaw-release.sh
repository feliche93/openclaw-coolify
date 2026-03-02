#!/usr/bin/env bash
set -euo pipefail

# Coolify Scheduled Task helper (single entrypoint):
# - Ensures Infisical secrets are available even when Coolify runs tasks via
#   `docker exec` (which does NOT inherit the `infisical run ... entrypoint.sh`
#   injected environment).
# - Resolves latest stable OpenClaw release and keeps OPENCLAW_GIT_REF aligned
#   in Coolify envs (so Docker build cache cannot pin stale `latest-release`).
# - Compares running OpenClaw version vs latest upstream release using core
#   release numbers only (YYYY.M.D), because upstream stable tags can still
#   report a `-beta` suffix in `openclaw --version`.
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

  exec env INFISICAL_TOKEN="$INFISICAL_RUNTIME_TOKEN" infisical run \
    --domain "$INFISICAL_API_URL" \
    --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV" \
    --path "$INFISICAL_PATH_EFFECTIVE" \
    -- env REDEPLOY_INFISICAL_WRAPPED=1 \
    /app/scripts/redeploy-if-new-openclaw-release.sh
}

ensure_coolify_token

current_raw="$(
  openclaw --version 2>/dev/null || true
)"

latest="$(
  curl -fsSL https://api.github.com/repos/openclaw/openclaw/releases/latest \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);const t=String(j.tag_name||"").replace(/^v/,"");if(!t)process.exit(2);process.stdout.write(t);});'
)"

if [ -z "${latest:-}" ]; then
  echo "[redeploy] ERROR: could not determine latest upstream version"
  exit 1
fi

desired_ref="v${latest}"
envs_url="${COOLIFY_API_BASE%/}/api/v1/applications/${COOLIFY_RESOURCE_UUID}/envs"

can_sync_ref="1"
has_ref="0"
current_ref=""

if envs_json="$(curl -fsS -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" "${envs_url}" 2>/tmp/redeploy-env-list.err)"; then
  read -r has_ref current_ref <<<"$(
    printf '%s' "${envs_json}" \
      | KEY="OPENCLAW_GIT_REF" node -e '
        const key = process.env.KEY;
        let s = "";
        process.stdin.on("data", d => (s += d)).on("end", () => {
          let arr;
          try { arr = JSON.parse(s); } catch { process.stdout.write("0 "); process.exit(0); }
          if (!Array.isArray(arr)) { process.stdout.write("0 "); process.exit(0); }
          const hit = arr.find(x => x && x.key === key);
          if (!hit) { process.stdout.write("0 "); return; }
          process.stdout.write("1 " + String(hit.value || ""));
        });
      '
  )"
else
  can_sync_ref="0"
  echo "[redeploy] WARN: unable to read Coolify envs; skipping OPENCLAW_GIT_REF sync."
  sed -n '1,120p' /tmp/redeploy-env-list.err || true
fi

if [ "${can_sync_ref}" = "1" ]; then
  if [ "${has_ref:-0}" != "1" ] || [ "${current_ref:-}" != "${desired_ref}" ]; then
    payload="$(KEY="OPENCLAW_GIT_REF" VALUE="${desired_ref}" node -e '
      const body = {
        key: process.env.KEY,
        value: process.env.VALUE,
        is_preview: false,
        is_literal: false,
        is_multiline: false,
        is_shown_once: false
      };
      process.stdout.write(JSON.stringify(body));
    ')"
    method="POST"
    if [ "${has_ref:-0}" = "1" ]; then
      method="PATCH"
    fi
    status="$(
      curl -sS -o /tmp/redeploy-env-update.out -w "%{http_code}" \
        -X "${method}" \
        -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${payload}" \
        "${envs_url}" || true
    )"
    if [ "${status#2}" = "${status}" ]; then
      # Fallback in case API shape differs from docs for this instance.
      if [ "${method}" = "PATCH" ]; then
        status="$(
          curl -sS -o /tmp/redeploy-env-update.out -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "${payload}" \
            "${envs_url}" || true
        )"
      fi
    fi
    if [ "${status#2}" = "${status}" ]; then
      echo "[redeploy] WARN: failed to set OPENCLAW_GIT_REF=${desired_ref} (status=${status}); continuing."
      sed -n '1,120p' /tmp/redeploy-env-update.out || true
    else
      echo "[redeploy] OPENCLAW_GIT_REF updated to ${desired_ref} in Coolify env."
    fi
  else
    echo "[redeploy] OPENCLAW_GIT_REF already ${desired_ref}."
  fi
fi

current_core="$(
  printf '%s' "${current_raw}" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/' | head -n1
)"
latest_core="$(
  printf '%s' "${latest}" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/' | head -n1
)"

cmp="$(
  CURRENT="${current_core}" LATEST="${latest_core}" node -e '
    const a = String(process.env.CURRENT || "").split(".").map(n => parseInt(n, 10));
    const b = String(process.env.LATEST || "").split(".").map(n => parseInt(n, 10));
    if (a.length < 3 || b.length < 3 || a.some(Number.isNaN) || b.some(Number.isNaN)) {
      process.stdout.write("unknown");
      process.exit(0);
    }
    for (let i = 0; i < 3; i++) {
      if (a[i] < b[i]) { process.stdout.write("-1"); process.exit(0); }
      if (a[i] > b[i]) { process.stdout.write("1"); process.exit(0); }
    }
    process.stdout.write("0");
  ' 2>/dev/null
)" || cmp="unknown"

if [ "${COOLIFY_FORCE}" != "true" ]; then
  if [ "${cmp}" = "0" ] || [ "${cmp}" = "1" ]; then
    echo "[redeploy] Up to date or ahead (current=${current_raw:-unknown} latest=${latest}); skipping deploy."
    exit 0
  fi
fi

if [ "${cmp}" = "unknown" ]; then
  echo "[redeploy] WARN: could not reliably compare current='${current_raw:-unknown}' vs latest='${latest}'. Deploying."
fi

deploy_url="${COOLIFY_API_BASE%/}/api/v1/deploy?uuid=${COOLIFY_RESOURCE_UUID}&force=${COOLIFY_FORCE}"

echo "[redeploy] Triggering deploy (current=${current_raw:-unknown} latest=${latest} force=${COOLIFY_FORCE})"
curl -fsS -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" "${deploy_url}" >/dev/null
echo "[redeploy] Deploy requested: ${deploy_url}"
