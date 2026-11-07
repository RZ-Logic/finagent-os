"""
FinAgent OS: thin PostgREST and webhook clients on httpx.

FAO-GOV-003 (least privilege): the MCP server talks to Supabase only through
PostgREST and Auth with the public key plus a signed-in user's own access
token. No service key, no direct database connection.

Error contract: every failure raises FaoError(kind, http_status). The kind is
one of timeout, connect, http, bad_json (auth is used by fao_auth). str() and
repr() of a FaoError carry only the kind and the status, never a URL, host,
header, token or exception text, so a tool result built from one cannot leak
connection details to the MCP client.
"""
from __future__ import annotations

import re
from typing import Any, Mapping, Optional, Sequence, Tuple, Union

import httpx

DEFAULT_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
# The invoke webhook answers after the claim RPC, so it gets a longer read
# timeout than PostgREST reads.
DEFAULT_INVOKE_TIMEOUT = httpx.Timeout(30.0, connect=5.0)

ERROR_KINDS = ("timeout", "connect", "http", "bad_json", "auth")

_NAME_RE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
_CONTENT_RANGE_RE = re.compile(r"^\s*(?:(\d+)-(\d+)|\*)/(\d+|\*)\s*$")

Params = Union[Mapping[str, str], Sequence[Tuple[str, str]], None]


class FaoError(Exception):
    """Structured client failure. Holds no URL, host, header or token."""

    def __init__(
        self,
        kind: str,
        http_status: Optional[int] = None,
        *,
        after_send: bool = False,
    ) -> None:
        if kind not in ERROR_KINDS:
            kind = "connect"
        self.kind = kind
        self.http_status = http_status if isinstance(http_status, int) else None
        # True when the request may have reached the server before the
        # failure (read timeout, dropped connection). Used by invoke to report
        # an unknown outcome instead of a clean error.
        self.after_send = bool(after_send)
        super().__init__(self.kind, self.http_status)

    def __str__(self) -> str:
        if self.http_status is None:
            return f"FaoError {self.kind}"
        return f"FaoError {self.kind} (HTTP {self.http_status})"

    def __repr__(self) -> str:
        return f"FaoError(kind={self.kind!r}, http_status={self.http_status!r})"

    def as_result(self) -> dict:
        return {"status": "error", "kind": self.kind, "http_status": self.http_status}


def _check_base_url(value: str) -> str:
    if not isinstance(value, str) or not re.match(r"^https?://[^/\s]+", value):
        raise ValueError("base url must be an http or https URL")
    return value.rstrip("/")


def _check_name(name: str) -> str:
    # Table and function names are fixed in code; this guard keeps any
    # caller-supplied value out of the request path.
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise ValueError("invalid relation or function name")
    return name


