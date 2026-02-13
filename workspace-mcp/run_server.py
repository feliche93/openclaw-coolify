import os
import logging
import html
from urllib.parse import urlencode

# Workspace MCP internals (packaged)
from auth.oauth_config import reload_oauth_config
from core.log_formatter import configure_file_logging
from core.utils import check_credentials_directory_permissions
from core.server import server, set_transport_mode, configure_server_for_http
from core.tool_tier_loader import resolve_tools_from_tier
from core.tool_registry import (
    set_enabled_tools as set_enabled_tool_names,
    wrap_server_tool_method,
    filter_server_tools,
)
from auth.scopes import set_enabled_tools as set_enabled_services_for_scopes

from starlette.requests import Request
from starlette.responses import HTMLResponse, RedirectResponse

# Reuse upstream callback logic, but present a simple "credentials saved" page.
from auth.google_auth import handle_auth_callback, check_client_secrets
from auth.google_auth import get_credential_store
from auth.scopes import get_current_scopes
from auth.oauth_config import get_oauth_config
from auth.credential_store import get_credential_store


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("workspace-mcp.run_server")


def _split_services(raw: str) -> list[str]:
    # Accept space or comma separated.
    parts = [p.strip() for p in raw.replace(",", " ").split()]
    return [p for p in parts if p]


