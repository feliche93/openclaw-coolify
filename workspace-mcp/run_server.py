import os
import logging
import html
from urllib.parse import urlencode

# Workspace MCP internals (packaged)
from auth.oauth_config import reload_oauth_config, is_stateless_mode
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

# OAuth 2.1 discovery/proxy endpoints (not exposed by the stock `workspace-mcp` CLI)
from auth.oauth_common_handlers import (
    handle_oauth_authorize,
    handle_proxy_token_exchange,
    handle_oauth_protected_resource,
    handle_oauth_authorization_server,
    handle_oauth_client_config,
    handle_oauth_register,
)
from starlette.requests import Request
from starlette.responses import HTMLResponse, RedirectResponse

# Reuse upstream callback logic, but present an access-token handoff page.
from auth.google_auth import handle_auth_callback, check_client_secrets
from auth.oauth21_session_store import get_oauth21_session_store
from auth.scopes import get_current_scopes
from auth.oauth_config import get_oauth_config


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

    # Credentials dir check (skip in stateless mode)
    if not is_stateless_mode():
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

    # Add OAuth 2.1 discovery/proxy endpoints expected by MCP OAuth flows.
    @server.custom_route("/.well-known/oauth-protected-resource", methods=["GET", "OPTIONS"])
    async def oauth_protected_resource(request: Request):
        return await handle_oauth_protected_resource(request)

    @server.custom_route("/.well-known/oauth-authorization-server", methods=["GET", "OPTIONS"])
    async def oauth_authorization_server(request: Request):
        return await handle_oauth_authorization_server(request)

    @server.custom_route("/.well-known/oauth-client", methods=["GET", "OPTIONS"])
    async def oauth_client_config(request: Request):
        return await handle_oauth_client_config(request)

    @server.custom_route("/oauth2/authorize-handoff", methods=["GET"])
    async def oauth_authorize_handoff(request: Request):
        """
        Convenience endpoint for humans: open in a browser, finish Google consent,
        land on /oauth2callback-handoff which shows the short-lived access token.

        We avoid /oauth2/authorize because FastMCP's RemoteAuthProvider may already
        register it; route ordering would make overriding unreliable.
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

    @server.custom_route("/oauth2/token", methods=["POST", "OPTIONS"])
    async def oauth_token(request: Request):
        return await handle_proxy_token_exchange(request)

    @server.custom_route("/oauth2/register", methods=["POST", "OPTIONS"])
    async def oauth_register(request: Request):
        return await handle_oauth_register(request)

    @server.custom_route("/oauth2callback-handoff", methods=["GET"])
    async def oauth2_callback_handoff(request: Request) -> HTMLResponse:
        """
        Browser-based auth flow that returns an access token for pasting into an agent.

        This is intentionally *not* the default /oauth2callback route shipped in the
        upstream server to avoid route conflicts and keep the stock UX intact.
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

        # Store in OAuth 2.1 session store so /mcp can accept it.
        try:
            store = get_oauth21_session_store()
            store.store_session(
                user_email=verified_user_id,
                access_token=credentials.token,
                refresh_token=credentials.refresh_token,
                token_uri=credentials.token_uri,
                client_id=credentials.client_id,
                client_secret=credentials.client_secret,
                scopes=credentials.scopes,
                expiry=credentials.expiry,
                session_id=f"google-{state}",
                mcp_session_id=None,
            )
        except Exception as e:
            logger.error(f"Failed to store OAuth 2.1 session for handoff: {e}", exc_info=True)

        # Display only the *access token*; do not display refresh_token.
        token = credentials.token or ""
        token_safe = html.escape(token)
        user_safe = html.escape(verified_user_id or "")
        mcp_url = f"{base_url}/mcp"

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
    <h1>Workspace MCP access token</h1>
    <div class="note">Authenticated as <b>{user_safe}</b>.</div>
    <div class="warn">
      <b>Security:</b> This is a short-lived Google access token. Share it only with trusted agents.
      When it expires, re-run the browser flow to get a new token.
    </div>
    <h2 style="margin-top: 18px; font-size: 16px;">Token</h2>
    <div class="row">
      <button onclick="navigator.clipboard.writeText(document.getElementById('tok').innerText)">Copy token</button>
      <button onclick="navigator.clipboard.writeText(document.getElementById('curl').innerText)">Copy curl</button>
    </div>
    <pre id="tok">{token_safe}</pre>
    <h2 style="margin-top: 18px; font-size: 16px;">Test</h2>
    <pre id="curl">curl -H 'Authorization: Bearer {token_safe}' '{html.escape(mcp_url)}'</pre>
    <div class="small">MCP endpoint: <code>{html.escape(mcp_url)}</code></div>
  </body>
</html>
"""
        return HTMLResponse(content=content, status_code=200)

    port = int(os.getenv("PORT", os.getenv("WORKSPACE_MCP_PORT", "8000")))
    server.run(transport="streamable-http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
