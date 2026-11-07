"""invoke_reserve_recon: own session, idempotency, webhook contract, no leaks (FAO-GOV-002)."""
from __future__ import annotations

import hashlib
import math

import httpx
import pytest

from conftest import (
    CORRELATION_ID,
    FIXED_NOW,
    INVOKE_KEY,
    INVOKER_EMAIL,
    INVOKER_TOKEN,
    PUBLIC_KEY,
    RUN_TOKEN,
    WEBHOOK_PATH,
    Harness,
    Router,
    assert_no_secrets,
    envelope,
    make_server,
    refusal,
)

RUN_START = "/rest/v1/rpc/fao_run_start"
REASON = "Month-end reserve check"


def started(**over):
    fields = dict(
        correlation_id=CORRELATION_ID,
        run_token=RUN_TOKEN,
        token_expires_at="2026-11-08T00:10:00+00:00",
        state="REQUESTED",
        replayed=False,
    )
    fields.update(over)
    return httpx.Response(200, json=envelope(**fields))


def accepted():
    return httpx.Response(202, json={"accepted": True, "correlation_id": CORRELATION_ID})


def expected_key(reason: str = REASON, now: float = FIXED_NOW) -> str:
    material = f"{INVOKER_EMAIL.lower()}|fao_reserve_recon_v1|{reason}|{math.floor(now / 600)}"
    return hashlib.sha256(material.encode()).hexdigest()[:32]


async def test_no_user_credential_refuses_before_any_request(router: Router):
    mcp = make_server(router, invoker=False)
    before = len(router.requests)
    result = await Harness(router, mcp).call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "refused" and result["code"] == "NO_USER_CREDENTIAL"
    assert len(router.requests) == before


async def test_no_user_credential_refuses_even_with_bad_reason(router: Router):
    mcp = make_server(router, invoker=False)
    before = len(router.requests)
    result = await Harness(router, mcp).call("invoke_reserve_recon", {"reason": ""})
    assert result["code"] == "NO_USER_CREDENTIAL"
    assert len(router.requests) == before


async def test_happy_path_invokes_with_users_own_session(harness: Harness):
    r = harness.router
    r.add("POST", RUN_START, started())
    r.add("POST", WEBHOOK_PATH, accepted())
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result == {
        "status": "invoked",
        "correlation_id": CORRELATION_ID,
        "idempotency_key": expected_key(),
    }
    (start,) = r.calls(RUN_START)
    assert start.headers["authorization"] == f"Bearer {INVOKER_TOKEN}"
    assert start.headers["apikey"] == PUBLIC_KEY
    assert r.body(start) == {
        "p_agent_id": "fao_reserve_recon_v1",
        "p_reason": REASON,
        "p_idempotency_key": expected_key(),
        "p_invoked_via": "mcp",
    }
    (hook,) = r.calls(WEBHOOK_PATH)
    assert hook.method == "POST"
    assert hook.headers["x-fao-invoke-key"] == INVOKE_KEY
    assert r.body(hook) == {"run_token": RUN_TOKEN}
    assert "authorization" not in hook.headers
    assert_no_secrets(result)


async def test_default_key_is_stable_within_a_bucket_and_returned(harness: Harness):
    r = harness.router
    r.add("POST", RUN_START, started())
    r.add("POST", WEBHOOK_PATH, accepted())
    first = await harness.call("invoke_reserve_recon", {"reason": REASON})
    second = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert first["idempotency_key"] == second["idempotency_key"] == expected_key()
    keys = [r.body(c)["p_idempotency_key"] for c in r.calls(RUN_START)]
    assert keys == [expected_key(), expected_key()]


