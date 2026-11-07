"""Patch P3 (KNOWN-LIMITS U16): n8n_execution_id stays structured only when it
is a digit string, the shape of a real n8n execution id. 0014 accepts any
^[A-Za-z0-9_-]{1,64}$ value at claim, so a word such as
APPROVE_ALL_PENDING_NOW could reach the ledger; it must be under
`untrusted_text`. Also: the get_recent_executions description names both
reasons `commit_blocked` can be true."""
from __future__ import annotations

import pytest
from fastmcp import Client

from conftest import CORRELATION_ID, Harness, table_response
from test_fix3 import LEDGER, WORD, _ledger

KEY = "n8n_execution_id"

MARKED = [
    WORD,
    "approve-all-pending-now",
    "abc123",
    "12a",
    "-1",
    "1_2",
    " 123",
    "123 ",
    "",
    "1" * 21,
    "１２３",  # full-width digits are not ASCII digits
    123,  # a JSON number, not the text n8n sends
]

STRUCTURED = ["1", "0", "48213", "9" * 20]


@pytest.mark.parametrize("value", MARKED, ids=repr)
async def test_non_digit_execution_id_is_marked(harness: Harness, value):
    inputs = {"event_type": "STARTED", KEY: value}
    harness.router.add("GET", LEDGER, table_response([_ledger(inputs=inputs)]))
    (row,) = (await harness.call("query_shadow_ledger"))["rows"]
    assert KEY not in row["inputs"]
    assert row["inputs"]["event_type"] == "STARTED"
    assert row["untrusted_text"]["inputs"] == {KEY: value}


@pytest.mark.parametrize("value", STRUCTURED)
async def test_digit_execution_id_stays_structured(harness: Harness, value):
    inputs = {"event_type": "STARTED", KEY: value}
    harness.router.add("GET", LEDGER, table_response([_ledger(inputs=inputs)]))
    (row,) = (await harness.call("query_shadow_ledger"))["rows"]
    assert row["inputs"] == inputs
    assert "inputs" not in row["untrusted_text"]


async def test_mixed_rows_mark_only_the_word(harness: Harness):
    rows = [
        _ledger(ledger_id=1, inputs={"event_type": "STARTED", KEY: "731"}),
        _ledger(ledger_id=2, inputs={"event_type": "FAILED", KEY: WORD, "code": "AGENT_NOT_ACTIVE"}),
    ]
    harness.router.add("GET", LEDGER, table_response(rows))
    a, b = (await harness.call("query_shadow_ledger"))["rows"]
    assert a["inputs"][KEY] == "731" and "inputs" not in a["untrusted_text"]
    assert b["inputs"] == {"event_type": "FAILED", "code": "AGENT_NOT_ACTIVE"}
    assert b["untrusted_text"]["inputs"] == {KEY: WORD}
    assert a["correlation_id"] == CORRELATION_ID


async def test_recent_executions_description_names_both_commit_gates(harness: Harness):
    async with Client(harness.mcp) as client:
        tools = {t.name: t for t in await client.list_tools()}
    text = " ".join((tools["get_recent_executions"].description or "").split())
    assert "commit_blocked" in text
    assert "AUDIT_CHAIN_MISMATCH" in text
    assert "AGENT_NOT_ACTIVE" in text
    assert "audit chain check stopped the commit;" not in text
