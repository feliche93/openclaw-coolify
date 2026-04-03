# Build OpenClaw from source so Coolify deployments do not depend on
# prebuilt coollabsio/openclaw:* tags.
FROM node:22-bookworm AS openclaw-build

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Use `main` for fastest access to upstream changes, or pin to a release tag
# (for example: v2026.2.22) for reproducible builds.
# You can also pass OPENCLAW_GIT_REF=latest-release to resolve the newest
# published tag at build time.
ARG OPENCLAW_GIT_REF=latest-release
# Cache-busting marker: when latest stable release metadata changes upstream,
# this URL payload changes and invalidates subsequent build layers.
ADD https://api.github.com/repos/openclaw/openclaw/releases/latest /tmp/openclaw-latest-release.json
RUN set -eux; \
  release_marker="$(sha256sum /tmp/openclaw-latest-release.json | awk '{print $1}')"; \
  echo "OpenClaw latest-release marker: ${release_marker}"; \
  ref="${OPENCLAW_GIT_REF}"; \
  if [ "${ref}" = "latest-release" ]; then \
    ref="v$(node -e 'fetch("https://api.github.com/repos/openclaw/openclaw/releases/latest",{headers:{"User-Agent":"openclaw-coolify"}}).then(r=>r.json()).then(j=>{const t=String(j.tag_name||"").replace(/^v/,"");if(!t)process.exit(2);process.stdout.write(t);}).catch(e=>{console.error(e);process.exit(1);})')"; \
  fi; \
  echo "Building OpenClaw from ref: ${ref}"; \
  git clone --depth 1 --branch "${ref}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages using workspace protocol.
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm

ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nginx \
    apache2-utils \
    ca-certificates \
    curl \
    bzip2 \
    ffmpeg \
    yt-dlp \
    python3 \
    python3-pip \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default

# Install under /opt/openclaw/app so that ../../ from dist/ lands at /opt/openclaw
# which is where we place the symlinks. This avoids polluting / with project files.
COPY --from=openclaw-build /openclaw /opt/openclaw/app

# Runtime container should be an immutable artifact, not a mutable git checkout.
# This prevents "dirty tree" drift in production when dependencies normalize files.
RUN rm -rf /opt/openclaw/app/.git

# Compiled JS in dist/ resolves ../../ relative to import.meta.url.
# Files in /opt/openclaw/app/dist/ resolve ../../ to /opt/openclaw/.
# Symlink docs/assets/package.json there so the paths work.
RUN ln -s /opt/openclaw/app/docs /opt/openclaw/docs \
  && ln -s /opt/openclaw/app/assets /opt/openclaw/assets \
  && ln -s /opt/openclaw/app/package.json /opt/openclaw/package.json

# restic (for volume backups to R2 via Coolify Scheduled Tasks)
ARG RESTIC_VERSION=latest
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) restic_arch="amd64" ;; \
    aarch64|arm64) restic_arch="arm64" ;; \
    *) echo "Unsupported architecture for restic: $arch" >&2; exit 1 ;; \
  esac; \
  version="${RESTIC_VERSION}"; \
  if [ "${version}" = "latest" ]; then \
    version="$(node -e 'fetch("https://api.github.com/repos/restic/restic/releases/latest",{headers:{"User-Agent":"openclaw-coolify"}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.tag_name||"").replace(/^v/,""))).catch(e=>{console.error(e);process.exit(1);})')"; \
  fi; \
  if [ -z "$version" ]; then echo "Failed to resolve latest restic version" >&2; exit 1; fi; \
  url="https://github.com/restic/restic/releases/download/v${version}/restic_${version}_linux_${restic_arch}.bz2"; \
  curl -fsSL "$url" -o /tmp/restic.bz2; \
  bunzip2 /tmp/restic.bz2; \
  install -m 0755 /tmp/restic /usr/local/bin/restic; \
  rm -f /tmp/restic; \
  restic version

# GitHub CLI
# Note: intentionally unpinned so each image build installs the latest release.
ARG GH_VERSION=latest
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) gh_arch="amd64" ;; \
    aarch64|arm64) gh_arch="arm64" ;; \
    *) echo "Unsupported architecture for gh: $arch" >&2; exit 1 ;; \
  esac; \
  version="${GH_VERSION}"; \
  if [ "${version}" = "latest" ]; then \
    version="$(node -e 'fetch("https://api.github.com/repos/cli/cli/releases/latest",{headers:{"User-Agent":"openclaw-coolify"}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.tag_name||"").replace(/^v/,""))).catch(e=>{console.error(e);process.exit(1);})')"; \
  fi; \
  if [ -z "$version" ]; then echo "Failed to resolve latest gh version" >&2; exit 1; fi; \
  url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${gh_arch}.tar.gz"; \
  curl -fsSL "$url" -o /tmp/gh.tgz; \
  tar -xzf /tmp/gh.tgz -C /tmp; \
  install -m 0755 "/tmp/gh_${version}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
  rm -rf /tmp/gh.tgz "/tmp/gh_${version}_linux_${gh_arch}"; \
  gh --version | head -n1