async def test_default_key_changes_with_reason_and_bucket(router: Router):
    clock = {"t": FIXED_NOW}
    router.add("POST", RUN_START, started())
    router.add("POST", WEBHOOK_PATH, accepted())
    h = Harness(router, make_server(router, clock=lambda: clock["t"]))
    a = await h.call("invoke_reserve_recon", {"reason": REASON})
    b = await h.call("invoke_reserve_recon", {"reason": REASON + "!"})
    clock["t"] += 600
    c = await h.call("invoke_reserve_recon", {"reason": REASON})
    assert len({a["idempotency_key"], b["idempotency_key"], c["idempotency_key"]}) == 3
    assert c["idempotency_key"] == expected_key(now=clock["t"])


async def test_explicit_key_is_used_and_returned(harness: Harness):
    harness.router.add("POST", RUN_START, started())
    harness.router.add("POST", WEBHOOK_PATH, accepted())
    result = await harness.call("invoke_reserve_recon", {"reason": REASON, "idempotency_key": "my-key_0001"})
    assert result["idempotency_key"] == "my-key_0001"
    (start,) = harness.router.calls(RUN_START)
    assert harness.router.body(start)["p_idempotency_key"] == "my-key_0001"


@pytest.mark.parametrize("key", ["short", "x" * 65, "bad key!", "a/b/c/d/e", 12345678])
async def test_bad_explicit_key_is_invalid_without_requests(harness: Harness, key):
    before = len(harness.router.requests)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON, "idempotency_key": key})
    assert result["status"] == "invalid" and result["field"] == "idempotency_key"
    assert len(harness.router.requests) == before


@pytest.mark.parametrize("reason", ["", "x" * 501, "bell\x07", 42, None])
async def test_bad_reason_is_invalid_without_requests(harness: Harness, reason):
    before = len(harness.router.requests)
    result = await harness.call("invoke_reserve_recon", {"reason": reason})
    assert result["status"] == "invalid" and result["field"] == "reason"
    assert len(harness.router.requests) == before


async def test_reason_with_newline_and_tab_is_accepted(harness: Harness):
    harness.router.add("POST", RUN_START, started())
    harness.router.add("POST", WEBHOOK_PATH, accepted())
    result = await harness.call("invoke_reserve_recon", {"reason": "line one\n\tline two"})
    assert result["status"] == "invoked"


async def test_replay_without_token_makes_no_webhook_call(harness: Harness):
    harness.router.add(
        "POST", RUN_START, started(run_token=None, token_expires_at=None, replayed=True, state="RUNNING")
    )
    harness.router.add("POST", WEBHOOK_PATH, accepted())
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result == {
        "status": "replayed",
        "correlation_id": CORRELATION_ID,
        "state": "RUNNING",
        "idempotency_key": expected_key(),
    }
    assert harness.router.calls(WEBHOOK_PATH) == []


async def test_replay_with_new_token_posts_once(harness: Harness):
    harness.router.add("POST", RUN_START, started(replayed=True))
    harness.router.add("POST", WEBHOOK_PATH, accepted())
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "invoked"
    assert len(harness.router.calls(WEBHOOK_PATH)) == 1


@pytest.mark.parametrize(
    "code,status,message",
    [
        ("RATE_LIMITED", 429, "Too many runs in the last hour."),
        ("AGENT_NOT_ACTIVE", 409, "The agent is not active."),
        ("NOT_AUTHORISED", 403, "You are not authorised for this action."),
        ("NOT_AN_OWNER", 403, "Your account is not an active process owner."),
        ("INVALID_INPUT", 400, "The request is not valid."),
    ],
)
async def test_run_start_refusal_is_reported_with_code(harness: Harness, code, status, message):
    harness.router.add("POST", RUN_START, httpx.Response(status, json=refusal(code, status, message, ref=31)))
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "refused"
    assert result["code"] == code and result["http_status"] == status
    assert result["ref"] == 31 and result["idempotency_key"] == expected_key()
    assert harness.router.calls(WEBHOOK_PATH) == []


