FROM node:22-slim

# Infisical CLI (optional; used for runtime secret injection via INFISICAL_TOKEN)
ARG INFISICAL_VERSION=0.43.48
# BuildKit sets TARGETARCH (amd64/arm64). Default to amd64 naming.
ARG TARGETARCH
# npm dist-tag/version for the Camofox server package.
# Keep as "latest" to track upstream releases automatically.
ARG CAMOFOX_BROWSER_NPM_TAG=latest

# Install dependencies for Camoufox (Firefox-based)
RUN apt-get update && apt-get install -y \
    # Firefox dependencies
    libgtk-3-0 \
    libdbus-glib-1-2 \
    libxt6 \
    libasound2 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    # Fonts
    fonts-liberation \
    fonts-noto-color-emoji \
    fontconfig \
    # Utils
    ca-certificates \
    curl \
    python3-minimal \
    tar \
    unzip \
    yt-dlp \
    && rm -rf /var/lib/apt/lists/*

# Install Infisical CLI (for optional runtime env injection)
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    [ -z "$arch" ] && arch="$(uname -m)" || true; \
    case "$arch" in \
      amd64|x86_64) go_arch="amd64" ;; \
      arm64|aarch64) go_arch="arm64" ;; \
      *) echo "Unsupported architecture for infisical: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/Infisical/cli/releases/download/v${INFISICAL_VERSION}/cli_${INFISICAL_VERSION}_linux_${go_arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/infisical.tgz; \
    tar -xzf /tmp/infisical.tgz -C /tmp infisical; \
    install -m 0755 /tmp/infisical /usr/local/bin/infisical; \
    rm -f /tmp/infisical.tgz /tmp/infisical; \
    infisical --version

WORKDIR /app

# Install the latest published Camofox server package at build time
# and copy its runtime files into /app.
RUN set -eux; \
    npm install -g "@askjo/camofox-browser@${CAMOFOX_BROWSER_NPM_TAG}"; \
    PKG_DIR="$(npm root -g)/@askjo/camofox-browser"; \
    cp -a "${PKG_DIR}/." /app/; \
    node -e "const j=require('/app/package.json'); console.log('[build] camofox package: ' + j.name + '@' + j.version);"

COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENV NODE_ENV=production
ENV CAMOFOX_PORT=9377

EXPOSE 9377

ENTRYPOINT ["./entrypoint.sh"]
CMD ["node", "server.js"]
