"""File transport security checks without a running DAW."""
import asyncio
import json

import pytest

import reaper_mcp_server as server


@pytest.fixture(autouse=True)
def bridge(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "BRIDGE_DIR", tmp_path)
    from types import SimpleNamespace
    monkeypatch.setattr(server.uuid, "uuid4", lambda: SimpleNamespace(hex="1"))
    monkeypatch.setattr(server, "FILE_TIMEOUT", 0.2)
    return tmp_path


@pytest.mark.asyncio
async def test_predictable_temp_symlink_is_not_followed(bridge):
    victim = bridge / "original.txt"
    victim.write_text("keep this")
    (bridge / "request_1.tmp").symlink_to(victim)
    result = await server.reaper_call_file("GetNumTracks", [])
    assert result["ok"] is False
    assert victim.read_text() == "keep this"
    assert not (bridge / "request_1.json").exists()


@pytest.mark.asyncio
async def test_cancellation_removes_pending_request(bridge):
    task = asyncio.create_task(server.reaper_call_file("GetNumTracks", []))
    await asyncio.sleep(0.03)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await asyncio.wait_for(task, timeout=1)
    assert not list(bridge.glob("request_*.json"))


@pytest.mark.asyncio
async def test_reads_complete_response(bridge):
    task = asyncio.create_task(server.reaper_call_file("GetNumTracks", []))
    await asyncio.sleep(0.03)
    (bridge / "response_1.json").write_text(json.dumps({"ok": True, "ret": 3}))
    assert await task == {"ok": True, "ret": 3}
    assert not list(bridge.glob("*.json"))


@pytest.mark.asyncio
async def test_read_timeout_does_not_repeat_daw_action_over_file_transport(monkeypatch):
    from unittest.mock import AsyncMock
    import httpx
    client = AsyncMock()
    client.post.side_effect = httpx.ReadTimeout("response lost")
    monkeypatch.setattr(server, "get_http_client", lambda: client)
    monkeypatch.setattr(server, "COMM_MODE", "auto")
    file_call = AsyncMock()
    monkeypatch.setattr(server, "reaper_call_file", file_call)
    result = await server.reaper_call("InsertTrackAtIndex", 0, True)
    assert result["ok"] is False
    assert result["fallback"] is False
    file_call.assert_not_called()