def main() -> None:
    # Match upstream behavior: read env after container starts.
    reload_oauth_config()
    configure_file_logging()

    # This deployment is stateful (file-based credentials).
    check_credentials_directory_permissions()

    # Tool selection (env-driven)
    tool_tier = (os.getenv("TOOL_TIER") or "").strip() or None
    services_raw = (os.getenv("TOOLS") or "").strip()
    services_filter = _split_services(services_raw) if services_raw else None

    # Set transport + auth provider for HTTP
    set_transport_mode("streamable-http")
    configure_server_for_http()

    # Import tool modules to register decorators.
    tool_imports = {
        "gmail": lambda: __import__("gmail.gmail_tools"),
        "drive": lambda: __import__("gdrive.drive_tools"),
        "calendar": lambda: __import__("gcalendar.calendar_tools"),
        "docs": lambda: __import__("gdocs.docs_tools"),
        "sheets": lambda: __import__("gsheets.sheets_tools"),
        "chat": lambda: __import__("gchat.chat_tools"),
        "forms": lambda: __import__("gforms.forms_tools"),
        "slides": lambda: __import__("gslides.slides_tools"),
        "tasks": lambda: __import__("gtasks.tasks_tools"),
        "search": lambda: __import__("gsearch.search_tools"),
    }

    if tool_tier:
        tier_tools, suggested_services = resolve_tools_from_tier(tool_tier, services_filter)
        # Enable only the tier tools.
        set_enabled_tool_names(set(tier_tools))
        services_to_import = services_filter or suggested_services
    else:
        services_to_import = services_filter or list(tool_imports.keys())
        # No per-tool filtering when no tier specified.
        set_enabled_tool_names(None)

    wrap_server_tool_method(server)
    set_enabled_services_for_scopes(list(services_to_import))

    for s in services_to_import:
        if s in tool_imports:
            tool_imports[s]()

    filter_server_tools(server)

    @server.custom_route("/oauth2/authorize-handoff", methods=["GET"])
    async def oauth_authorize_handoff(request: Request):
        """
        Convenience endpoint for humans: open in a browser, finish Google consent,
        then land on /oauth2callback-handoff which persists refreshable credentials
        into the server's file-based credential store.

        This is NOT an MCP OAuth2.1 flow. It is only used to seed credentials so
        OpenClaw (and other internal callers) can invoke tools without bearer tokens.
        """
        params = dict(request.query_params)

        config = get_oauth_config()
        base_url = config.get_oauth_base_url()

        # Defaults (only if caller didn't provide them).
        if "client_id" not in params and os.getenv("GOOGLE_OAUTH_CLIENT_ID"):
            params["client_id"] = os.getenv("GOOGLE_OAUTH_CLIENT_ID")
        params["response_type"] = "code"
        params.setdefault("redirect_uri", f"{base_url}/oauth2callback-handoff")
        params.setdefault("access_type", "offline")
        params.setdefault("prompt", "consent")

        # Merge client scopes with scopes for enabled tools only.
        client_scopes = params.get("scope", "").split() if params.get("scope") else []
        enabled_tool_scopes = get_current_scopes()
        all_scopes = set(client_scopes) | set(enabled_tool_scopes)
        params["scope"] = " ".join(sorted(all_scopes))
        logger.info(f"OAuth handoff authorization: Requesting scopes: {params['scope']}")

        google_auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode(params)
        return RedirectResponse(url=google_auth_url, status_code=302)

    @server.custom_route("/oauth2callback-handoff", methods=["GET"])
    async def oauth2_callback_handoff(request: Request) -> HTMLResponse:
        """
        Browser-based auth flow that seeds refreshable credentials in the server's
        credential store and shows a short confirmation page.
        """
        state = request.query_params.get("state")
        code = request.query_params.get("code")
        error = request.query_params.get("error")

        if error:
            msg = f"Authentication failed: Google returned an error: {error}. State: {state}."
            logger.error(msg)
            return HTMLResponse(content=f"<pre>{html.escape(msg)}</pre>", status_code=400)

        if not code:
            msg = "Authentication failed: No authorization code received from Google."
            logger.error(msg)
            return HTMLResponse(content=f"<pre>{html.escape(msg)}</pre>", status_code=400)

        error_message = check_client_secrets()
        if error_message:
            return HTMLResponse(content=f"<pre>{html.escape(error_message)}</pre>", status_code=500)

        # IMPORTANT: redirect_uri must match what we used in /oauth2/authorize.
        config = get_oauth_config()
        base_url = config.get_oauth_base_url()
        redirect_uri = f"{base_url}/oauth2callback-handoff"

        try:
            verified_user_id, credentials = handle_auth_callback(
                scopes=get_current_scopes(),
                authorization_response=str(request.url),
                redirect_uri=redirect_uri,
                session_id=None,
            )
        except Exception as e:
            logger.error(f"Error processing OAuth callback handoff: {e}", exc_info=True)
            return HTMLResponse(content=f"<pre>{html.escape(str(e))}</pre>", status_code=500)

        # Also persist to the file-based credential store (refreshable) when enabled.
        # This enables "server-side" usage (e.g. OpenClaw calling workspace-mcp internally)
        # without requiring a per-request OAuth browser flow.
        try:
            cred_store = get_credential_store()
            ok = cred_store.store_credential(verified_user_id, credentials)
            if ok:
                logger.info(f"Saved Google credentials for {verified_user_id} (file store).")
            else:
                logger.error(f"Failed to save Google credentials for {verified_user_id} (file store).")
        except Exception as e:
            logger.error(f"Failed to persist Google credentials for handoff: {e}", exc_info=True)

        user_safe = html.escape(verified_user_id or "")
        proxied_mcp_url = f"{base_url}/mcp"
        internal_mcp_url = "http://workspace-mcp:8000/mcp"

        content = f"""<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Workspace MCP Token</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 18px; }}
      h1 {{ font-size: 22px; margin-bottom: 10px; }}
      .note {{ color: #444; margin: 10px 0 18px; }}
      .warn {{ background: #fff3cd; border: 1px solid #ffeeba; padding: 12px; border-radius: 8px; }}
      pre {{ background: #0b1020; color: #e6edf3; padding: 14px; border-radius: 10px; overflow-x: auto; }}
      code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }}
      .row {{ display: flex; gap: 10px; flex-wrap: wrap; margin: 12px 0; }}
      button {{ border: 1px solid #ddd; background: #fff; padding: 10px 14px; border-radius: 10px; cursor: pointer; }}
      button:hover {{ background: #f6f6f6; }}
      .small {{ font-size: 13px; color: #666; }}
    </style>
  </head>
  <body>
    <h1>Workspace MCP connected</h1>
    <div class="note">Authenticated as <b>{user_safe}</b>.</div>
    <div class="warn">
      <b>Success:</b> Credentials were saved on the server (refreshable). You can close this page.
    </div>
    <h2 style="margin-top: 18px; font-size: 16px;">Endpoints</h2>
    <div class="small">Proxied MCP endpoint (via OpenClaw nginx): <code>{html.escape(proxied_mcp_url)}</code></div>
    <div class="small">Internal MCP endpoint (Docker DNS): <code>{html.escape(internal_mcp_url)}</code></div>
  </body>
</html>
"""
        return HTMLResponse(content=content, status_code=200)

    @server.tool()
    async def list_google_accounts() -> list[str]:
        """
        List Google accounts that have stored credentials on this MCP server.

        Use this from OpenClaw to discover which `user_google_email` values are available.
        """
        try:
            store = get_credential_store()
            return store.list_users()
        except Exception as e:
            logger.error(f"Failed to list credentialed users: {e}", exc_info=True)
            return []

    port = int(os.getenv("PORT", os.getenv("WORKSPACE_MCP_PORT", "8000")))
    server.run(transport="streamable-http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