async def test_timeout_after_send_is_unknown_with_key_and_correlation(harness: Harness):
    harness.router.add("POST", RUN_START, started())
    harness.router.add("POST", WEBHOOK_PATH, httpx.ReadTimeout)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result == {
        "status": "unknown",
        "message": "outcome unknown, the run may have started",
        "correlation_id": CORRELATION_ID,
        "idempotency_key": expected_key(),
    }
    assert_no_secrets(result)


async def test_dropped_connection_after_send_is_unknown(harness: Harness):
    harness.router.add("POST", RUN_START, started())
    harness.router.add("POST", WEBHOOK_PATH, httpx.RemoteProtocolError)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "unknown"


WEBHOOK_FAILURES = [
    (httpx.Response(200, text="<html>ok</html>"), "bad_json", 200),
    (httpx.Response(202, text="accepted"), "bad_json", 202),
    (httpx.Response(401, json={"accepted": False, "code": "INVALID_TOKEN"}), "http", 401),
    (httpx.Response(409, json={"accepted": False, "code": "ALREADY_CLAIMED"}), "http", 409),
    (httpx.Response(410, json={"accepted": False, "code": "TOKEN_EXPIRED"}), "http", 410),
    (httpx.Response(403, text="Forbidden"), "http", 403),
    (httpx.Response(500, json={"message": f"error at {WEBHOOK_PATH} key {INVOKE_KEY}"}), "http", 500),
    (httpx.Response(200, json={"accepted": True}), "http", 200),
    (httpx.ConnectError, "connect", None),
    (httpx.ConnectTimeout, "timeout", None),
]


@pytest.mark.parametrize("failure,kind,status", WEBHOOK_FAILURES)
async def test_webhook_failures_are_structured_errors(harness: Harness, failure, kind, status):
    harness.router.add("POST", RUN_START, started())
    harness.router.add("POST", WEBHOOK_PATH, failure)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "error"
    assert result["kind"] == kind and result["http_status"] == status
    assert result["idempotency_key"] == expected_key()
    assert result["correlation_id"] == CORRELATION_ID
    assert_no_secrets(result)


async def test_webhook_refusal_code_is_passed_through(harness: Harness):
    harness.router.add("POST", RUN_START, started())
    harness.router.add(
        "POST", WEBHOOK_PATH, httpx.Response(409, json={"accepted": False, "code": "ALREADY_CLAIMED"})
    )
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["code"] == "ALREADY_CLAIMED"


@pytest.mark.parametrize(
    "failure,kind,status",
    [
        (httpx.Response(200, text="not json"), "bad_json", 200),
        (httpx.Response(401, json={"code": "PGRST301", "message": "JWT expired"}), "http", 401),
        (httpx.Response(500, text="oops"), "http", 500),
        (httpx.ConnectError, "connect", None),
        (httpx.ReadTimeout, "timeout", None),
    ],
)
async def test_run_start_transport_failures_are_structured(harness: Harness, failure, kind, status):
    harness.router.add("POST", RUN_START, failure)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "error" and result["kind"] == kind and result["http_status"] == status
    assert harness.router.calls(WEBHOOK_PATH) == []
    assert_no_secrets(result)


async def test_invoker_sign_in_refused_is_structured(harness: Harness):
    reader_auth = harness.router.routes[("POST", "/auth/v1/token")]

    def only_reader(request):
        body = harness.router.body(request)
        if body["email"] == INVOKER_EMAIL:
            return httpx.Response(400, json={"error": "invalid_grant", "msg": body["password"]})
        return reader_auth(request)

    harness.router.add("POST", "/auth/v1/token", only_reader)
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "error" and result["kind"] == "auth" and result["http_status"] == 400
    assert harness.router.calls(RUN_START) == []
    assert_no_secrets(result)


async def test_success_without_token_and_not_replayed_is_an_error(harness: Harness):
    harness.router.add("POST", RUN_START, started(run_token=None, replayed=False))
    result = await harness.call("invoke_reserve_recon", {"reason": REASON})
    assert result["status"] == "error" and result["kind"] == "bad_json"
    assert harness.router.calls(WEBHOOK_PATH) == []