# Infisical CLI (used for runtime secret injection via INFISICAL_TOKEN)
# Defaults to the newest release that ships the expected Linux archive.
ARG INFISICAL_VERSION=latest
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) go_arch="amd64" ;; \
    aarch64|arm64) go_arch="arm64" ;; \
    *) echo "Unsupported architecture for infisical: $arch" >&2; exit 1 ;; \
  esac; \
  version="${INFISICAL_VERSION}"; \
  if [ "${version}" = "latest" ]; then \
    version="$(GO_ARCH="$go_arch" node -e 'const goArch = process.env.GO_ARCH; const expectedAsset = (version) => `cli_${version}_linux_${goArch}.tar.gz`; fetch("https://api.github.com/repos/Infisical/cli/releases?per_page=30", { headers: { "User-Agent": "openclaw-coolify" } }).then(async (r) => { if (!r.ok) { throw new Error(`GitHub API returned ${r.status}`); } return r.json(); }).then((releases) => { if (!Array.isArray(releases)) { throw new Error("Unexpected GitHub releases response"); } for (const release of releases) { if (!release || release.draft || release.prerelease) continue; const version = String(release.tag_name || "").replace(/^v/, ""); const assets = Array.isArray(release.assets) ? release.assets : []; if (version && assets.some((asset) => asset?.name === expectedAsset(version))) { process.stdout.write(version); return; } } throw new Error(`No Infisical release found with asset ${expectedAsset("<version>")}`); }).catch((e) => { console.error(e); process.exit(1); });')"; \
  fi; \
  if [ -z "$version" ]; then echo "Failed to resolve latest Infisical CLI version" >&2; exit 1; fi; \
  url="https://github.com/Infisical/cli/releases/download/v${version}/cli_${version}_linux_${go_arch}.tar.gz"; \
  curl -fsSL "$url" -o /tmp/infisical.tgz; \
  tar -xzf /tmp/infisical.tgz -C /tmp infisical; \
  install -m 0755 /tmp/infisical /usr/local/bin/infisical; \
  rm -f /tmp/infisical.tgz /tmp/infisical; \
  infisical --version

# OpenClaw's built-in skill installer expects `bun` to be available
# (e.g. "Install mcporter (bun)"). The runtime stage does not ship bun,
# so we add it explicitly for Coolify deployments.
RUN curl -fsSL https://bun.sh/install | bash \
  && ln -sf /root/.bun/bin/bun /usr/local/bin/bun \
  && ln -sf /root/.bun/bin/bunx /usr/local/bin/bunx

# Google Workspace CLI (gog)
ARG GOGCLI_VERSION=latest
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) go_arch="amd64" ;; \
    aarch64|arm64) go_arch="arm64" ;; \
    *) echo "Unsupported architecture for gogcli: $arch" >&2; exit 1 ;; \
  esac; \
  version="${GOGCLI_VERSION}"; \
  if [ "${version}" = "latest" ]; then \
    version="$(node -e 'fetch("https://api.github.com/repos/steipete/gogcli/releases/latest",{headers:{"User-Agent":"openclaw-coolify"}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.tag_name||"").replace(/^v/,""))).catch(e=>{console.error(e);process.exit(1);})')"; \
  fi; \
  if [ -z "$version" ]; then echo "Failed to resolve latest gog version" >&2; exit 1; fi; \
  url="https://github.com/steipete/gogcli/releases/download/v${version}/gogcli_${version}_linux_${go_arch}.tar.gz"; \
  curl -fsSL "$url" -o /tmp/gogcli.tgz; \
  tar -xzf /tmp/gogcli.tgz -C /tmp; \
  install -m 0755 /tmp/gog /usr/local/bin/gog; \
  rm -f /tmp/gogcli.tgz /tmp/gog; \
  gog --version

# Provide `mcporter` CLI inside the container so agents can use it and it survives restarts.
RUN npm i -g mcporter@0.7.3

# Provide `agent-browser` CLI for browser automation workflows from inside the
# openclaw container (typically used with remote CDP sidecars).
ARG AGENT_BROWSER_VERSION=latest
RUN set -eux; \
  if [ "${AGENT_BROWSER_VERSION}" = "latest" ]; then \
    npm i -g agent-browser; \
  else \
    npm i -g "agent-browser@${AGENT_BROWSER_VERSION}"; \
  fi; \
  agent-browser >/dev/null

