FROM python:3.12-slim

WORKDIR /app

# Keep image minimal but usable (certs + curl helpful for debugging)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Install the Google Workspace MCP server (PyPI: workspace-mcp)
# Pin for reproducible behavior.
RUN pip install --no-cache-dir "workspace-mcp==1.4.7"

ENV WORKSPACE_MCP_PORT=8000
ENV PORT=8000

EXPOSE 8000

# Add a small shim that exposes OAuth discovery endpoints (not wired into the stock CLI).
COPY run_server.py /app/run_server.py

CMD ["python3", "/app/run_server.py"]