def _parse_json(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        raise FaoError("bad_json", response.status_code) from None


def has_more_from_content_range(
    header: Optional[str], *, offset: int, limit: int, returned: int
) -> bool:
    """PostgREST Content-Range is `<start>-<end>/<total>` or `*/<total>`."""
    if header:
        m = _CONTENT_RANGE_RE.match(header)
        if m:
            end, total = m.group(2), m.group(3)
            if total != "*":
                total_n = int(total)
                if end is None:
                    return offset + returned < total_n
                return int(end) + 1 < total_n
    # No exact count: assume more when the page came back full.
    return returned >= limit


class RestClient:
    """PostgREST and Auth client for one Supabase project.

    Filter values always travel in the query string through httpx `params`,
    which encodes them; nothing caller-supplied is formatted into a path.
    """

    def __init__(
        self,
        base_url: str,
        public_key: str,
        transport: Optional[httpx.BaseTransport] = None,
        timeout: httpx.Timeout = DEFAULT_TIMEOUT,
    ) -> None:
        self._base = _check_base_url(base_url)
        if not isinstance(public_key, str) or not public_key:
            raise ValueError("public key is required")
        self._public_key = public_key
        self._client = httpx.Client(
            transport=transport, timeout=timeout, follow_redirects=False
        )

    def __repr__(self) -> str:
        return "RestClient()"

    def close(self) -> None:
        self._client.close()

    # -- transport --------------------------------------------------------

    def _headers(self, bearer: Optional[str]) -> dict:
        headers = {"apikey": self._public_key, "Accept": "application/json"}
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        return headers

    def _send(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        try:
            return self._client.request(method, url, **kwargs)
        except httpx.TimeoutException:
            raise FaoError("timeout") from None
        except (httpx.HTTPError, httpx.InvalidURL, httpx.StreamError):
            raise FaoError("connect") from None

    # -- PostgREST ----------------------------------------------------------

    def select(
        self,
        table: str,
        *,
        bearer: str,
        params: Params,
        limit: int,
        offset: int,
    ) -> Tuple[list, bool]:
        """GET /rest/v1/<table> with a Range page. Returns (rows, has_more)."""
        table = _check_name(table)
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
            raise ValueError("limit must be a positive int")
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
            raise ValueError("offset must be a non-negative int")
        headers = self._headers(bearer)
        headers["Range-Unit"] = "items"
        headers["Range"] = f"{offset}-{offset + limit - 1}"
        headers["Prefer"] = "count=exact"
        query = list(params.items()) if isinstance(params, Mapping) else list(params or [])
        response = self._send(
            "GET", f"{self._base}/rest/v1/{table}", params=query, headers=headers
        )
        if response.status_code == 416:
            # Offset past the end of the result set.
            return [], False
        if not 200 <= response.status_code < 300:
            raise FaoError("http", response.status_code)
        rows = _parse_json(response)
        if not isinstance(rows, list):
            raise FaoError("bad_json", response.status_code)
        has_more = has_more_from_content_range(
            response.headers.get("content-range"),
            offset=offset,
            limit=limit,
            returned=len(rows),
        )
        return rows, has_more

    def rpc(self, name: str, body: Mapping[str, Any], *, bearer: Optional[str]) -> dict:
        """POST /rest/v1/rpc/<name>. Returns the FinAgent result envelope.

        The envelope is returned for any HTTP status that carries one (the
        RPCs set 4xx statuses on refusals). Anything else raises FaoError.
        """
        name = _check_name(name)
        headers = self._headers(bearer)
        headers["Content-Type"] = "application/json"
        response = self._send(
            "POST", f"{self._base}/rest/v1/rpc/{name}", json=dict(body), headers=headers
        )
        try:
            payload = response.json()
        except ValueError:
            payload = None
        if (
            isinstance(payload, dict)
            and isinstance(payload.get("ok"), bool)
            and isinstance(payload.get("code"), str)
        ):
            return payload
        if 200 <= response.status_code < 300:
            raise FaoError("bad_json", response.status_code)
        raise FaoError("http", response.status_code)

    # -- Auth -----------------------------------------------------------------

    def password_grant(self, email: str, password: str) -> Tuple[int, Any]:
        """POST /auth/v1/token?grant_type=password. Returns (status, json or None)."""
        response = self._send(
            "POST",
            f"{self._base}/auth/v1/token",
            params=[("grant_type", "password")],
            json={"email": email, "password": password},
            headers={**self._headers(None), "Content-Type": "application/json"},
        )
        try:
            payload = response.json()
        except ValueError:
            payload = None
        return response.status_code, payload


# Failures that happen before any request bytes can reach the server.
_NOT_SENT = (
    httpx.ConnectError,
    httpx.ConnectTimeout,
    httpx.PoolTimeout,
    httpx.LocalProtocolError,
    httpx.UnsupportedProtocol,
)


class InvokeClient:
    """POSTs a run token to the n8n invoke webhook (2.11 contract).

    The URL and header value live only inside this object; neither appears in
    any error or return value.
    """

    HEADER = "X-FAO-Invoke-Key"

    def __init__(
        self,
        url: str,
        key: str,
        transport: Optional[httpx.BaseTransport] = None,
        timeout: httpx.Timeout = DEFAULT_INVOKE_TIMEOUT,
    ) -> None:
        _check_base_url(url)
        if not isinstance(key, str) or not key:
            raise ValueError("invoke key is required")
        self._url = url
        self._key = key
        self._client = httpx.Client(
            transport=transport, timeout=timeout, follow_redirects=False
        )

    def __repr__(self) -> str:
        return "InvokeClient()"

    def close(self) -> None:
        self._client.close()

    def post_run_token(self, run_token: str) -> Tuple[int, Any]:
        """Returns (status, json or None). Raises FaoError on transport failure.

        A failure after the request may have been delivered (read timeout,
        dropped connection) raises with after_send=True.
        """
        try:
            response = self._client.post(
                self._url,
                json={"run_token": run_token},
                headers={self.HEADER: self._key, "Content-Type": "application/json"},
            )
        except _NOT_SENT as exc:
            kind = "timeout" if isinstance(exc, httpx.TimeoutException) else "connect"
            raise FaoError(kind) from None
        except httpx.TimeoutException:
            raise FaoError("timeout", after_send=True) from None
        except (httpx.HTTPError, httpx.StreamError):
            raise FaoError("connect", after_send=True) from None
        except httpx.InvalidURL:
            raise FaoError("connect") from None
        try:
            payload = response.json()
        except ValueError:
            payload = None
        return response.status_code, payload