# Provide the `firecrawl` CLI so the Firecrawl skill can be installed later
# without rebuilding the image again just to satisfy the binary dependency.
ARG FIRECRAWL_CLI_VERSION=latest
RUN set -eux; \
  if [ "${FIRECRAWL_CLI_VERSION}" = "latest" ]; then \
    npm i -g firecrawl-cli; \
  else \
    npm i -g "firecrawl-cli@${FIRECRAWL_CLI_VERSION}"; \
  fi; \
  firecrawl --version

# Provide the `summarize` CLI for link-to-summary workflows.
ARG SUMMARIZE_VERSION=latest
RUN set -eux; \
  if [ "${SUMMARIZE_VERSION}" = "latest" ]; then \
    npm i -g @steipete/summarize; \
  else \
    npm i -g "@steipete/summarize@${SUMMARIZE_VERSION}"; \
  fi; \
  summarize --help >/dev/null

# Vendor the `summarize` skill into the container's global agent skill dirs.
# For this image, OpenClaw is the primary target; Codex is included because it
# is also installed in the runtime image and may be invoked from the container.
RUN set -eux; \
  tmpdir="$(mktemp -d)"; \
  curl -fsSL https://codeload.github.com/steipete/clawdis/tar.gz/main | tar -xzf - -C "$tmpdir"; \
  skill_src="$(find "$tmpdir" -path '*/skills/summarize' -type d | head -n1)"; \
  [ -n "$skill_src" ]; \
  for rel in \
    ".codex/skills/summarize" \
    ".openclaw/skills/summarize" \
  ; do \
    dest="/root/$rel"; \
    mkdir -p "$dest"; \
    cp -R "$skill_src"/. "$dest"/; \
  done; \
  rm -rf "$tmpdir"

# OpenClaw ships a bundled "coding-agent" skill that can drive Codex CLI, but the
# upstream image doesn't include the `codex` binary. Install it so the skill is
# eligible inside Coolify deployments.
#
# Note: intentionally unpinned so each image build installs the latest Codex CLI.
RUN npm i -g @openai/codex \
  && codex --version

# Provide the `viral-app` CLI for viral.app API workflows.
# Installed from GitHub source tarball so the wrapper can keep its local
# OpenAPI + restish runtime files inside the image.
ARG VIRAL_APP_SKILLS_REPO=fmd-labs/viral-app-skills
ARG VIRAL_APP_SKILLS_REF=main
RUN set -eux; \
  rm -rf /opt/viral-app-skills; \
  mkdir -p /opt/viral-app-skills; \
  curl -fsSL "https://codeload.github.com/${VIRAL_APP_SKILLS_REPO}/tar.gz/${VIRAL_APP_SKILLS_REF}" \
    | tar -xz -C /opt/viral-app-skills --strip-components=1; \
  VIRAL_APP_BIN_DIR=/usr/local/bin /opt/viral-app-skills/scripts/install-global.sh; \
  viral-app --help >/dev/null

# Provide the `whisper` CLI for the built-in OpenAI Whisper skill.
# This is a heavy dependency (pulls torch CPU wheels), but it makes the
# "Missing: bin:whisper" requirement pass inside the container.
RUN python3 -m venv /opt/whisper-venv \
  && /opt/whisper-venv/bin/pip install --no-cache-dir --prefer-binary openai-whisper \
  && ln -sf /opt/whisper-venv/bin/whisper /usr/local/bin/whisper

# Provide the `nano-pdf` CLI for the built-in nano-pdf skill.
RUN python3 -m venv /opt/nano-pdf-venv \
  && /opt/nano-pdf-venv/bin/pip install --no-cache-dir --prefer-binary nano-pdf \
  && ln -sf /opt/nano-pdf-venv/bin/nano-pdf /usr/local/bin/nano-pdf \
  && nano-pdf --help >/dev/null

# Provide the `scrapling` CLI with all optional extras and browser dependencies
# so Scrapling fetchers/shell/MCP features can run inside OpenClaw.
RUN python3 -m venv /opt/scrapling-venv \
  && /opt/scrapling-venv/bin/pip install --no-cache-dir --prefer-binary "scrapling[all]" \
  && ln -sf /opt/scrapling-venv/bin/scrapling /usr/local/bin/scrapling \
  && scrapling install \
  && scrapling --help >/dev/null

# Provide the `dspy` Python framework for agentic workflows that import it.
# Install into the default Python environment so future skills/scripts can use
# plain `python3 -c 'import dspy'` without a dedicated wrapper.
ARG DSPY_VERSION=latest
RUN set -eux; \
  if [ "${DSPY_VERSION}" = "latest" ]; then \
    python3 -m pip install --no-cache-dir --prefer-binary --break-system-packages dspy; \
  else \
    python3 -m pip install --no-cache-dir --prefer-binary --break-system-packages "dspy==${DSPY_VERSION}"; \
  fi; \
  python3 - <<'PY'
