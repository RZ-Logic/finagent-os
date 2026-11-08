"""Startup refusals: privileged keys, missing settings, reader identity (FAO-GOV-015)."""
from __future__ import annotations

import base64
import json

import httpx
import pytest

import server
from conftest import (
    PUBLIC_KEY,
    READER_EMAIL,
    Router,
    WEBHOOK_URL,
    envelope,
    make_server,
)

GOOD_ENV = {
    "SUPABASE_URL": "http://127.0.0.1:54321",
    "SUPABASE_PUBLIC_KEY": PUBLIC_KEY,
    "FAO_READER_EMAIL": READER_EMAIL,
    "FAO_READER_PASSWORD": "pw",
    "N8N_INVOKE_WEBHOOK_URL": WEBHOOK_URL,
    "N8N_INVOKE_KEY": "k",
}


def _jwt(role: str) -> str:
    def part(obj: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")

    return f"{part({'alg': 'HS256'})}.{part({'role': role})}.sig"


def test_good_config_loads_without_invoker():
    config = server.load_config(GOOD_ENV)
    assert config.invoker_email is None and config.invoker_password is None
    assert "pw" not in repr(config)


@pytest.mark.parametrize("key", ["SUPABASE_SERVICE_KEY", "SUPABASE_SECRET_KEY"])
def test_refuses_service_or_secret_key(key):
    with pytest.raises(SystemExit) as exc:
        server.load_config({**GOOD_ENV, key: "anything"})
    assert exc.value.code == server.MSG_PRIVILEGED_KEY
    assert "anything" not in str(exc.value.code)


def test_refuses_empty_service_key_variable_too():
    with pytest.raises(SystemExit):
        server.load_config({**GOOD_ENV, "SUPABASE_SERVICE_KEY": ""})


@pytest.mark.parametrize(
    "key",
    [
        "SUPABASE_URL",
        "SUPABASE_PUBLIC_KEY",
        "FAO_READER_EMAIL",
        "FAO_READER_PASSWORD",
        "N8N_INVOKE_WEBHOOK_URL",
        "N8N_INVOKE_KEY",
    ],
)
def test_refuses_missing_required_key(key):
    env = dict(GOOD_ENV)
    del env[key]
    with pytest.raises(SystemExit) as exc:
        server.load_config(env)
    assert key in exc.value.code


@pytest.mark.parametrize("public_key", ["sb_secret_abc123", _jwt("service_role")])
def test_refuses_privileged_key_in_public_slot(public_key):
    with pytest.raises(SystemExit) as exc:
        server.load_config({**GOOD_ENV, "SUPABASE_PUBLIC_KEY": public_key})
    assert exc.value.code == server.MSG_PUBLIC_KEY_PRIVILEGED


def test_accepts_anon_jwt_public_key():
    assert server.load_config({**GOOD_ENV, "SUPABASE_PUBLIC_KEY": _jwt("anon")})


def test_refuses_half_invoker_credentials():
    with pytest.raises(SystemExit) as exc:
        server.load_config({**GOOD_ENV, "FAO_INVOKER_EMAIL": "a@b.c"})
    assert exc.value.code == server.MSG_INVOKER_PAIR


def test_refuses_non_http_url():
    with pytest.raises(SystemExit):
        server.load_config({**GOOD_ENV, "SUPABASE_URL": "ftp://x"})


def test_refuses_reader_that_cannot_sign_in(router: Router):
    router.add("POST", "/auth/v1/token", httpx.Response(400, json={"error": "invalid_grant"}))
    with pytest.raises(SystemExit) as exc:
        make_server(router)
    assert exc.value.code == server.MSG_READER_SIGN_IN
    assert router.calls("/rest/v1/rpc/fao_whoami") == []


def test_refuses_reader_when_auth_unreachable(router: Router):
    router.add("POST", "/auth/v1/token", httpx.ConnectError)
    with pytest.raises(SystemExit) as exc:
        make_server(router)
    assert exc.value.code == server.MSG_READER_SIGN_IN


@pytest.mark.parametrize(
    "roles",
    [
        [],
        [{"role": "reader", "agent_id": "fao_reserve_recon_v1"}],
        [{"role": "reader", "agent_id": None}, {"role": "invoker", "agent_id": None}],
        [{"role": "admin", "agent_id": None}],
        [{"role": "approver", "agent_id": None}],
        None,
    ],
)
def test_refuses_reader_with_wrong_roles(router: Router, roles):
    router.add("POST", "/rest/v1/rpc/fao_whoami", httpx.Response(200, json=envelope(roles=roles)))
    with pytest.raises(SystemExit) as exc:
        make_server(router)
    assert exc.value.code == server.MSG_READER_ROLES


def test_refuses_when_whoami_refuses(router: Router):
    router.add(
        "POST",
        "/rest/v1/rpc/fao_whoami",
        httpx.Response(
            403,
            json={
                "ok": False,
                "code": "NOT_AUTHORISED",
                "http_status": 403,
                "message": "You are not authorised for this action.",
                "ref": 1,
            },
        ),
    )
    with pytest.raises(SystemExit) as exc:
        make_server(router)
    assert exc.value.code == server.MSG_READER_ROLES


def test_startup_whoami_uses_reader_token_and_public_key(router: Router):
    make_server(router)
    (call,) = router.calls("/rest/v1/rpc/fao_whoami")
    assert call.headers["authorization"] == "Bearer reader-access-token-aaa111"
    assert call.headers["apikey"] == PUBLIC_KEY


def test_main_refuses_service_key_before_any_request(monkeypatch):
    def boom(*a, **k):  # pragma: no cover - must never run
        raise AssertionError("no client may be built")

    monkeypatch.setattr(server, "RestClient", boom)
    with pytest.raises(SystemExit):
        server.main({**GOOD_ENV, "SUPABASE_SERVICE_KEY": "x"})
