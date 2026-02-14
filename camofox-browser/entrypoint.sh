#!/usr/bin/env sh
set -eu

# Optional: inject secrets from Infisical (runtime).
# Re-exec ourselves under `infisical run` so the Node process sees injected env.
if [ -n "${INFISICAL_PROJECT_ID:-}" ] && [ -z "${INFISICAL_INJECTED:-}" ]; then
  INFISICAL_RUNTIME_TOKEN=""
  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$INFISICAL_TOKEN"
  elif [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    echo "[camofox-entrypoint] infisical: acquiring access token (universal-auth)"
    INFISICAL_RUNTIME_TOKEN="$(infisical login \
      --method=universal-auth \
      --client-id "$INFISICAL_CLIENT_ID" \
      --client-secret "$INFISICAL_CLIENT_SECRET" \
      --plain --silent)"
  fi

  if [ -n "$INFISICAL_RUNTIME_TOKEN" ]; then
    export INFISICAL_INJECTED=1
    INFISICAL_ENV_EFFECTIVE="${INFISICAL_ENV:-prod}"
    INFISICAL_PATH_EFFECTIVE="${INFISICAL_PATH:-/}"
    echo "[camofox-entrypoint] infisical: injecting secrets (env=$INFISICAL_ENV_EFFECTIVE path=$INFISICAL_PATH_EFFECTIVE)"
    exec infisical run \
      --token "$INFISICAL_RUNTIME_TOKEN" \
      --projectId "$INFISICAL_PROJECT_ID" \
      --env "$INFISICAL_ENV_EFFECTIVE" \
      --path "$INFISICAL_PATH_EFFECTIVE" \
      -- "$0" "$@"
  fi
fi

# Coolify magic env var alias (if you store the value under SERVICE_BASE64_64_CAMOFOX).
if [ -z "${CAMOFOX_API_KEY:-}" ] && [ -n "${SERVICE_BASE64_64_CAMOFOX:-}" ]; then
  export CAMOFOX_API_KEY="$SERVICE_BASE64_64_CAMOFOX"
fi

exec "$@"