import dspy
print(dspy.__version__)
PY

# Provide the `himalaya` CLI for the built-in email skill.
# Note: intentionally unpinned so each image build installs the latest release.
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) himalaya_arch="x86_64" ;; \
    aarch64|arm64) himalaya_arch="aarch64" ;; \
    *) echo "Unsupported architecture for himalaya: $arch" >&2; exit 1 ;; \
  esac; \
  version="$(node -e 'fetch("https://api.github.com/repos/pimalaya/himalaya/releases/latest",{headers:{"User-Agent":"openclaw-coolify"}}).then(r=>r.json()).then(j=>process.stdout.write(String(j.tag_name||"").replace(/^v/,""))).catch(e=>{console.error(e);process.exit(1);})')"; \
  if [ -z "$version" ]; then echo "Failed to resolve latest Himalaya version" >&2; exit 1; fi; \
  url="https://github.com/pimalaya/himalaya/releases/download/v${version}/himalaya.${himalaya_arch}-linux.tgz"; \
  curl -fsSL "$url" -o /tmp/himalaya.tgz; \
  tar -xzf /tmp/himalaya.tgz -C /tmp himalaya; \
  install -m 0755 /tmp/himalaya /usr/local/bin/himalaya; \
  rm -f /tmp/himalaya.tgz /tmp/himalaya; \
  himalaya --version

# Provide the `bvg` CLI for BVG transport API workflows.
# Installed directly from GitHub source tarball (no manual clone needed).
ARG BVGCLI_REPO=feliche93/bvg-cli
ARG BVGCLI_REF=main
RUN set -eux; \
  rm -rf /opt/bvg-cli; \
  mkdir -p /opt/bvg-cli; \
  curl -fsSL "https://codeload.github.com/${BVGCLI_REPO}/tar.gz/${BVGCLI_REF}" \
    | tar -xz -C /opt/bvg-cli --strip-components=1; \
  BVG_BIN_DIR=/usr/local/bin /opt/bvg-cli/scripts/install-global.sh; \
  bvg --help >/dev/null

# Provide the `goplaces` CLI for the built-in Google Places skill.
# Pin version for reproducible Coolify builds; override with --build-arg if needed.
ARG GOPLACES_VERSION=0.3.0
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
    x86_64) go_arch="amd64" ;; \
    aarch64|arm64) go_arch="arm64" ;; \
    *) echo "Unsupported architecture for goplaces: $arch" >&2; exit 1 ;; \
  esac; \
  url="https://github.com/steipete/goplaces/releases/download/v${GOPLACES_VERSION}/goplaces_${GOPLACES_VERSION}_linux_${go_arch}.tar.gz"; \
  curl -fsSL "$url" -o /tmp/goplaces.tgz; \
  tar -xzf /tmp/goplaces.tgz -C /tmp goplaces; \
  install -m 0755 /tmp/goplaces /usr/local/bin/goplaces; \
  rm -f /tmp/goplaces.tgz /tmp/goplaces; \
  goplaces --help >/dev/null

# Coolify deployment cannot reliably bind-mount individual files from the repo
# into the container. Bake the updated scripts into a derived image instead.
COPY openclaw.custom.json /app/config/openclaw.json
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
COPY scripts/configure.js /app/scripts/configure.js
COPY scripts/openclaw-wrapper.sh /app/scripts/openclaw-wrapper.sh
COPY scripts/redeploy-if-new-openclaw-release.sh /app/scripts/redeploy-if-new-openclaw-release.sh
COPY scripts/backup-openclaw-data-to-r2.sh /app/scripts/backup-openclaw-data-to-r2.sh
COPY scripts/restore-openclaw-data-from-r2.sh /app/scripts/restore-openclaw-data-from-r2.sh
COPY config/mcporter.container.json /app/config/mcporter.json

RUN chmod +x /app/scripts/entrypoint.sh \
  /app/scripts/openclaw-wrapper.sh \
  /app/scripts/redeploy-if-new-openclaw-release.sh \
  /app/scripts/backup-openclaw-data-to-r2.sh \
  /app/scripts/restore-openclaw-data-from-r2.sh \
  && ln -sf /app/scripts/openclaw-wrapper.sh /usr/local/bin/openclaw

ENV PORT=8080
EXPOSE 8080

# Ensure Docker exposes a health status for Coolify to pick up.
# /healthz is served by the nginx proxy generated by entrypoint.sh.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=12 \
  CMD curl -fsS "http://localhost:${PORT:-8080}/healthz" >/dev/null || exit 1

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
