# Openclaw Automated Build

## Quick Start

### Minimal (`docker run`)

```bash
docker run -d \
  --name openclaw \
  -p 8080:8080 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -e AUTH_PASSWORD=changeme \
  -e OPENCLAW_GATEWAY_TOKEN=my-secret-token \
  -v openclaw-data:/data \
  coollabsio/openclaw:latest
```

- `ANTHROPIC_API_KEY` — any [supported provider key](#ai-providers-at-least-one-required) works (OpenAI, Gemini, etc.)
- `AUTH_PASSWORD` — protects the web UI with HTTP basic auth (user defaults to `admin`, override with `AUTH_USERNAME`)
- `OPENCLAW_GATEWAY_TOKEN` — internal API token; required (inject via Infisical or env var)
- `/data` — persists state, config, and workspace across restarts

### Full Setup (docker-compose)

Includes persistent storage, browser sidecar (CDP + VNC), and webhook hooks. See [`docker-compose.yml`](docker-compose.yml).

```bash
docker compose up -d
```

**After starting:**

1. **Openclaw UI** — `http://localhost:8080` (login: your `AUTH_USERNAME` / `AUTH_PASSWORD`)
2. **Browser desktop** — `http://localhost:8080/browser/` (login: your `AUTH_USERNAME` / browser `PASSWORD`) — use this to log into sites that need auth (OAuth, 2FA, captchas). Openclaw reuses the session via CDP.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Docker container (coollabsio/openclaw)     │
│                                             │
│  ┌──────────┐  :8080   ┌────────────────┐  │
│  │  nginx    │ ──────→  │  openclaw      │  │
│  │  (basic   │  proxy   │  gateway       │  │
│  │   auth)   │  :18789  │  :18789        │  │
│  └──────────┘          └────────────────┘  │
│                                             │
│  entrypoint.sh                              │
│    1. configure.js (env vars → json)        │
│    2. nginx (background)                    │
│    3. exec openclaw gateway                 │
└─────────────────────────────────────────────┘
```

Docker build strategy:
1. **Base image** (`Dockerfile.base`) — builds openclaw from source. Tagged `coollabsio/openclaw-base:<version>`.
2. **Runtime image** (`Dockerfile`) — self-contained build from upstream OpenClaw source + extra CLIs/tools used by built-in skills.

## Files

```
.github/workflows/auto-update.yml   — cron every 6h, check openclaw releases, build+push
.github/workflows/build.yml         — CI on push/PR (build only, no push)
Dockerfile.base                     — multi-stage: build openclaw from source → slim runtime
Dockerfile                          — self-contained image (builds OpenClaw from source + adds extra CLIs/tools, including global `agent-browser`, `summarize`, and `yt-dlp`)
scripts/configure.js                — reads env vars, writes/patches openclaw.json
scripts/entrypoint.sh               — container entrypoint: configure → nginx → gateway
scripts/smoke.js                    — smoke test (openclaw --version)
nginx/default.conf                  — reverse proxy :8080 → :18789, optional basic auth
.dockerignore                       — standard ignores
.env.example                        — env var reference
```

The `openclaw` service in `docker-compose.yml` builds `Dockerfile` with:
- `OPENCLAW_GIT_REF=${OPENCLAW_GIT_REF:-latest-release}` (build arg)
- `AGENT_BROWSER_VERSION=latest` (build arg; override with an exact version if you want to pin)
- `SUMMARIZE_VERSION=latest` (build arg)

This installs `agent-browser`, `summarize`, and `yt-dlp` globally in the container so OpenClaw agents can call them directly. By default, `agent-browser` follows the npm `latest` tag at build time, but you can override the build arg with an exact version if you want reproducible pinning.
It also vendors the `steipete/clawdis` `summarize` skill into the container's global OpenClaw skill directory, plus Codex for in-container coding-agent workflows.

### Runtime vs Workspace Git

- Runtime app path (`/opt/openclaw/app`) is treated as immutable artifact and does not keep `.git`.
- Do repo edits from inside OpenClaw in persistent workspace paths (`/data/workspace`), not runtime app paths.
- Practical flow for in-container edits:
  1. `cd /data/workspace`
  2. `git clone https://github.com/feliche93/openclaw-coolify.git` (first time)
  3. edit/commit/push from that workspace clone
  4. redeploy from Coolify (`main`)

This keeps production runtime clean while preserving your ability to manage your repos from within OpenClaw.

### Get Latest Faster (Self-Build)

This repo now mirrors upstream OpenClaw's source-build pattern for the custom image, so you can choose your update speed directly:

```bash
# Latest published OpenClaw release tag (resolved at build time)
OPENCLAW_GIT_REF=latest-release

# Fastest updates (latest upstream commit on main)
OPENCLAW_GIT_REF=main

# Reproducible pinned release
OPENCLAW_GIT_REF=v2026.2.22
```

Local builds:

```bash
# Build custom image from current OPENCLAW_GIT_REF (defaults to latest-release)
./scripts/build.sh custom

# Resolve latest release tag automatically and build custom image
OPENCLAW_GIT_REF=latest-release ./scripts/build.sh custom
```

In Coolify, set `OPENCLAW_GIT_REF` as a build env var (`main`, `latest-release`, or pinned `vYYYY.M.D`) and redeploy.

`Dockerfile` includes a `releases/latest` metadata marker layer so `latest-release` builds are less likely to get stuck on stale Docker cache.

## auto-update.yml workflow

```
Jobs:
1. check-release        — fetch latest openclaw/openclaw release, skip if image exists
2. build-base           — matrix amd64/arm64, build Dockerfile.base, push per-arch
3. merge-base-manifest  — merge into coollabsio/openclaw-base:<ver> + :latest
4. build-final          — matrix amd64/arm64, build Dockerfile, push per-arch
5. merge-final-manifest — merge into coollabsio/openclaw:<ver> + :latest
```

Triggers: `schedule: '0 */6 * * *'` + `workflow_dispatch` (version, force_rebuild, skip_latest_tag).

## Coolify Scheduled Task: Deploy Only When New Upstream Version Exists

If you deploy this repo in Coolify and want to redeploy only when a newer
stable `openclaw/openclaw` release exists, add a Coolify Scheduled Task that runs:

```bash
/app/scripts/redeploy-if-new-openclaw-release.sh
```

What this script now does:
- Resolves latest upstream stable release (not beta/prerelease)
- Updates Coolify env `OPENCLAW_GIT_REF` to the resolved tag (for example `v2026.3.1`) before deploy
- Compares running vs latest by core release number (`YYYY.M.D`) to avoid false drift when upstream stable tags still expose a `-beta` suffix in `openclaw --version`
- Triggers deploy only when required (or when `COOLIFY_FORCE=true`)

This avoids stale Docker cache behavior where `latest-release` can otherwise keep building an older prerelease layer.

## Backups (R2): OpenClaw `/data` Volume Only

If you want to back up OpenClaw state/workspace persisted in `/data` (but not the browser profile),
you can add a Coolify Scheduled Task on the **openclaw** application that runs:

```bash
/app/scripts/backup-openclaw-data-to-r2.sh
```

Required environment variables (store them in Infisical if possible):
- `R2_ENDPOINT` (Cloudflare R2 S3 endpoint, e.g. `https://<accountid>.r2.cloudflarestorage.com`)
- `R2_BUCKET`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `RESTIC_PASSWORD` (restic repository encryption password; required to restore)

Optional:
- `R2_PREFIX` (defaults to `coolify/openclaw-data/<COOLIFY_RESOURCE_UUID>`)
- `KEEP_DAILY`/`KEEP_WEEKLY`/`KEEP_MONTHLY` (defaults: 7/4/6)

Required environment variables (recommend storing in Infisical and injecting at runtime):
- `COOLIFY_API_TOKEN` (Coolify API token; Bearer)
- `COOLIFY_RESOURCE_UUID` (the Coolify resource UUID you want to redeploy)

Optional:
- `COOLIFY_API_BASE` (defaults to `https://app.coolify.io`; set for self-hosted)
- `COOLIFY_FORCE` (`true`/`false`, defaults to `false`)

## Secrets needed (repo settings)

- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub access token
- `GITHUB_TOKEN` — auto-provided by GitHub Actions

## Environment variables

### AI Providers (at least one required)

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key. Configures Claude models (Opus 4.5, Sonnet 4.5, Haiku 4.5). Set as primary when present. |
| `OPENAI_API_KEY` | OpenAI API key. Configures GPT models (5.2, 5, 4.5-preview). Primary if no Anthropic key. |
| `OPENROUTER_API_KEY` | OpenRouter API key. Primary if no Anthropic/OpenAI key. |
| `GEMINI_API_KEY` | Google Gemini API key. Primary if no other provider key set. |
| `XAI_API_KEY` | xAI API key. Configures Grok models. |
| `GROQ_API_KEY` | Groq API key. Configures Llama models on Groq hardware. |
| `MISTRAL_API_KEY` | Mistral API key. Configures Mistral Large and other models. |
| `CEREBRAS_API_KEY` | Cerebras API key. Configures Llama models on Cerebras hardware. |
| `VENICE_API_KEY` | Venice AI API key (OpenAI-compatible). Configures Llama 3.3 70B. |
| `MOONSHOT_API_KEY` | Moonshot API key (OpenAI-compatible). Configures Kimi K2.5. |
| `KIMI_API_KEY` | Kimi Coding API key (Anthropic-compatible). Configures K2P5. |
| `MINIMAX_API_KEY` | MiniMax API key (Anthropic-compatible). Configures MiniMax M2.1. |
| `ZAI_API_KEY` | ZAI API key. Configures GLM models. |
| `AI_GATEWAY_API_KEY` | Vercel AI Gateway API key. |
| `OPENCODE_API_KEY` | OpenCode API key. Also accepted as `OPENCODE_ZEN_API_KEY`. |
| `SYNTHETIC_API_KEY` | Synthetic API key (Anthropic-compatible). |
| `COPILOT_GITHUB_TOKEN` | GitHub Copilot token. Configures Claude models via GitHub. |
| `XIAOMI_API_KEY` | Xiaomi MiMo API key (Anthropic-compatible). Configures MiMo v2 Flash. |

Multiple providers can be set simultaneously. Priority for primary model: Anthropic > OpenAI > OpenRouter > Gemini > OpenCode > GitHub Copilot > xAI > Groq > Mistral > Cerebras > Venice > Moonshot > Kimi > MiniMax > Synthetic > ZAI > AI Gateway > Xiaomi > Bedrock > Ollama.

If a provider env var is removed, that provider section is cleaned from `openclaw.json` on next start.

### Infisical (optional; recommended for Coolify)

This Compose deployment uses Infisical Universal Auth. The container entrypoints exchange `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` for a runtime access token, then re-exec themselves under `infisical run` so secrets are injected at runtime. This lets you keep almost all application secrets out of Coolify env vars.
The wrappers pass the runtime token via `INFISICAL_TOKEN` environment variable (not `--token`) to avoid exposing it in `ps`/`docker top` command arguments.

| Variable | Default | Description |
|---|---|---|
| `INFISICAL_PROJECT_ID` | | Infisical project ID. |
| `INFISICAL_ENV` | `prod` | Infisical environment slug (e.g. `dev`, `staging`, `prod`). |
| `INFISICAL_PATH` | `/` | Secrets folder path. |
| `INFISICAL_CLIENT_ID` | | Universal Auth client ID (machine identity). |
| `INFISICAL_CLIENT_SECRET` | | Universal Auth client secret (machine identity). |
| `INFISICAL_API_URL` | | Infisical API base URL (required for self-hosted / non-US). Example: `https://infisical.example.com/api`. |

### Deepgram (audio transcription, optional)

| Variable | Description |
|---|---|
| `DEEPGRAM_API_KEY` | Deepgram API key. Enables audio transcription via Nova 3 model. |

### Amazon Bedrock (uses AWS credential chain)

| Variable | Default | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | | AWS access key. Both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` required. |
| `AWS_SECRET_ACCESS_KEY` | | AWS secret key. |
| `AWS_REGION` | `us-east-1` | AWS region for Bedrock runtime endpoint. |
| `AWS_SESSION_TOKEN` | | Optional session token for temporary credentials. |
| `BEDROCK_PROVIDER_FILTER` | `anthropic` | Filter Bedrock model discovery by provider. |

### Ollama (local models, no API key needed)

| Variable | Description |
|---|---|
| `OLLAMA_BASE_URL` | Ollama server URL (e.g. `http://host.docker.internal:11434`). Enables Ollama provider when set. |

### Model selection

| Variable | Description |
|---|---|
| `OPENCLAW_PRIMARY_MODEL` | Override the default primary model. Format: `provider/model-id` (e.g. `openai/gpt-5.3-codex-spark`). |

### Memory search

By default, the baked `openclaw.custom.json` config uses Gemini for memory search with `gemini-embedding-2-preview` and resolves the embedding key from `GEMINI_API_KEY`. This improves recall for memory spread across many Markdown files and works with the standard Coolify + Infisical runtime injection used by this image.

| Variable | Description |
|---|---|
| `OPENCLAW_MEMORY_SEARCH_MODEL` | Override the default memory embedding model. Defaults to `gemini-embedding-2-preview`. |
| `OPENCLAW_MEMORY_SEARCH_OUTPUT_DIMENSIONALITY` | Optional Gemini embedding-2 output size override. Valid values: `768`, `1536`, `3072`. Changing this forces a full memory reindex. |

### HTTP Basic Auth (recommended)

| Variable | Default | Description |
|---|---|---|
| `OPENCLAW_BASIC_AUTH` | `auto` | Basic auth mode for nginx. `auto` = enable only when `AUTH_PASSWORD` is set. `on` = require basic auth (errors if `AUTH_PASSWORD` unset). `off` = disable basic auth even if `AUTH_PASSWORD` is set (for Cloudflare Access, etc.). |
| `AUTH_PASSWORD` | *(none)* | Basic auth password. Effective when `OPENCLAW_BASIC_AUTH=auto` (and set) or `OPENCLAW_BASIC_AUTH=on`. |
| `AUTH_USERNAME` | `admin` | Username for basic auth. |

If you run `OPENCLAW_BASIC_AUTH=off`, ensure origin access is restricted (for example Cloudflare Tunnel or firewall allowlist). Cloudflare Access alone does not protect direct-origin requests if the origin IP is publicly reachable.

### Gateway

| Variable | Default | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | *(required)* | Bearer token for gateway auth. Use Infisical/runtime env injection. This image does not persist the token to `openclaw.json`. |
| `OPENCLAW_EXEC_SOCKET_TOKEN` | *(optional)* | If set, seeds `<STATE_DIR>/exec-approvals.json` socket token on startup (recommended via Infisical). |
| `OPENCLAW_EXEC_APPROVALS_SOCKET_PATH` | `<STATE_DIR>/exec-approvals.sock` | Optional override for exec-approvals Unix socket path when using `OPENCLAW_EXEC_SOCKET_TOKEN`. |
| `OPENCLAW_GATEWAY_PORT` | `18789` | Internal port the gateway binds to. |
| `OPENCLAW_GATEWAY_BIND` | `loopback` | Gateway bind mode. `loopback` = 127.0.0.1 only (nginx proxies LAN traffic). `lan` = 0.0.0.0 (direct access, bypasses nginx auth). Also: `tailnet`, `auto`, `custom`. **Guardrail:** this image refuses `lan` unless `OPENCLAW_ALLOW_LAN_BIND=true` is set. |
| `OPENCLAW_ALLOW_LAN_BIND` | *(none)* | Set to `true` to allow `OPENCLAW_GATEWAY_BIND=lan`. Unsafe unless you know your ingress/firewall setup. |
| `OPENCLAW_STATE_DIR` | `/data/.openclaw` | Persistent state directory. Mount a volume here. |
| `OPENCLAW_WORKSPACE_DIR` | `/data/workspace` | Workspace directory for openclaw projects. |
| `OPENCLAW_CONFIG_PATH` | `<STATE_DIR>/openclaw.json` | Override path to the config file. |
| `OPENCLAW_CUSTOM_CONFIG` | `/app/config/openclaw.json` | Path to a user-provided custom JSON config. Env vars override on top. |

### Hooks (webhook automation, optional)

| Variable | Default | Description |
|---|---|---|
| `HOOKS_ENABLED` | | Set to `true` to enable the webhook hooks endpoint. |
| `HOOKS_TOKEN` | | Shared secret for hook request auth. Required by openclaw when hooks are enabled. |
| `HOOKS_PATH` | `/hooks` | Path prefix for hook endpoints (`/hooks/wake`, `/hooks/agent`, etc.). |

When hooks are enabled and `AUTH_PASSWORD` is set, the hooks path automatically bypasses HTTP basic auth. Openclaw validates requests using the hook token instead. Docs: https://docs.openclaw.ai/automation/webhook

#### Putting `/hooks/*` live later (Cloudflare Access + service tokens)

If you protect the UI with Cloudflare Access (human login), hooks typically need a different auth path so automations can call them without an interactive login.

Recommended approach:

1. Cloudflare Access Application for `https://<host>/*` (human login policy for the UI).
2. Cloudflare Access Application for `https://<host>/hooks/*` with a **Service Auth** policy (machine callers use a Cloudflare service token).
3. Enable hooks in OpenClaw and store the hook token as a secret:
   - `HOOKS_ENABLED=true`, `HOOKS_PATH=/hooks`, `HOOKS_TOKEN=<long-random>`
   - Prefer keeping `HOOKS_TOKEN` in Infisical and injecting it at runtime (via `INFISICAL_*`), not in Coolify plaintext env vars.

Auth expectations:

- Cloudflare Access service token: caller sends `CF-Access-Client-Id` and `CF-Access-Client-Secret`
- OpenClaw hook token: caller sends either:
  - `x-openclaw-token: <HOOKS_TOKEN>` (recommended), or
  - `Authorization: Bearer <HOOKS_TOKEN>`

Example (wake the agent via hooks, using both Cloudflare Access + OpenClaw hook token):

```bash
curl -X POST "https://<host>/hooks/wake" \
  -H "content-type: application/json" \
  -H "CF-Access-Client-Id: <cf_client_id>" \
  -H "CF-Access-Client-Secret: <cf_client_secret>" \
  -H "x-openclaw-token: <hooks_token>" \
  --data '{"text":"ping","mode":"now"}'
```

If your webhook source cannot send custom headers:

- Keep `/hooks/*` behind Cloudflare Access Service Auth, and
- Add a small proxy (Cloudflare Worker, serverless function, or internal gateway) that receives the external webhook and forwards it to OpenClaw while adding `x-openclaw-token`.

### Browser tool (remote CDP sidecar, optional)

| Variable | Default | Description |
|---|---|---|
| `BROWSER_CDP_URL` | | Remote CDP URL pointing to the sidecar's CDP proxy (for this stack: `http://browser:9223`). Required to activate browser tool. |
| `BROWSER_EVALUATE_ENABLED` | `false` | Allow JavaScript evaluation in page context via browser actions. |
| `BROWSER_SNAPSHOT_MODE` | | Default snapshot mode (e.g. `efficient`). |
| `BROWSER_REMOTE_TIMEOUT_MS` | `1500` | HTTP timeout in ms for remote CDP connection. |
| `BROWSER_REMOTE_HANDSHAKE_TIMEOUT_MS` | `3000` | WebSocket handshake timeout in ms for remote CDP. |
| `BROWSER_DEFAULT_PROFILE` | | Override the default browser profile name. |

This repo uses `coollabsio/openclaw-browser:latest`, which exposes an nginx CDP proxy on `:9223` and forwards internally to Chromium on `:9222`. OpenClaw should talk to `9223`, not `9222`. Docs: https://docs.openclaw.ai/tools/browser

#### Browser login (VNC sidecar)

For sites requiring authentication, use `kasmweb/chrome` so you can log in manually via a web-based desktop. Openclaw reuses the authenticated session via CDP.

1. Open `https://<host>:6901` — full Chrome desktop via noVNC
2. Navigate to the target site, log in manually (handles captchas, 2FA, OAuth)
3. Sessions persist in a mounted volume across restarts
4. Set `BROWSER_CDP_URL=http://browser:9223` — OpenClaw connects through the sidecar's CDP proxy

Mount a persistent volume at the sidecar's profile directory (`/home/kasm-user`) so cookies and sessions survive container restarts. The sidecar may need `CHROME_ARGS=--remote-debugging-port=9222 --remote-debugging-address=0.0.0.0` to expose CDP. Docs: https://docs.openclaw.ai/tools/browser-login

#### Coolify self-heal for wedged CDP

If the browser sidecar becomes `unhealthy`, restarting only the OpenClaw gateway is not enough. The common failure mode is that Chromium inside the `browser` container stops responding on `127.0.0.1:9222`, while nginx on `:9223` stays up and keeps timing out.

Recommended Coolify scheduled task:

- Name: `Recycle browser sidecar if CDP wedges`
- Container: `browser`
- Frequency: `*/10 * * * *`
- Timeout: `120`
- Command:

```sh
sh -lc 'pid="$(pgrep -o chromium || true)"; fd=0; [ -n "$pid" ] && fd="$(ls "/proc/$pid/fd" 2>/dev/null | wc -l | tr -d " ")"; stuck="$(ps -eo args | grep "[c]url .*127.0.0.1:9223/json/version" | wc -l | tr -d " ")"; if ! curl -fsS --connect-timeout 1 --max-time 3 http://127.0.0.1:9223/json/version >/dev/null || [ "${fd:-0}" -ge 7000 ] || [ "${stuck:-0}" -ge 8 ]; then echo "recycling browser: fd=$fd stuck=$stuck"; kill -TERM 1; else echo "browser ok: fd=$fd stuck=$stuck"; fi'
```

This is intentionally conditional. It recycles the sidecar only when CDP is already failing or Chromium is approaching FD saturation, instead of killing the browser at a fixed time every night.

### Camofox Browser (Camoufox anti-detection sidecar + OpenClaw plugin, optional)

Run the `camofox` service in the same `docker-compose.yml` as OpenClaw without publishing its port (internal-only), and configure the `camofox-browser` OpenClaw plugin to talk to it.

You can provide the shared cookie-import key via `CAMOFOX_API_KEY` directly, or store it in Infisical (recommended) and let both the `openclaw` and `camofox` containers inject it at runtime using `INFISICAL_*`.

| Variable | Default | Description |
|---|---|---|
| `CAMOFOX_BROWSER_URL` | | Camofox server URL (e.g. `http://camofox:9377`). When set, the container entrypoint installs/enables `@askjo/camofox-browser`. |
| `CAMOFOX_BROWSER_AUTOSTART` | `false` | Set to `false` when the server runs as its own container (plugin must not spawn it). |
| `CAMOFOX_PLUGIN_VERSION` | `latest` | OpenClaw plugin version selector for `@askjo/camofox-browser`. `latest` auto-updates on startup; set an exact version to pin. |
| `CAMOFOX_BROWSER_NPM_TAG` | `latest` | Build arg for the `camofox` sidecar image (`@askjo/camofox-browser@<tag|version>`). Keep `latest` to follow upstream releases automatically. |
| `CAMOFOX_BROWSER_PORT` | | Server port (used only if `CAMOFOX_BROWSER_URL` is not set). |
| `CAMOFOX_API_KEY` | | Shared API key required to enable cookie import on the server. Must be set on both `openclaw` and `camofox` services. |
| `SERVICE_BASE64_64_CAMOFOX` | | Optional alias: if `CAMOFOX_API_KEY` is unset and this is set, the entrypoints map it to `CAMOFOX_API_KEY`. |

### Channels (optional)

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | | Telegram bot token from BotFather. |
| `TELEGRAM_DM_POLICY` | `pairing` | DM access policy: `pairing`, `allowlist`, `open`, or `disabled`. |
| `TELEGRAM_ALLOW_FROM` | | Comma-separated allowlist of user IDs/usernames. Required when `dmPolicy=allowlist` or `dmPolicy=open` (use `*`). |
| `TELEGRAM_GROUP_POLICY` | `allowlist` | Group access policy: `open`, `allowlist`, or `disabled`. |
| `TELEGRAM_GROUP_ALLOW_FROM` | | Comma-separated group sender allowlist (user IDs/usernames). |
| `TELEGRAM_REPLY_TO_MODE` | `first` | Reply threading: `off`, `first`, or `all`. |
| `TELEGRAM_CHUNK_MODE` | `length` | Outbound split mode: `length` or `newline` (paragraph boundaries). |
| `TELEGRAM_TEXT_CHUNK_LIMIT` | `4000` | Outbound text chunk size (chars). |
| `TELEGRAM_STREAM_MODE` | `partial` | Draft streaming: `off`, `partial`, or `block`. |
| `TELEGRAM_LINK_PREVIEW` | `true` | Toggle link previews for outbound messages. |
| `TELEGRAM_MEDIA_MAX_MB` | `5` | Inbound/outbound media cap in MB. |
| `TELEGRAM_REACTION_NOTIFICATIONS` | `own` | Which reactions trigger events: `off`, `own`, or `all`. |
| `TELEGRAM_REACTION_LEVEL` | `minimal` | Agent reaction capability: `off`, `ack`, `minimal`, or `extensive`. |
| `TELEGRAM_INLINE_BUTTONS` | `allowlist` | Inline button capability: `off`, `dm`, `group`, `all`, or `allowlist`. |
| `TELEGRAM_ACTIONS_REACTIONS` | `true` | Gate Telegram tool reactions. |
| `TELEGRAM_ACTIONS_STICKER` | `false` | Gate Telegram sticker send/search actions. |
| `TELEGRAM_PROXY` | | Proxy URL for Bot API calls (SOCKS/HTTP). |
| `TELEGRAM_WEBHOOK_URL` | | Enable webhook mode with public endpoint URL. |
| `TELEGRAM_WEBHOOK_SECRET` | | Webhook secret (optional). |
| `TELEGRAM_WEBHOOK_PATH` | `/telegram-webhook` | Local webhook path for incoming updates. |
| `TELEGRAM_MESSAGE_PREFIX` | | Prefix prepended to inbound messages. |
`TELEGRAM_BOT_TOKEN` is still required when you want to activate/configure the default top-level Telegram account from env alone. If Telegram is already configured via custom JSON or persisted state (for example multi-account setups), `TELEGRAM_WEBHOOK_URL`, `TELEGRAM_WEBHOOK_SECRET`, and `TELEGRAM_WEBHOOK_PATH` still override the top-level Telegram webhook settings.

When Telegram webhook mode is enabled, `entrypoint.sh` reads the resolved `channels.telegram.webhookPath` from `openclaw.json` after `configure.js` runs and generates an nginx `location` block that bypasses HTTP basic auth for that path. Telegram/OpenClaw handle webhook authentication via the webhook secret instead.

| `DISCORD_BOT_TOKEN` | | Discord bot token. Enable MESSAGE CONTENT INTENT in Discord Developer Portal. |
| `DISCORD_DM_POLICY` | `pairing` | DM access policy: `pairing`, `allowlist`, `open`, or `disabled`. |
| `DISCORD_DM_ALLOW_FROM` | | Comma-separated user IDs/names for DM allowlist. |
| `DISCORD_GROUP_POLICY` | `allowlist` | Guild access policy: `open`, `allowlist`, or `disabled`. |
| `DISCORD_REPLY_TO_MODE` | `off` | Reply threading: `off`, `first`, or `all`. |
| `DISCORD_CHUNK_MODE` | `length` | Outbound split mode: `length` or `newline`. |
| `DISCORD_TEXT_CHUNK_LIMIT` | `2000` | Outbound text chunk size (chars). |
| `DISCORD_MAX_LINES_PER_MESSAGE` | `17` | Soft line limit per message. |
| `DISCORD_MEDIA_MAX_MB` | `8` | Inbound media cap in MB. |
| `DISCORD_HISTORY_LIMIT` | `20` | Recent guild messages for context. |
| `DISCORD_DM_HISTORY_LIMIT` | | DM history limit per user. |
| `DISCORD_REACTION_NOTIFICATIONS` | `own` | Which reactions trigger events: `off`, `own`, `all`, or `allowlist`. |
| `DISCORD_ALLOW_BOTS` | `false` | Process messages from other bots. |
| `DISCORD_MESSAGE_PREFIX` | | Prefix prepended to inbound messages. |
| `DISCORD_ACTIONS_REACTIONS` | `true` | Gate reaction actions. |
| `DISCORD_ACTIONS_STICKERS` | `true` | Gate sticker send. |
| `DISCORD_ACTIONS_EMOJI_UPLOADS` | `true` | Gate emoji uploads. |
| `DISCORD_ACTIONS_STICKER_UPLOADS` | `true` | Gate sticker uploads. |
| `DISCORD_ACTIONS_POLLS` | `true` | Gate poll creation. |
| `DISCORD_ACTIONS_PERMISSIONS` | `true` | Gate channel permission edits. |
| `DISCORD_ACTIONS_MESSAGES` | `true` | Gate message read/send/edit/delete. |
| `DISCORD_ACTIONS_THREADS` | `true` | Gate thread operations. |
| `DISCORD_ACTIONS_PINS` | `true` | Gate pin/unpin operations. |
| `DISCORD_ACTIONS_SEARCH` | `true` | Gate message search. |
| `DISCORD_ACTIONS_MEMBER_INFO` | `true` | Gate member lookup. |
| `DISCORD_ACTIONS_ROLE_INFO` | `true` | Gate role list. |
| `DISCORD_ACTIONS_CHANNEL_INFO` | `true` | Gate channel info. |
| `DISCORD_ACTIONS_CHANNELS` | `true` | Gate channel management. |
| `DISCORD_ACTIONS_VOICE_STATUS` | `true` | Gate voice state. |
| `DISCORD_ACTIONS_EVENTS` | `true` | Gate event management. |
| `DISCORD_ACTIONS_ROLES` | `false` | Gate role add/remove. |
| `DISCORD_ACTIONS_MODERATION` | `false` | Gate timeout/kick/ban. |
| `SLACK_BOT_TOKEN` | | Slack bot token (`xoxb-...`). Both bot + app token required for Slack. |
| `SLACK_APP_TOKEN` | | Slack app token (`xapp-...`). |
| `SLACK_USER_TOKEN` | | Slack user token (`xoxp-...`). Optional, for user-level API calls. |
| `SLACK_SIGNING_SECRET` | | Signing secret for HTTP mode verification. |
| `SLACK_MODE` | `socket` | Connection mode: `socket` or `http`. |
| `SLACK_WEBHOOK_PATH` | `/slack/events` | Webhook path for HTTP mode. |
| `SLACK_DM_POLICY` | `pairing` | DM access policy: `pairing` or `open`. |
| `SLACK_DM_ALLOW_FROM` | | Comma-separated user IDs/handles for DM allowlist. |
| `SLACK_GROUP_POLICY` | `open` | Channel access policy: `open`, `allowlist`, or `disabled`. |
| `SLACK_REPLY_TO_MODE` | `off` | Reply threading: `off`, `first`, or `all`. |
| `SLACK_REACTION_NOTIFICATIONS` | `own` | Which reactions trigger events: `off`, `own`, or `all`. |
| `SLACK_CHUNK_MODE` | `newline` | Outbound split mode. |
| `SLACK_TEXT_CHUNK_LIMIT` | `4000` | Outbound text chunk size (chars). |
| `SLACK_MEDIA_MAX_MB` | `20` | Inbound media cap in MB. |
| `SLACK_HISTORY_LIMIT` | `50` | Recent channel messages for context. |
| `SLACK_ALLOW_BOTS` | `false` | Process messages from other bots. |
| `SLACK_MESSAGE_PREFIX` | | Prefix prepended to inbound messages. |
| `SLACK_ACTIONS_REACTIONS` | `true` | Gate reaction actions. |
| `SLACK_ACTIONS_MESSAGES` | `true` | Gate message read/send/edit/delete. |
| `SLACK_ACTIONS_PINS` | `true` | Gate pin/unpin operations. |
| `SLACK_ACTIONS_MEMBER_INFO` | `true` | Gate member lookup. |
| `SLACK_ACTIONS_EMOJI_LIST` | `true` | Gate emoji list retrieval. |
| `WHATSAPP_ENABLED` | | Set to `true` to enable WhatsApp channel. Uses QR/pairing code auth at runtime. |
| `WHATSAPP_DM_POLICY` | `pairing` | DM access policy: `pairing`, `allowlist`, `open`, or `disabled`. |
| `WHATSAPP_ALLOW_FROM` | | Comma-separated E.164 phone numbers for DM allowlist. |
| `WHATSAPP_SELF_CHAT_MODE` | `false` | Enable when running on your personal WhatsApp number. |
| `WHATSAPP_GROUP_POLICY` | `allowlist` | Group access policy: `open`, `disabled`, or `allowlist`. |
| `WHATSAPP_GROUP_ALLOW_FROM` | | Comma-separated E.164 phone numbers for group sender allowlist. |
| `WHATSAPP_MEDIA_MAX_MB` | `50` | Inbound media save cap in MB. |
| `WHATSAPP_HISTORY_LIMIT` | `50` | Recent unprocessed messages inserted for group context. |
| `WHATSAPP_DM_HISTORY_LIMIT` | | DM history limit in user turns. |
| `WHATSAPP_SEND_READ_RECEIPTS` | `true` | Send read receipts (blue ticks) on message receipt. |
| `WHATSAPP_ACK_REACTION_EMOJI` | | Emoji sent on message receipt (e.g. `👀`). Omit to disable. |
| `WHATSAPP_ACK_REACTION_DIRECT` | `true` | Send ack reactions in DM chats. |
| `WHATSAPP_ACK_REACTION_GROUP` | `mentions` | Group reaction behavior: `always`, `mentions`, or `never`. |
| `WHATSAPP_MESSAGE_PREFIX` | | Inbound message prefix. |
| `WHATSAPP_ACTIONS_REACTIONS` | `true` | Enable WhatsApp tool reactions. |

If a channel env var is removed, that channel is cleaned from config on next start. WhatsApp env vars fully overwrite any existing WhatsApp config (no merge with custom JSON).

### Provider overrides (optional)

| Variable | Description |
|---|---|
| `AI_GATEWAY_BASE_URL` | Custom base URL for AI gateway (e.g. Cloudflare AI Gateway). Applied to the matching provider based on URL suffix. |
| `ANTHROPIC_BASE_URL` | Override Anthropic API base URL specifically. |
| `MOONSHOT_BASE_URL` | Override Moonshot API base URL. Default: `https://api.moonshot.ai/v1`. |
| `KIMI_BASE_URL` | Override Kimi Coding API base URL. Default: `https://api.moonshot.ai/anthropic`. |

### Extra system packages (optional)

| Variable | Description |
|---|---|
| `OPENCLAW_DOCKER_APT_PACKAGES` | Space-separated list of apt packages to install at container startup (e.g. `ffmpeg build-essential`). Packages are installed before openclaw starts. Reinstalled on each container restart. |

### Port

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | External port nginx listens on. |


### Coolify-specific (auto-set by Coolify)

| Variable | Description |
|---|---|
| `COOLIFY_FQDN` | Public FQDN assigned by Coolify. |
| `COOLIFY_URL` | Coolify dashboard URL. |
| `COOLIFY_BRANCH` | Git branch deployed. |

## Custom JSON config (Docker mount / baked config)

For settings too complex for flat env vars (e.g. `channels.*.groups`, agent defaults, plugin config), mount a custom JSON file into the container:

```bash
docker run -v ./my-openclaw.json:/app/config/openclaw.json ...
```

In this repo's `docker-compose.yml`, `openclaw.custom.json` is baked into the image at build time (no single-file bind mount).

Override the mount path with `OPENCLAW_CUSTOM_CONFIG` env var if needed.

**3-tier merge order** (configure.js):

1. Custom JSON (`/app/config/openclaw.json`) — base layer
2. Persisted state (`<STATE_DIR>/openclaw.json`) — preserves runtime changes from previous runs
3. Env vars — applied on top, always win

Arrays are replaced, not concatenated. Provider API keys are always read from env vars, never from JSON.

**Note:** WhatsApp is a special case — when `WHATSAPP_ENABLED=true`, env vars fully overwrite the WhatsApp config block (custom JSON whatsapp keys are discarded). For all other channels, custom JSON keys are preserved and env vars merge on top.

## Notes

- Openclaw uses CalVer: `v2026.1.29` (roughly daily releases). Detected via GitHub Releases API.
- Using native `ubuntu-24.04-arm` runners for arm64 builds (same pattern as coollabsio/pocketbase).
- Config is environment-driven: set env vars → restart container → config updates automatically.
- `Dockerfile` preinstalls `mcporter`, `agent-browser`, `summarize`, `yt-dlp`, `codex`, `viral-app`, `whisper`, `nano-pdf`, `scrapling` (with optional extras and `scrapling install`), `himalaya`, `bvg`, and `goplaces` so matching built-in skills are not blocked by missing binaries.
- The `summarize` skill from [`steipete/clawdis`](https://skills.sh/steipete/clawdis/summarize) is also baked into the image so it is available by default to OpenClaw, with a matching Codex copy for in-container coding-agent workflows.
- `bvg` is installed from `https://github.com/feliche93/bvg-cli` at image build time via GitHub tarball (`BVGCLI_REPO`, `BVGCLI_REF` build args), so no manual repo clone step is required.
- `viral-app` is installed from `https://github.com/fmd-labs/viral-app-skills` at image build time via GitHub tarball (`VIRAL_APP_SKILLS_REPO`, `VIRAL_APP_SKILLS_REF` build args), so agents can call it directly from the container.
