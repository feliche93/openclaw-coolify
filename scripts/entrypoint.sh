#!/usr/bin/env bash
set -e

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo "[entrypoint] state dir: $STATE_DIR"
echo "[entrypoint] workspace dir: $WORKSPACE_DIR"

# ── Optional: inject secrets from Infisical (runtime) ────────────────────────
# If Infisical credentials are provided, re-exec the entrypoint under
# `infisical run` so all subsequent checks + configure.js see the injected env.
#
# Supported auth inputs:
# - Service token: INFISICAL_TOKEN + INFISICAL_PROJECT_ID
# - Universal Auth: INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET + INFISICAL_PROJECT_ID
#
# This keeps Coolify env vars minimal: only INFISICAL_* needs to live in Coolify.
if [ -n "${INFISICAL_PROJECT_ID:-}" ] && [ -z "${INFISICAL_INJECTED:-}" ]; then
  INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"
  INFISICAL_RUNTIME_TOKEN=""

  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$INFISICAL_TOKEN"
  elif [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    echo "[entrypoint] infisical: acquiring access token (universal-auth)"
    # Use direct HTTP to avoid the CLI printing tokens to logs on some versions.
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
        if (!res.ok || !tok) {
          console.error('[entrypoint] infisical: token request failed (status=' + res.status + ')');
          process.exit(1);
        }
        process.stdout.write(tok);
      }).catch((e) => { console.error('[entrypoint] infisical: token request error'); process.exit(1); });
    ")"
  fi

  if [ -n "${INFISICAL_RUNTIME_TOKEN:-}" ]; then
    export INFISICAL_INJECTED=1
    INFISICAL_ENV_EFFECTIVE="${INFISICAL_ENV:-prod}"
    INFISICAL_PATH_EFFECTIVE="${INFISICAL_PATH:-/}"
    echo "[entrypoint] infisical: injecting secrets (env=$INFISICAL_ENV_EFFECTIVE path=$INFISICAL_PATH_EFFECTIVE)"
    exec env INFISICAL_TOKEN="$INFISICAL_RUNTIME_TOKEN" infisical run \
      --domain "$INFISICAL_API_URL" \
      --projectId "$INFISICAL_PROJECT_ID" \
      --env "$INFISICAL_ENV_EFFECTIVE" \
      --path "$INFISICAL_PATH_EFFECTIVE" \
      -- /app/scripts/entrypoint.sh
  fi
fi

# ── Coolify magic env var aliases (runtime-safe) ─────────────────────────────
# In Coolify Compose, "magic" SERVICE_* vars are reliably injected into the
# container env, but Docker Compose var substitution (VAR=${SERVICE_*}) can be
# brittle. Prefer mapping at runtime so CLIs can depend on stable env names.
if [ -z "${CAMOFOX_API_KEY:-}" ] && [ -n "${SERVICE_BASE64_64_CAMOFOX:-}" ]; then
  export CAMOFOX_API_KEY="$SERVICE_BASE64_64_CAMOFOX"
fi

if [ -z "${GOG_KEYRING_BACKEND:-}" ]; then
  export GOG_KEYRING_BACKEND="file"
fi
if [ -z "${GOG_KEYRING_PASSWORD:-}" ] && [ -n "${SERVICE_PASSWORD_64_GOGKEYRING:-}" ]; then
  export GOG_KEYRING_PASSWORD="$SERVICE_PASSWORD_64_GOGKEYRING"
fi

