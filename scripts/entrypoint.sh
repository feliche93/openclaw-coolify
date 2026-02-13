#!/usr/bin/env bash
set -e

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo "[entrypoint] state dir: $STATE_DIR"
echo "[entrypoint] workspace dir: $WORKSPACE_DIR"

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
chmod 600 "$STATE_DIR/openclaw.json"

# ── Optional: camofox-browser plugin (Camoufox anti-detection browser) ───────
# Gate on CAMOFOX_BROWSER_URL so we don't slow down startup unless requested.
if [ -n "${CAMOFOX_BROWSER_URL:-}" ]; then
  echo "[entrypoint] camofox-browser requested (CAMOFOX_BROWSER_URL set)"
  cd /opt/openclaw/app

  if [ ! -d "$STATE_DIR/extensions/camofox-browser" ]; then
    echo "[entrypoint] installing @askjo/camofox-browser..."
    # This can be slow on first boot (npm install + postinstall hooks).
    if command -v timeout >/dev/null 2>&1; then
      timeout 900s openclaw plugins install @askjo/camofox-browser
    else
      openclaw plugins install @askjo/camofox-browser
    fi
  else
    echo "[entrypoint] camofox-browser already installed"
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
NGINX_CONF="/etc/nginx/conf.d/openclaw.conf"

AUTH_BLOCK=""
if [ -n "$AUTH_PASSWORD" ]; then
  echo "[entrypoint] setting up nginx basic auth (user: $AUTH_USERNAME)"
  htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USERNAME" "$AUTH_PASSWORD" 2>/dev/null
  AUTH_BLOCK='auth_basic "Openclaw";
        auth_basic_user_file /etc/nginx/.htpasswd;'
else
  echo "[entrypoint] no AUTH_PASSWORD set, nginx will not require authentication"
fi

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
        return 200 '{"ok":true,"gateway":"starting"}';
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

GATEWAY_ARGS=(
  gateway
  --port "$GATEWAY_PORT"
  --verbose
  --allow-unconfigured
  --bind "${OPENCLAW_GATEWAY_BIND:-loopback}"
)

GATEWAY_ARGS+=(--token "$GATEWAY_TOKEN")

# cwd must be the app root so the gateway finds dist/control-ui/ assets
cd /opt/openclaw/app
exec openclaw "${GATEWAY_ARGS[@]}"
