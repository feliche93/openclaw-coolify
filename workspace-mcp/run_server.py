import os
import logging

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

    @server.custom_route("/oauth2/authorize", methods=["GET", "OPTIONS"])
    async def oauth_authorize(request: Request):
        return await handle_oauth_authorize(request)

    @server.custom_route("/oauth2/token", methods=["POST", "OPTIONS"])
    async def oauth_token(request: Request):
        return await handle_proxy_token_exchange(request)

    @server.custom_route("/oauth2/register", methods=["POST", "OPTIONS"])
    async def oauth_register(request: Request):
        return await handle_oauth_register(request)

    port = int(os.getenv("PORT", os.getenv("WORKSPACE_MCP_PORT", "8000")))
    server.run(transport="streamable-http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()

