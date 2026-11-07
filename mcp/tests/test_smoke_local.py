"""smoke_local refuses anything that is not the local stack."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "smoke_local.py"


def load_module():
    spec = importlib.util.spec_from_file_location("smoke_local", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_env(path: Path, **values: str) -> None:
    path.write_text("".join(f"{k}={v}\n" for k, v in values.items()), encoding="utf-8")


@pytest.mark.parametrize(
    "url",
    [
        "https://abcdefgh.supabase.co",
        "http://127.0.0.1.evil.example:54321",
        "http://localhost.example:54321",
        "",
    ],
)
def test_refuses_non_local_supabase_url(tmp_path, monkeypatch, url):
    smoke = load_module()
    env_file = tmp_path / "mcp.env"
    write_env(env_file, SUPABASE_URL=url, SUPABASE_PUBLIC_KEY="k")
    monkeypatch.setattr(smoke, "ENV_FILE", env_file)
    with pytest.raises(SystemExit):
        smoke.load_local_env()


def test_refuses_non_local_webhook(tmp_path, monkeypatch):
    smoke = load_module()
    env_file = tmp_path / "mcp.env"
    write_env(
        env_file,
        SUPABASE_URL="http://127.0.0.1:54321",
        N8N_INVOKE_WEBHOOK_URL="https://n8n.example.com/webhook/fao-recon-invoke",
    )
    monkeypatch.setattr(smoke, "ENV_FILE", env_file)
    with pytest.raises(SystemExit):
        smoke.load_local_env()


def test_accepts_local_and_drops_invoker(tmp_path, monkeypatch):
    smoke = load_module()
    env_file = tmp_path / "mcp.env"
    write_env(
        env_file,
        SUPABASE_URL="http://localhost:54321",
        FAO_INVOKER_EMAIL="a@b.c",
        FAO_INVOKER_PASSWORD="p",
    )
    monkeypatch.setattr(smoke, "ENV_FILE", env_file)
    env = smoke.load_local_env()
    assert "FAO_INVOKER_EMAIL" not in env and "FAO_INVOKER_PASSWORD" not in env
    assert env["N8N_INVOKE_WEBHOOK_URL"].startswith("http://127.0.0.1:")


def test_missing_env_file_refuses(tmp_path, monkeypatch):
    smoke = load_module()
    monkeypatch.setattr(smoke, "ENV_FILE", tmp_path / "absent.env")
    with pytest.raises(SystemExit):
        smoke.load_local_env()