# ── Install extra apt packages (if requested) ────────────────────────────────
if [ -n "${OPENCLAW_DOCKER_APT_PACKAGES:-}" ]; then
  echo "[entrypoint] installing extra packages: $OPENCLAW_DOCKER_APT_PACKAGES"
  apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $OPENCLAW_DOCKER_APT_PACKAGES \
    && rm -rf /var/lib/apt/lists/*
fi

# ── Require OPENCLAW_GATEWAY_TOKEN ───────────────────────────────────────────
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_TOKEN is required."
  echo "[entrypoint] Generate one with: openssl rand -hex 32"
  exit 1
fi
GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"

# ── Require at least one AI provider API key env var ─────────────────────────
# Providers always read API keys from env vars, never from JSON config.
HAS_PROVIDER=0
for key in ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY \
           XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY CEREBRAS_API_KEY \
           VENICE_API_KEY MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY \
           ZAI_API_KEY AI_GATEWAY_API_KEY OPENCODE_API_KEY OPENCODE_ZEN_API_KEY \
           SYNTHETIC_API_KEY COPILOT_GITHUB_TOKEN XIAOMI_API_KEY; do
  [ -n "${!key:-}" ] && HAS_PROVIDER=1 && break
done
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && HAS_PROVIDER=1
[ -n "${OLLAMA_BASE_URL:-}" ] && HAS_PROVIDER=1
if [ "$HAS_PROVIDER" -eq 0 ]; then
  echo "[entrypoint] ERROR: At least one AI provider API key env var is required."
  echo "[entrypoint] Providers read API keys from env vars, never from the JSON config."
  echo "[entrypoint] Set one of: ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY, GEMINI_API_KEY,"
  echo "[entrypoint]   XAI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, CEREBRAS_API_KEY, VENICE_API_KEY,"
  echo "[entrypoint]   MOONSHOT_API_KEY, KIMI_API_KEY, MINIMAX_API_KEY, ZAI_API_KEY, AI_GATEWAY_API_KEY,"
  echo "[entrypoint]   OPENCODE_API_KEY, SYNTHETIC_API_KEY, COPILOT_GITHUB_TOKEN, XIAOMI_API_KEY"
  echo "[entrypoint] Or: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (Bedrock), OLLAMA_BASE_URL (local)"
  exit 1
fi

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
mkdir -p "$STATE_DIR/agents/main/sessions" "$STATE_DIR/credentials"
chmod 700 "$STATE_DIR"

# Export state/workspace dirs so openclaw CLI + configure.js see them
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_WORKSPACE_DIR="$WORKSPACE_DIR"

# Set HOME so that ~/.openclaw resolves to $STATE_DIR directly.
# This avoids "multiple state directories" warnings from openclaw doctor
# (symlinks are detected as separate paths).
export HOME="${STATE_DIR%/.openclaw}"

# ── Pre-clean: avoid invalid config if plugin config exists before install ───
if [ -n "${CAMOFOX_BROWSER_URL:-}" ] && [ ! -d "$STATE_DIR/extensions/camofox-browser" ] && [ -f "$STATE_DIR/openclaw.json" ]; then
  echo "[entrypoint] removing stale camofox-browser plugin entry (not installed yet)"
  node -e "
    const fs = require('fs');
    const p = '$STATE_DIR/openclaw.json';
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (j.plugins && j.plugins.entries) delete j.plugins.entries['camofox-browser'];
    if (j.plugins && j.plugins.installs) delete j.plugins.installs['camofox-browser'];
    fs.writeFileSync(p, JSON.stringify(j, null, 2));
  " || true
fi

# ── Configure openclaw from env vars ─────────────────────────────────────────
echo "[entrypoint] running configure..."
node /app/scripts/configure.js

# Keep gateway token env-authoritative; remove any persisted token field.
node -e "
  const fs = require('fs');
  const p = '$STATE_DIR/openclaw.json';
  try {
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (j.gateway && j.gateway.auth && Object.prototype.hasOwnProperty.call(j.gateway.auth, 'token')) {
      delete j.gateway.auth.token;
      fs.writeFileSync(p, JSON.stringify(j, null, 2));
    }
  } catch (_) {}
" || true

# Optional: pre-seed exec-approvals socket token from env (e.g. Infisical).
# This avoids random token generation drifting across restarts.
if [ -n "${OPENCLAW_EXEC_SOCKET_TOKEN:-}" ]; then
  export OPENCLAW_EXEC_APPROVALS_SOCKET_PATH="${OPENCLAW_EXEC_APPROVALS_SOCKET_PATH:-$STATE_DIR/exec-approvals.sock}"
  echo "[entrypoint] writing exec-approvals token from env"
  node -e "
    const fs = require('fs');
    const token = process.env.OPENCLAW_EXEC_SOCKET_TOKEN || '';
    const socketPath = process.env.OPENCLAW_EXEC_APPROVALS_SOCKET_PATH || '$STATE_DIR/exec-approvals.sock';
    const p = '$STATE_DIR/exec-approvals.json';
    if (!token) process.exit(0);
    fs.mkdirSync('$STATE_DIR', { recursive: true });
    fs.writeFileSync(p, JSON.stringify({ socket: { path: socketPath, token } }, null, 2));
  " || true
  chmod 600 "$STATE_DIR/exec-approvals.json" || true
fi

chmod 600 "$STATE_DIR/openclaw.json"

# ── Optional: camofox-browser plugin (Camoufox anti-detection browser) ───────
# Gate on CAMOFOX_BROWSER_URL so we don't slow down startup unless requested.
if [ -n "${CAMOFOX_BROWSER_URL:-}" ]; then
  echo "[entrypoint] camofox-browser requested (CAMOFOX_BROWSER_URL set)"
  cd /opt/openclaw/app

  CAMOFOX_PLUGIN_VERSION="${CAMOFOX_PLUGIN_VERSION:-latest}"
  CAMOFOX_PLUGIN_SPEC="@askjo/camofox-browser"
  if [ "$CAMOFOX_PLUGIN_VERSION" = "latest" ]; then
    CAMOFOX_PLUGIN_SPEC="@askjo/camofox-browser@latest"
  else
    CAMOFOX_PLUGIN_SPEC="@askjo/camofox-browser@${CAMOFOX_PLUGIN_VERSION}"
  fi

  CAMOFOX_INSTALLED_VERSION="$(node -e "
    const fs = require('fs');
    const p = process.argv[1];
    if (!fs.existsSync(p)) process.exit(0);
    try {
      const j = JSON.parse(fs.readFileSync(p, 'utf8'));
      if (j && j.version) process.stdout.write(String(j.version));
    } catch (_) {}
  " "$STATE_DIR/extensions/camofox-browser/package.json" 2>/dev/null || true)"

  CAMOFOX_TARGET_VERSION="$CAMOFOX_PLUGIN_VERSION"
  if [ "$CAMOFOX_PLUGIN_VERSION" = "latest" ]; then
    CAMOFOX_TARGET_VERSION="$(node -e "
      fetch('https://registry.npmjs.org/@askjo/camofox-browser/latest', {
        headers: { 'User-Agent': 'openclaw-coolify' }
      }).then(async (res) => {
        if (!res.ok) process.exit(1);
        const j = await res.json();
        if (!j || !j.version) process.exit(2);
        process.stdout.write(String(j.version));
      }).catch(() => process.exit(1));
    " 2>/dev/null || true)"
  fi

  NEEDS_CAMOFOX_INSTALL=0
  if [ -z "$CAMOFOX_INSTALLED_VERSION" ]; then
    NEEDS_CAMOFOX_INSTALL=1
    echo "[entrypoint] camofox-browser plugin not installed; installing $CAMOFOX_PLUGIN_SPEC"
  elif [ -n "$CAMOFOX_TARGET_VERSION" ] && [ "$CAMOFOX_INSTALLED_VERSION" != "$CAMOFOX_TARGET_VERSION" ]; then
    NEEDS_CAMOFOX_INSTALL=1
    echo "[entrypoint] camofox-browser plugin update: $CAMOFOX_INSTALLED_VERSION -> $CAMOFOX_TARGET_VERSION"
  elif [ "$CAMOFOX_PLUGIN_VERSION" = "latest" ] && [ -z "$CAMOFOX_TARGET_VERSION" ]; then
    echo "[entrypoint] camofox-browser plugin latest version lookup failed; keeping $CAMOFOX_INSTALLED_VERSION"
  else
    echo "[entrypoint] camofox-browser plugin already up-to-date ($CAMOFOX_INSTALLED_VERSION)"
  fi

  if [ "$NEEDS_CAMOFOX_INSTALL" -eq 1 ]; then
    # This can be slow on first boot (npm install + postinstall hooks).
    if command -v timeout >/dev/null 2>&1; then
      timeout 900s openclaw plugins install "$CAMOFOX_PLUGIN_SPEC"
    else
      openclaw plugins install "$CAMOFOX_PLUGIN_SPEC"
    fi
  fi

  # Avoid relying on `openclaw plugins enable`, which can hang in some container
  # environments even after printing a success message. Enabling is just a JSON
  # config toggle, so patch it directly.
  echo "[entrypoint] enabling + configuring camofox-browser..."
  node -e "
    const fs = require('fs');
    const p = (process.env.OPENCLAW_STATE_DIR || '$STATE_DIR') + '/openclaw.json';
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    j.plugins = j.plugins || {};
    j.plugins.entries = j.plugins.entries || {};
    j.plugins.entries['camofox-browser'] = j.plugins.entries['camofox-browser'] || {};
    const e = j.plugins.entries['camofox-browser'];
    e.enabled = true;
    e.config = e.config || {};
    if (process.env.CAMOFOX_BROWSER_URL) e.config.url = process.env.CAMOFOX_BROWSER_URL;
    if (process.env.CAMOFOX_BROWSER_PORT) e.config.port = parseInt(process.env.CAMOFOX_BROWSER_PORT, 10);
    if (process.env.CAMOFOX_BROWSER_AUTOSTART !== undefined) e.config.autoStart = process.env.CAMOFOX_BROWSER_AUTOSTART === 'true';
    fs.writeFileSync(p, JSON.stringify(j, null, 2));
  "
  chmod 600 "$STATE_DIR/openclaw.json"
fi

# ── Auto-fix doctor suggestions (e.g. enable configured channels) ─────────
echo "[entrypoint] running openclaw doctor --fix..."
cd /opt/openclaw/app
openclaw doctor --fix 2>&1 || true

# ── mcporter config bootstrap (single source of truth) ───────────────────────
# Goal: keep exactly one persisted config file, but make it discoverable from
# both common working dirs:
#   - /data/.openclaw/mcporter.json (state)
#   - /data/workspace/config/mcporter.json (workspace)
#
# We store the canonical file in the workspace so agents editing "from the repo"
# naturally touch the right one, then link the state path to it.
MCPORTER_WORKSPACE_DIR="$WORKSPACE_DIR/config"
MCPORTER_WORKSPACE_PATH="$MCPORTER_WORKSPACE_DIR/mcporter.json"
MCPORTER_STATE_PATH="$STATE_DIR/mcporter.json"
MCPORTER_TEMPLATE_PATH="/app/config/mcporter.json"
export MCPORTER_TEMPLATE_PATH MCPORTER_WORKSPACE_PATH

mkdir -p "$MCPORTER_WORKSPACE_DIR"

# If neither exists, seed from the baked template.
if [ ! -f "$MCPORTER_WORKSPACE_PATH" ] && [ ! -f "$MCPORTER_STATE_PATH" ] && [ -f "$MCPORTER_TEMPLATE_PATH" ]; then
  cp "$MCPORTER_TEMPLATE_PATH" "$MCPORTER_WORKSPACE_PATH"
  chmod 600 "$MCPORTER_WORKSPACE_PATH" || true
  echo "[entrypoint] seeded mcporter config: $MCPORTER_WORKSPACE_PATH"
fi

# If state exists but workspace doesn't, copy it into workspace.
if [ -f "$MCPORTER_STATE_PATH" ] && [ ! -f "$MCPORTER_WORKSPACE_PATH" ]; then
  cp "$MCPORTER_STATE_PATH" "$MCPORTER_WORKSPACE_PATH"
  chmod 600 "$MCPORTER_WORKSPACE_PATH" || true
  echo "[entrypoint] copied mcporter config to workspace: $MCPORTER_WORKSPACE_PATH"
fi

# If a template exists, merge any missing server entries into the canonical file.
# This lets us ship new MCP configs in the image without clobbering user edits.
if [ -f "$MCPORTER_TEMPLATE_PATH" ] && [ -f "$MCPORTER_WORKSPACE_PATH" ]; then
  node -e "
    const fs = require('fs');
    const tmplPath = process.env.MCPORTER_TEMPLATE_PATH;
    const dstPath = process.env.MCPORTER_WORKSPACE_PATH;
    const tmpl = JSON.parse(fs.readFileSync(tmplPath, 'utf8'));
    const dst = JSON.parse(fs.readFileSync(dstPath, 'utf8'));
    dst.mcpServers = dst.mcpServers || {};
    const tmplServers = (tmpl && tmpl.mcpServers) || {};
    let added = 0;
    for (const [name, cfg] of Object.entries(tmplServers)) {
      if (!(name in dst.mcpServers)) {
        dst.mcpServers[name] = cfg;
        added++;
      }
    }
    if (added > 0) {
      fs.writeFileSync(dstPath, JSON.stringify(dst, null, 2));
      console.log('[entrypoint] merged mcporter template entries into canonical config (added=' + added + ')');
    }
  " 2>/dev/null || true
  chmod 600 "$MCPORTER_WORKSPACE_PATH" || true
fi

# Ensure the state path points at the workspace file.
if [ -f "$MCPORTER_WORKSPACE_PATH" ]; then
  rm -f "$MCPORTER_STATE_PATH"
  ln -s "$MCPORTER_WORKSPACE_PATH" "$MCPORTER_STATE_PATH"
  echo "[entrypoint] linked mcporter config: $MCPORTER_STATE_PATH -> $MCPORTER_WORKSPACE_PATH"
fi

# ── Tool/CLI sanity checks (show up in Coolify logs) ─────────────────────────
if command -v mcporter >/dev/null 2>&1; then
  echo "[entrypoint] mcporter available: $(mcporter --version 2>/dev/null || echo 'version-check-failed')"
else
  echo "[entrypoint] mcporter missing from PATH"
fi

if command -v whisper >/dev/null 2>&1; then
  echo "[entrypoint] whisper available"
else
  echo "[entrypoint] whisper missing from PATH"
fi

if command -v bvg >/dev/null 2>&1; then
  echo "[entrypoint] bvg available"
else
  echo "[entrypoint] bvg missing from PATH"
fi

if command -v goplaces >/dev/null 2>&1; then
  echo "[entrypoint] goplaces available"
else
  echo "[entrypoint] goplaces missing from PATH"
fi

# ── Read hooks path from generated config (if hooks enabled) ─────────────────
HOOKS_PATH=""
HOOKS_PATH=$(node -e "
  try {
    const c = JSON.parse(require('fs').readFileSync('$STATE_DIR/openclaw.json','utf8'));
    if (c.hooks && c.hooks.enabled) process.stdout.write(c.hooks.path || '/hooks');
  } catch {}
" 2>/dev/null || true)
if [ -n "$HOOKS_PATH" ]; then
  echo "[entrypoint] hooks enabled, path: $HOOKS_PATH (will bypass HTTP auth)"
fi

# ── Generate nginx config ────────────────────────────────────────────────────
AUTH_PASSWORD="${AUTH_PASSWORD:-}"
AUTH_USERNAME="${AUTH_USERNAME:-admin}"
# OPENCLAW_BASIC_AUTH controls whether nginx enforces HTTP basic auth.
# Values:
# - auto (default): enable basic auth only when AUTH_PASSWORD is set
# - on: require basic auth; error if AUTH_PASSWORD is missing
# - off: disable basic auth even if AUTH_PASSWORD is set (for Cloudflare Access, etc.)
OPENCLAW_BASIC_AUTH="${OPENCLAW_BASIC_AUTH:-auto}"
NGINX_CONF="/etc/nginx/conf.d/openclaw.conf"

AUTH_BLOCK=""
case "$OPENCLAW_BASIC_AUTH" in
  auto)
    if [ -n "$AUTH_PASSWORD" ]; then
      echo "[entrypoint] setting up nginx basic auth (user: $AUTH_USERNAME; mode=auto)"
      htpasswd -Bbc /etc/nginx/.htpasswd "$AUTH_USERNAME" "$AUTH_PASSWORD" 2>/dev/null
      AUTH_BLOCK='auth_basic "Openclaw";
        auth_basic_user_file /etc/nginx/.htpasswd;'
    else
      echo "[entrypoint] basic auth disabled (mode=auto; no AUTH_PASSWORD)"
    fi
    ;;
  on)
    if [ -z "$AUTH_PASSWORD" ]; then
      echo "[entrypoint] ERROR: OPENCLAW_BASIC_AUTH=on requires AUTH_PASSWORD" >&2
      exit 1
    fi
    echo "[entrypoint] setting up nginx basic auth (user: $AUTH_USERNAME; mode=on)"
    htpasswd -Bbc /etc/nginx/.htpasswd "$AUTH_USERNAME" "$AUTH_PASSWORD" 2>/dev/null
    AUTH_BLOCK='auth_basic "Openclaw";
        auth_basic_user_file /etc/nginx/.htpasswd;'
    ;;
  off)
    if [ -n "$AUTH_PASSWORD" ]; then
      echo "[entrypoint] basic auth disabled (mode=off; ignoring AUTH_PASSWORD)"
    else
      echo "[entrypoint] basic auth disabled (mode=off)"
    fi
    ;;
  *)
    echo "[entrypoint] ERROR: invalid OPENCLAW_BASIC_AUTH='$OPENCLAW_BASIC_AUTH' (expected: auto|on|off)" >&2
    exit 1
    ;;
esac

# Build hooks location block (skips HTTP basic auth, openclaw validates hook token)
HOOKS_LOCATION_BLOCK=""
if [ -n "$HOOKS_PATH" ]; then
  HOOKS_LOCATION_BLOCK="location ${HOOKS_PATH} {
        proxy_pass http://127.0.0.1:${GATEWAY_PORT};
        proxy_set_header Authorization \"Bearer ${GATEWAY_TOKEN}\";

        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;

        proxy_http_version 1.1;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }"
fi


# ── Write startup page for 502/503/504 while gateway boots ───────────────────
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/starting.html <<'STARTPAGE'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Openclaw - Starting</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: #0a0a0a; color: #e5e5e5; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
    .card { text-align: center; max-width: 480px; padding: 2.5rem; }
    h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 1rem; }
    p { color: #a3a3a3; line-height: 1.6; margin-bottom: 1.5rem; }
    .spinner { width: 32px; height: 32px; border: 3px solid #333; border-top-color: #e5e5e5; border-radius: 50%; animation: spin 0.8s linear infinite; margin: 0 auto 1.5rem; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .retry { color: #737373; font-size: 0.85rem; }
  </style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>Openclaw is starting up</h1>
    <p>The gateway is initializing.</p>
    <p>This usually takes a few minutes.</p>
    <p class="retry">This page will auto-refresh.</p>
  </div>
  <script>setTimeout(function(){ location.reload(); }, 3000);</script>
</body>
</html>
STARTPAGE

cat > "$NGINX_CONF" <<NGINXEOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

map \$arg_token \$ocw_has_token {
    ''      0;
    default 1;
}

map "\$ocw_has_token:\$args" \$ocw_proxy_args {
    ~^1:    \$args;
    ~^0:.+  "\$args&token=${GATEWAY_TOKEN}";
    default "token=${GATEWAY_TOKEN}";
}

server {
    listen ${PORT:-8080} default_server;
    server_name _;
    absolute_redirect off;

    location = /healthz {
        access_log off;
        proxy_pass http://127.0.0.1:${GATEWAY_PORT}/;
        proxy_set_header Host \$host;
        proxy_connect_timeout 2s;
        error_page 502 503 504 = @healthz_fallback;
    }

    location @healthz_fallback {
        # Readiness: fail healthcheck until gateway is actually accepting requests.
        return 503 '{"ok":false,"gateway":"starting"}';
        default_type application/json;
    }

    ${HOOKS_LOCATION_BLOCK}

    location / {
        ${AUTH_BLOCK}

        proxy_pass http://127.0.0.1:${GATEWAY_PORT}\$uri?\$ocw_proxy_args;
        proxy_set_header Authorization "Bearer ${GATEWAY_TOKEN}";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        error_page 502 503 504 /starting.html;
    }

    location = /starting.html {
        root /usr/share/nginx/html;
        internal;
    }

    # Browser sidecar proxy (VNC web UI)
    location /browser/ {
        ${AUTH_BLOCK}

        proxy_pass http://browser:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINXEOF

# ── Start nginx ──────────────────────────────────────────────────────────────
echo "[entrypoint] starting nginx on port ${PORT:-8080}..."
nginx

# ── Clean up stale lock files ────────────────────────────────────────────────
rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$STATE_DIR/gateway.lock" 2>/dev/null || true

# ── Start openclaw gateway ───────────────────────────────────────────────────
echo "[entrypoint] starting openclaw gateway on port $GATEWAY_PORT..."

GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
# Guardrail: binding the gateway to LAN can bypass the nginx/Cloudflare ingress
# model if the port is ever exposed. Require an explicit override.
if [ "$GATEWAY_BIND" = "lan" ] && [ "${OPENCLAW_ALLOW_LAN_BIND:-}" != "true" ]; then
  echo "[entrypoint] ERROR: OPENCLAW_GATEWAY_BIND=lan is unsafe." >&2
  echo "[entrypoint] Set OPENCLAW_ALLOW_LAN_BIND=true to proceed (or use OPENCLAW_GATEWAY_BIND=loopback)." >&2
  exit 1
fi

GATEWAY_ARGS=(
  gateway
  --port "$GATEWAY_PORT"
  --verbose
  --allow-unconfigured
  --bind "$GATEWAY_BIND"
)

# Avoid passing secrets via process args. The gateway reads
# OPENCLAW_GATEWAY_TOKEN from env by default.
export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"

# cwd must be the app root so the gateway finds dist/control-ui/ assets
cd /opt/openclaw/app
exec openclaw "${GATEWAY_ARGS[@]}"
