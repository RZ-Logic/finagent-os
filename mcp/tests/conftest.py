"""Offline fixtures for the FinAgent OS MCP server tests.

Every HTTP call goes through an httpx.MockTransport router keyed by method
and path. The router records each request, returns canned PostgREST and Auth
responses, and can raise httpx.ReadTimeout or httpx.ConnectError on chosen
routes. Nothing here contacts a network.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable, Optional, Union

import httpx
import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

from fastmcp import Client  # noqa: E402

import server  # noqa: E402
from fao_auth import UserSession  # noqa: E402
from fao_rest import InvokeClient, RestClient  # noqa: E402

BASE_URL = "http://127.0.0.1:54321"
PUBLIC_KEY = "public-key-for-tests"
WEBHOOK_HOST = "n8n-hook.test.invalid"
WEBHOOK_PATH = "/webhook/fao-recon-invoke"
WEBHOOK_URL = f"https://{WEBHOOK_HOST}{WEBHOOK_PATH}"
INVOKE_KEY = "invoke-header-value-7f3a9c"
READER_EMAIL = "mcp.reader@finagent-os.demo"
READER_PASSWORD = "reader-password-q8w7e6"
READER_TOKEN = "reader-access-token-aaa111"
INVOKER_EMAIL = "Aisha.Okonkwo@finagent-os.demo"
INVOKER_PASSWORD = "invoker-password-z9x8c7"
INVOKER_TOKEN = "invoker-access-token-bbb222"
RUN_TOKEN = "R" * 43
CORRELATION_ID = "0b6f4c1e-2a7d-4e59-9a51-6f0f3c2d1e00"
FIXED_NOW = 1_794_000_000.0  # fixed clock for idempotency buckets and deadlines

# Every value that must never appear in a tool result.
SECRETS = (
    BASE_URL,
    "127.0.0.1",
    WEBHOOK_URL,
    WEBHOOK_HOST,
    WEBHOOK_PATH,
    INVOKE_KEY,
    "X-FAO-Invoke-Key",
    READER_PASSWORD,
    READER_TOKEN,
    INVOKER_PASSWORD,
    INVOKER_TOKEN,
    RUN_TOKEN,
    PUBLIC_KEY,
)

Handler = Union[httpx.Response, Callable[[httpx.Request], httpx.Response], type, BaseException]


def envelope(**fields: Any) -> dict:
    base = {"ok": True, "code": "OK", "http_status": 200, "message": "OK", "ref": None}
    base.update(fields)
    return base


def refusal(code: str, http_status: int, message: str, ref: Optional[int] = 7) -> dict:
    return {"ok": False, "code": code, "http_status": http_status, "message": message, "ref": ref}


class Router:
    """httpx.MockTransport handler keyed by (method, path); records requests."""

    def __init__(self) -> None:
        self.routes: dict = {}
        self.requests: list[httpx.Request] = []

    def add(self, method: str, path: str, handler: Handler) -> None:
        self.routes[(method.upper(), path)] = handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        handler = self.routes.get((request.method, request.url.path))
        if handler is None:
            return httpx.Response(404, json={"message": "no route"})
        if isinstance(handler, type) and issubclass(handler, BaseException):
            raise handler("simulated failure", request=request)
        if isinstance(handler, BaseException):
            raise handler
        if callable(handler) and not isinstance(handler, httpx.Response):
            return handler(request)
        return handler

    def calls(self, path: str, method: Optional[str] = None) -> list[httpx.Request]:
        return [
            r
            for r in self.requests
            if r.url.path == path and (method is None or r.method == method.upper())
        ]

    def body(self, request: httpx.Request) -> Any:
        return json.loads(request.content.decode("utf-8"))


def auth_handler(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content.decode("utf-8"))
    if request.url.params.get("grant_type") != "password":
        return httpx.Response(400, json={"error": "unsupported_grant_type"})
    if body.get("email") == READER_EMAIL and body.get("password") == READER_PASSWORD:
        token = READER_TOKEN
    elif body.get("email") == INVOKER_EMAIL and body.get("password") == INVOKER_PASSWORD:
        token = INVOKER_TOKEN
    else:
        return httpx.Response(400, json={"error": "invalid_grant"})
    return httpx.Response(
        200,
        json={
            "access_token": token,
            "token_type": "bearer",
            "expires_in": 3600,
            "expires_at": int(FIXED_NOW) + 3600,
            "refresh_token": "refresh-unused",
        },
    )


def table_response(rows: list, content_range: Optional[str] = None, status: int = 200):
    headers = {}
    if content_range is not None:
        headers["content-range"] = content_range
    elif rows:
        headers["content-range"] = f"0-{len(rows) - 1}/{len(rows)}"
    else:
        headers["content-range"] = "*/0"
    return httpx.Response(status, json=rows, headers=headers)


@pytest.fixture
def router() -> Router:
    r = Router()
    r.add("POST", "/auth/v1/token", auth_handler)
    r.add(
        "POST",
        "/rest/v1/rpc/fao_whoami",
        httpx.Response(
            200,
            json=envelope(
                user_id="11111111-1111-4111-8111-111111111111",
                is_owner=False,
                name=None,
                email=None,
                active=None,
                aal="aal1",
                roles=[{"role": "reader", "agent_id": None}],
            ),
        ),
    )
    return r


class Harness:
    def __init__(self, router: Router, mcp: Any) -> None:
        self.router = router
        self.mcp = mcp

    async def call(self, name: str, args: Optional[dict] = None) -> dict:
        async with Client(self.mcp) as client:
            result = await client.call_tool(name, args or {})
        data = result.structured_content
        assert isinstance(data, dict)
        return data


def make_server(router: Router, *, invoker: bool = True, clock: Callable[[], float] = lambda: FIXED_NOW):
    transport = httpx.MockTransport(router)
    rest = RestClient(BASE_URL, PUBLIC_KEY, transport=transport)
    reader = UserSession(READER_EMAIL, READER_PASSWORD, rest, clock=clock)
    invoker_session = (
        UserSession(INVOKER_EMAIL, INVOKER_PASSWORD, rest, clock=clock) if invoker else None
    )
    invoke_client = InvokeClient(WEBHOOK_URL, INVOKE_KEY, transport=transport)
    return server.build_server(
        rest, reader, lambda: invoker_session, invoke_client, clock=clock
    )


@pytest.fixture
def harness(router: Router) -> Harness:
    return Harness(router, make_server(router))


def assert_no_secrets(result: Any) -> None:
    text = json.dumps(result, default=str)
    for secret in SECRETS:
        assert secret not in text, f"result leaks a protected value: {secret[:6]}..."
