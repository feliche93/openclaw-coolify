#!/usr/bin/env bash
set -e

OPENCLAW_ENTRYPOINT="${OPENCLAW_ENTRYPOINT:-/opt/openclaw/app/openclaw.mjs}"

if [ -n "${INFISICAL_PROJECT_ID:-}" ] && [ -z "${INFISICAL_INJECTED:-}" ]; then
  INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"
  INFISICAL_RUNTIME_TOKEN=""

  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$INFISICAL_TOKEN"
  elif [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$(node -e "
      const api = process.env.INFISICAL_API_URL || 'https://app.infisical.com/api';
      const clientId = process.env.INFISICAL_CLIENT_ID;
      const clientSecret = process.env.INFISICAL_CLIENT_SECRET;
      if (!clientId || !clientSecret) process.exit(2);
      fetch(api.replace(/\\/+$/,'') + '/v1/auth/universal-auth/login', {
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
    " 2>/dev/null)"
  fi

  if [ -n "${INFISICAL_RUNTIME_TOKEN:-}" ]; then
    exec env \
      INFISICAL_INJECTED=1 \
      INFISICAL_TOKEN="$INFISICAL_RUNTIME_TOKEN" \
      infisical run \
      --domain "$INFISICAL_API_URL" \
      --projectId "$INFISICAL_PROJECT_ID" \
      --env "${INFISICAL_ENV:-prod}" \
      --path "${INFISICAL_PATH:-/}" \
      -- node "$OPENCLAW_ENTRYPOINT" "$@"
  fi
fi

exec node "$OPENCLAW_ENTRYPOINT" "$@"
