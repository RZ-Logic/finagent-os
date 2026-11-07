"""fao_rest and fao_auth units: error text, envelope handling, token cache."""
from __future__ import annotations

import httpx
import pytest

from conftest import BASE_URL, PUBLIC_KEY, READER_EMAIL, READER_PASSWORD, READER_TOKEN, Router, envelope
from fao_auth import UserSession
from fao_rest import FaoError, InvokeClient, RestClient, has_more_from_content_range


def client(router: Router) -> RestClient:
    return RestClient(BASE_URL, PUBLIC_KEY, transport=httpx.MockTransport(router))


@pytest.mark.parametrize("kind", ["timeout", "connect", "http", "bad_json", "auth"])
def test_fao_error_text_has_kind_and_status_only(kind):
    err = FaoError(kind, 503)
    assert str(err) == f"FaoError {kind} (HTTP 503)"
    assert repr(err) == f"FaoError(kind={kind!r}, http_status=503)"
    assert err.as_result() == {"status": "error", "kind": kind, "http_status": 503}


def test_fao_error_unknown_kind_collapses_to_connect():
    assert FaoError("http://secret.example/").kind == "connect"


def test_transport_error_text_never_reaches_fao_error(router: Router):
    router.add("GET", "/rest/v1/shadow_ledger", httpx.ConnectError)
    with pytest.raises(FaoError) as exc:
        client(router).select("shadow_ledger", bearer="t", params=[], limit=1, offset=0)
    assert exc.value.kind == "connect"
    assert exc.value.__cause__ is None and exc.value.__suppress_context__
    assert "127.0.0.1" not in str(exc.value) and "127.0.0.1" not in repr(exc.value)


def test_rpc_returns_envelope_for_refusal_status(router: Router):
    body = {"ok": False, "code": "NOT_AUTHORISED", "http_status": 403, "message": "m", "ref": 4}
    router.add("POST", "/rest/v1/rpc/fao_hitl_get", httpx.Response(403, json=body))
    assert client(router).rpc("fao_hitl_get", {"p_hitl_id": "1"}, bearer="t") == body


def test_rpc_non_envelope_error_raises_http(router: Router):
    router.add("POST", "/rest/v1/rpc/fao_x", httpx.Response(404, json={"code": "PGRST202"}))
    with pytest.raises(FaoError) as exc:
        client(router).rpc("fao_x", {}, bearer="t")
    assert (exc.value.kind, exc.value.http_status) == ("http", 404)


def test_rpc_non_envelope_success_raises_bad_json(router: Router):
    router.add("POST", "/rest/v1/rpc/fao_x", httpx.Response(200, json=[1, 2]))
    with pytest.raises(FaoError) as exc:
        client(router).rpc("fao_x", {}, bearer="t")
    assert exc.value.kind == "bad_json"


@pytest.mark.parametrize("name", ["shadow_ledger?select=*", "../auth", "Shadow", "a b", ""])
def test_names_are_never_formatted_from_input(router: Router, name):
    with pytest.raises(ValueError):
        client(router).select(name, bearer="t", params=[], limit=1, offset=0)
    with pytest.raises(ValueError):
        client(router).rpc(name, {}, bearer="t")
    assert router.requests == []


def test_select_sends_range_and_count(router: Router):
    router.add(
        "GET",
        "/rest/v1/agent_registry",
        httpx.Response(206, json=[{}], headers={"content-range": "5-5/9"}),
    )
    rows, more = client(router).select(
        "agent_registry", bearer="tok", params=[("status", "eq.ACTIVE")], limit=1, offset=5
    )
    assert rows == [{}] and more is True
    (req,) = router.requests
    assert req.headers["range"] == "5-5" and req.headers["prefer"] == "count=exact"
    assert req.headers["authorization"] == "Bearer tok" and req.headers["apikey"] == PUBLIC_KEY


def test_content_range_helper():
    assert has_more_from_content_range("*/10", offset=0, limit=5, returned=0) is True
    assert has_more_from_content_range("*/0", offset=0, limit=5, returned=0) is False
    assert has_more_from_content_range(None, offset=0, limit=5, returned=5) is True
    assert has_more_from_content_range("garbage", offset=0, limit=5, returned=2) is False


def test_session_caches_until_60_seconds_before_expiry(router: Router):
    clock = {"t": 1000.0}
    router.add(
        "POST",
        "/auth/v1/token",
        httpx.Response(200, json={"access_token": READER_TOKEN, "expires_at": 1000 + 3600}),
    )
    session = UserSession(READER_EMAIL, READER_PASSWORD, client(router), clock=lambda: clock["t"])
    assert session.bearer() == READER_TOKEN
    clock["t"] = 1000 + 3600 - 61
    session.bearer()
    assert len(router.calls("/auth/v1/token")) == 1
    clock["t"] = 1000 + 3600 - 60
    session.bearer()
    assert len(router.calls("/auth/v1/token")) == 2
    (first, _) = router.calls("/auth/v1/token")
    assert first.url.params["grant_type"] == "password"
    assert router.body(first) == {"email": READER_EMAIL, "password": READER_PASSWORD}


def test_session_uses_expires_in_when_no_expires_at(router: Router):
    clock = {"t": 50.0}
    router.add("POST", "/auth/v1/token", httpx.Response(200, json={"access_token": "a", "expires_in": 120}))
    session = UserSession("u@x", "p", client(router), clock=lambda: clock["t"])
    session.bearer()
    clock["t"] = 50 + 59
    session.bearer()
    assert len(router.calls("/auth/v1/token")) == 1


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(400, json={"error": "invalid_grant"}),
        httpx.Response(200, json={"no_token": True}),
        httpx.Response(200, text="not json"),
    ],
)
def test_session_refusal_raises_auth(router: Router, response):
    router.add("POST", "/auth/v1/token", response)
    session = UserSession("u@x", "secret-pass", client(router))
    with pytest.raises(FaoError) as exc:
        session.bearer()
    assert exc.value.kind == "auth" and exc.value.http_status == response.status_code
    assert "secret-pass" not in repr(session) and "secret-pass" not in str(exc.value)


def test_invoke_client_requires_url_and_key():
    with pytest.raises(ValueError):
        InvokeClient("not a url", "k")
    with pytest.raises(ValueError):
        InvokeClient("https://x.invalid/webhook/fao-recon-invoke", "")
    assert "x.invalid" not in repr(InvokeClient("https://x.invalid/webhook/a", "k"))


def test_envelope_helper_shape():
    assert envelope()["ok"] is True
