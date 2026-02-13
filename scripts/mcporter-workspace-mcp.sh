#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper for mcporter against the deployed Workspace MCP server.
#
# Requirements (one-time):
# 1) In Google Cloud Console for the OAuth client used by workspace-mcp, add:
#    http://127.0.0.1:42297/callback
# 2) Then run:
#    ./scripts/mcporter-workspace-mcp.sh auth
#
# Common usage:
#   ./scripts/mcporter-workspace-mcp.sh auth
#   ./scripts/mcporter-workspace-mcp.sh list --schema
#   ./scripts/mcporter-workspace-mcp.sh call workspace-mcp.tools/list

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/config/mcporter.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Missing config: $CONFIG_PATH" >&2
  exit 1
fi

exec npx -y mcporter@0.7.3 --config "$CONFIG_PATH" "$@"

