#!/usr/bin/env bash
# Build openclaw Docker images locally.
#
# Usage:
#   ./scripts/build.sh                  # build both base + final
#   ./scripts/build.sh base             # build base only
#   ./scripts/build.sh final            # build final only from OPENCLAW_GIT_REF
#   ./scripts/build.sh custom           # build the self-contained OpenClaw image
#   ./scripts/build.sh browser          # build browser sidecar only
#   OPENCLAW_GIT_REF=v2026.1.29 ./scripts/build.sh  # pin to a specific version
#   OPENCLAW_GIT_REF=latest-release ./scripts/build.sh custom

set -euo pipefail

OPENCLAW_GIT_REF="${OPENCLAW_GIT_REF:-latest-release}"
BASE_TAG="openclaw-base:local"
FINAL_TAG="openclaw:local"
CUSTOM_TAG="openclaw:local"
BROWSER_TAG="openclaw-browser:local"
AGENT_BROWSER_VERSION="${AGENT_BROWSER_VERSION:-latest}"
FIRECRAWL_CLI_VERSION="${FIRECRAWL_CLI_VERSION:-latest}"
DSPY_VERSION="${DSPY_VERSION:-latest}"
SUMMARIZE_VERSION="${SUMMARIZE_VERSION:-latest}"
TARGET="${1:-all}"

resolve_latest_release() {
  curl -fsSL https://api.github.com/repos/openclaw/openclaw/releases/latest \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);const t=String(j.tag_name||"").replace(/^v/,"");if(!t){process.exit(2);}process.stdout.write(t);});'
}

if [ "${OPENCLAW_GIT_REF}" = "latest-release" ]; then
  LATEST_RELEASE="$(resolve_latest_release)"
  OPENCLAW_GIT_REF="v${LATEST_RELEASE}"
  echo "==> Resolved latest OpenClaw release: ${OPENCLAW_GIT_REF}"
fi

build_base() {
  echo "==> Building base image (ref: ${OPENCLAW_GIT_REF})..."
  docker build \
    -f Dockerfile.base \
    --build-arg "OPENCLAW_GIT_REF=${OPENCLAW_GIT_REF}" \
    -t "${BASE_TAG}" \
    .
  echo "==> Base image built: ${BASE_TAG}"
}

build_final() {
  echo "==> Building final image (ref: ${OPENCLAW_GIT_REF})..."
  docker build \
    -f Dockerfile \
    --build-arg "OPENCLAW_GIT_REF=${OPENCLAW_GIT_REF}" \
    --build-arg "AGENT_BROWSER_VERSION=${AGENT_BROWSER_VERSION}" \
    --build-arg "FIRECRAWL_CLI_VERSION=${FIRECRAWL_CLI_VERSION}" \
    --build-arg "DSPY_VERSION=${DSPY_VERSION}" \
    --build-arg "SUMMARIZE_VERSION=${SUMMARIZE_VERSION}" \
    -t "${FINAL_TAG}" \
    .
  echo "==> Final image built: ${FINAL_TAG}"
}

build_custom() {
  echo "==> Building OpenClaw image from source (ref: ${OPENCLAW_GIT_REF})..."
  docker build \
    -f Dockerfile \
    --build-arg "OPENCLAW_GIT_REF=${OPENCLAW_GIT_REF}" \
    --build-arg "AGENT_BROWSER_VERSION=${AGENT_BROWSER_VERSION}" \
    --build-arg "FIRECRAWL_CLI_VERSION=${FIRECRAWL_CLI_VERSION}" \
    --build-arg "DSPY_VERSION=${DSPY_VERSION}" \
    --build-arg "SUMMARIZE_VERSION=${SUMMARIZE_VERSION}" \
    -t "${CUSTOM_TAG}" \
    .
  echo "==> Image built: ${CUSTOM_TAG}"
}

build_browser() {
  echo "==> Building browser sidecar image..."
  docker build \
    -f Dockerfile.browser \
    -t "${BROWSER_TAG}" \
    .
  echo "==> Browser image built: ${BROWSER_TAG}"
}

case "${TARGET}" in
  base)
    build_base
    ;;
  final)
    build_final
    ;;
  custom)
    build_custom
    ;;
  browser)
    build_browser
    ;;
  all)
    build_base
    build_final
    build_browser
    ;;
  *)
    echo "Usage: $0 [base|final|custom|browser|all]"
    exit 1
    ;;
esac

echo ""
echo "Done. Run with:"
if [ "${TARGET}" = "custom" ]; then
  echo "  docker run -e OPENCLAW_GATEWAY_TOKEN=\$(openssl rand -hex 32) -e ANTHROPIC_API_KEY=sk-... -e AUTH_PASSWORD=secret -p 8080:8080 ${CUSTOM_TAG}"
else
  echo "  docker run -e OPENCLAW_GATEWAY_TOKEN=\$(openssl rand -hex 32) -e ANTHROPIC_API_KEY=sk-... -e AUTH_PASSWORD=secret -p 8080:8080 ${FINAL_TAG}"
fi
