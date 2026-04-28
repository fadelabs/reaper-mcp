"""Contract tests for reaper_mcp_server.

Verifies that server tool functions pass correct parameters to reaper_call.
Does NOT test Lua bridge (requires running Reaper) — tests the Python side only.
"""

import asyncio
import json
from unittest.mock import AsyncMock, patch, MagicMock

import pytest

# Patch reaper_call before importing server functions
reaper_call_mock = AsyncMock()


@pytest.fixture(autouse=True)
def mock_reaper_call():
    """Mock reaper_call for all tests."""
    with patch("reaper_mcp_server.reaper_call", new=reaper_call_mock) as m:
        m.reset_mock()
        m.return_value = {"ok": True, "ret": 0}
        yield m


# --- Track Naming (Bug #3) ---


class TestInsertTrackNaming:
    """insert_track must name the correct track, not track 0."""

    @pytest.mark.asyncio
    async def test_name_targets_correct_index(self, mock_reaper_call):
        from reaper_mcp_server import insert_track

        mock_reaper_call.return_value = {"ok": True, "ret": 5}
        await insert_track(index=3, name="Vocals")

        calls = [c.args for c in mock_reaper_call.call_args_list]
        # First call: InsertTrackAtIndex
        assert calls[0] == ("InsertTrackAtIndex", 3, True)
        # Second call: set name on track 3, NOT track 0
        name_call = calls[1]
        assert name_call[0] == "GetSetMediaTrackInfo_String"
        assert name_call[1] == 3  # track index, not 0
        assert "P_NAME" in name_call
        assert "Vocals" in name_call

    @pytest.mark.asyncio
    async def test_no_name_skips_naming(self, mock_reaper_call):
        from reaper_mcp_server import insert_track

        mock_reaper_call.return_value = {"ok": True, "ret": 0}
        await insert_track(index=0, name=None)

        assert mock_reaper_call.call_count == 1  # only InsertTrackAtIndex


# --- Envelope Automation (Bug #2) ---


class TestEnvelopeAutomation:
    """Envelope functions must call correct bridge functions."""

    @pytest.mark.asyncio
    async def test_add_envelope_point(self, mock_reaper_call):
        from reaper_mcp_server import add_envelope_point

        await add_envelope_point(
            track_index=0, envelope_name="Volume", time=1.5, value=0.75, shape=0
        )
        mock_reaper_call.assert_called_once()
        call_args = mock_reaper_call.call_args[0]
        assert call_args[0] == "InsertEnvelopePoint"
        assert call_args[1] == 0  # track_index
        assert call_args[2] == "Volume"
        assert call_args[3] == 1.5  # time
        assert call_args[4] == 0.75  # value

    @pytest.mark.asyncio
    async def test_get_envelope_points(self, mock_reaper_call):
        from reaper_mcp_server import get_envelope_points

        mock_reaper_call.return_value = {"ok": True, "points": []}
        await get_envelope_points(track_index=0, envelope_name="Volume")
        mock_reaper_call.assert_called_once_with("GetEnvelopePoints", 0, "Volume")

    @pytest.mark.asyncio
    async def test_clear_envelope(self, mock_reaper_call):
        from reaper_mcp_server import clear_envelope

        await clear_envelope(track_index=0, envelope_name="Volume")
        mock_reaper_call.assert_called_once_with("ClearEnvelope", 0, "Volume")

    @pytest.mark.asyncio
    async def test_get_envelope_point_count(self, mock_reaper_call):
        from reaper_mcp_server import get_envelope_point_count

        mock_reaper_call.return_value = {"ok": True, "count": 5}
        await get_envelope_point_count(track_index=0, envelope_name="Volume")
        mock_reaper_call.assert_called_once_with(
            "CountEnvelopePoints", 0, "Volume"
        )


# --- Render/Export (Bug #2) ---


class TestRender:
    """Render functions must call correct bridge functions."""

    @pytest.mark.asyncio
    async def test_render_project(self, mock_reaper_call):
        from reaper_mcp_server import render_project

        await render_project(output_path="/tmp/out.wav")
        mock_reaper_call.assert_called_once()
        call_args = mock_reaper_call.call_args[0]
        assert call_args[0] == "RenderProject"
        assert "/tmp/out.wav" in call_args

    @pytest.mark.asyncio
    async def test_render_region(self, mock_reaper_call):
        from reaper_mcp_server import render_region

        await render_region(region_index=0, output_path="/tmp/region.wav")
        mock_reaper_call.assert_called_once_with(
            "RenderRegion", 0, "/tmp/region.wav"
        )


# --- Item Queries (Bug #4) ---


class TestItemQueries:
    """Item query functions must call correct bridge functions."""

    @pytest.mark.asyncio
    async def test_get_item_info(self, mock_reaper_call):
        from reaper_mcp_server import get_item_info

        mock_reaper_call.return_value = {"ok": True, "position": 0, "length": 1.0}
        await get_item_info(track_index=0, item_index=0)
        mock_reaper_call.assert_called_once_with("GetItemInfo", 0, 0)

    @pytest.mark.asyncio
    async def test_get_track_items(self, mock_reaper_call):
        from reaper_mcp_server import get_track_items

        mock_reaper_call.return_value = {"ok": True, "items": []}
        await get_track_items(track_index=0)
        mock_reaper_call.assert_called_once_with("GetTrackItems", 0)


# --- MIDI Notes (Bug #5) ---


class TestMIDINotes:
    """MIDI functions must call correct bridge functions."""

    @pytest.mark.asyncio
    async def test_add_midi_note(self, mock_reaper_call):
        from reaper_mcp_server import add_midi_note

        await add_midi_note(
            track_index=0,
            item_index=0,
            pitch=60,
            velocity=100,
            start_ppq=0,
            end_ppq=960,
            channel=0,
        )
        mock_reaper_call.assert_called_once()
        call_args = mock_reaper_call.call_args[0]
        assert call_args[0] == "MIDI_InsertNote"

    @pytest.mark.asyncio
    async def test_get_midi_notes(self, mock_reaper_call):
        from reaper_mcp_server import get_midi_notes

        mock_reaper_call.return_value = {"ok": True, "notes": []}
        await get_midi_notes(track_index=0, item_index=0)
        mock_reaper_call.assert_called_once_with("GetMIDINotes", 0, 0)

    @pytest.mark.asyncio
    async def test_delete_midi_note(self, mock_reaper_call):
        from reaper_mcp_server import delete_midi_note

        await delete_midi_note(track_index=0, item_index=0, note_index=0)
        mock_reaper_call.assert_called_once_with("MIDI_DeleteNote", 0, 0, 0)

    @pytest.mark.asyncio
    async def test_clear_midi_item(self, mock_reaper_call):
        from reaper_mcp_server import clear_midi_item

        await clear_midi_item(track_index=0, item_index=0)
        mock_reaper_call.assert_called_once_with("ClearMIDIItem", 0, 0)
