#!/usr/bin/env python3
"""
REAPER MCP Server — Live Integration Test Harness

Calls every bridge function with valid args, validates response shapes
against documented contracts, reports PASS/FAIL per tool.

Requires a running REAPER instance with the Lua bridge script loaded.

Usage:
    uv run python test_harness.py              # run all tests
    uv run python test_harness.py --category track  # run one category
    uv run python test_harness.py --verbose    # show full responses
    uv run python test_harness.py --json       # machine-readable output
"""

import argparse
import json
import os
import struct
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
MAGENTA = "\033[95m"
CYAN = "\033[96m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"

NO_COLOR = os.getenv("NO_COLOR", "")


def c(color: str, text: str) -> str:
    if NO_COLOR:
        return text
    return f"{color}{text}{RESET}"


# ---------------------------------------------------------------------------
# Bridge client
# ---------------------------------------------------------------------------
class ReaperBridge:
    def __init__(self, bridge_dir: str | None = None, timeout: float = 8.0):
        if bridge_dir:
            self.bridge_dir = Path(bridge_dir)
        else:
            self.bridge_dir = Path(
                os.getenv(
                    "REAPER_BRIDGE_DIR",
                    os.path.expanduser(
                        "~/Library/Application Support/REAPER/Scripts/mcp_bridge_data"
                    ),
                )
            )
        self.timeout = timeout
        self._counter = 0

    def call(self, func: str, *args) -> dict:
        self._counter = (self._counter % 999) + 1
        req_file = self.bridge_dir / f"request_{self._counter}.json"
        resp_file = self.bridge_dir / f"response_{self._counter}.json"

        try:
            resp_file.unlink(missing_ok=True)
        except OSError:
            pass

        payload = json.dumps({"func": func, "args": list(args)})
        tmp = req_file.with_suffix(".tmp")
        tmp.write_text(payload)
        tmp.rename(req_file)

        start = time.time()
        while time.time() - start < self.timeout:
            if resp_file.exists():
                try:
                    text = resp_file.read_text()
                    if text.strip():
                        data = json.loads(text)
                        req_file.unlink(missing_ok=True)
                        resp_file.unlink(missing_ok=True)
                        return data
                except (json.JSONDecodeError, OSError):
                    pass
            time.sleep(0.03)

        req_file.unlink(missing_ok=True)
        return {"ok": False, "error": "timeout", "_timeout": True}


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------
@dataclass
class TestResult:
    name: str
    status: str  # PASS, FAIL, SKIP, ERROR
    detail: str = ""
    failures: list[str] = field(default_factory=list)
    response: dict = field(default_factory=dict)
    duration_ms: float = 0.0


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def check_fields(response: dict, fields: dict[str, type], name: str = "") -> list[str]:
    """Validate response has expected fields with correct types.

    fields: {"key": type} or {"key": (type1, type2)} for union types.
    Use type None to skip type checking (just check presence).
    """
    failures = []
    for key, expected_type in fields.items():
        if key not in response:
            failures.append(f"missing '{key}'")
            continue
        if expected_type is None:
            continue
        val = response[key]
        if isinstance(expected_type, tuple):
            if not isinstance(val, expected_type):
                failures.append(
                    f"'{key}': expected {'/'.join(t.__name__ for t in expected_type)}, "
                    f"got {type(val).__name__}"
                )
        else:
            if not isinstance(val, expected_type):
                failures.append(
                    f"'{key}': expected {expected_type.__name__}, got {type(val).__name__}"
                )
    return failures


def expect_ok(response: dict) -> list[str]:
    if not response.get("ok"):
        err = response.get("error", "unknown")
        if response.get("_timeout"):
            return [f"TIMEOUT (bridge not responding)"]
        return [f"ok=false: {err}"]
    return []


def expect_error(response: dict) -> list[str]:
    if response.get("ok", False):
        return ["expected ok=false but got ok=true"]
    return []


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def create_silence_wav(path: str, duration: float = 0.5, sr: int = 44100):
    n = int(sr * duration)
    data_size = n * 2
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        f.write(b"\x00" * data_size)


def brief(response: dict, max_len: int = 50) -> str:
    keys = [k for k in response if k != "ok"]
    parts = []
    for k in keys[:4]:
        v = response[k]
        if isinstance(v, str) and len(v) > 20:
            v = v[:17] + "..."
        elif isinstance(v, list):
            v = f"[{len(v)} items]"
        elif isinstance(v, dict):
            v = "{...}"
        parts.append(f"{k}={v}")
    s = ", ".join(parts)
    if len(s) > max_len:
        s = s[: max_len - 3] + "..."
    return s


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
def run_test(name: str, fn, bridge: ReaperBridge) -> TestResult:
    start = time.time()
    try:
        result = fn(bridge)
        result.duration_ms = (time.time() - start) * 1000
        return result
    except Exception as e:
        return TestResult(
            name=name,
            status="ERROR",
            detail=str(e),
            duration_ms=(time.time() - start) * 1000,
        )


# ===================================================================
# TEST DEFINITIONS
# ===================================================================

# --- Phase 0: Connectivity ---


def test_connectivity(b: ReaperBridge) -> TestResult:
    r = b.call("CountTracks", 0)
    fails = expect_ok(r)
    if not fails:
        fails = check_fields(r, {"ret": (int, float)})
    return TestResult("connectivity", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 1: Project Info (read-only) ---


def test_get_track_count(b: ReaperBridge) -> TestResult:
    r = b.call("CountTracks", 0)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    return TestResult("get_track_count", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_tempo(b: ReaperBridge) -> TestResult:
    r = b.call("Master_GetTempo")
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    return TestResult("get_tempo", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_time_signature(b: ReaperBridge) -> TestResult:
    r = b.call("GetTimeSignature")
    fails = expect_ok(r) or check_fields(r, {"numerator": (int, float), "denominator": (int, float)})
    return TestResult("get_time_signature", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_project_name(b: ReaperBridge) -> TestResult:
    r = b.call("GetProjectName", 0, "")
    fails = expect_ok(r)
    return TestResult("get_project_name", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_project_path(b: ReaperBridge) -> TestResult:
    r = b.call("GetProjectPath", "")
    fails = expect_ok(r)
    return TestResult("get_project_path", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_project_length(b: ReaperBridge) -> TestResult:
    r = b.call("GetProjectLength", 0)
    fails = expect_ok(r)
    return TestResult("get_project_length", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_project_summary(b: ReaperBridge) -> TestResult:
    r = b.call("GetProjectSummary")
    fails = expect_ok(r) or check_fields(
        r,
        {
            "project_name": str,
            "tempo": (int, float),
            "track_count": (int, float),
            "tracks": list,
        },
    )
    return TestResult("get_project_summary", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_cursor_position(b: ReaperBridge) -> TestResult:
    r = b.call("GetCursorPosition")
    fails = expect_ok(r)
    return TestResult("get_cursor_position", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_play_state(b: ReaperBridge) -> TestResult:
    r = b.call("GetPlayState")
    fails = expect_ok(r)
    return TestResult("get_play_state", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_play_position(b: ReaperBridge) -> TestResult:
    r = b.call("GetPlayPosition")
    fails = expect_ok(r)
    return TestResult("get_play_position", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 2: Transport ---


def test_stop(b: ReaperBridge) -> TestResult:
    r = b.call("OnStopButton")
    fails = expect_ok(r)
    return TestResult("stop", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_play_stop(b: ReaperBridge) -> TestResult:
    r1 = b.call("OnPlayButton")
    time.sleep(0.1)
    r2 = b.call("OnStopButton")
    fails = expect_ok(r1)
    if not fails:
        fails = expect_ok(r2)
    return TestResult("play+stop", "FAIL" if fails else "PASS", "play then stop", fails, r1)


def test_set_cursor_position(b: ReaperBridge) -> TestResult:
    r = b.call("SetEditCurPos", 2.0, True, False)
    fails = expect_ok(r)
    if not fails:
        r2 = b.call("GetCursorPosition")
        pos = r2.get("ret", r2.get("position", -1))
        if isinstance(pos, (int, float)) and abs(pos - 2.0) > 0.1:
            fails.append(f"cursor at {pos}, expected ~2.0")
    b.call("SetEditCurPos", 0.0, True, False)
    return TestResult("set_cursor_position", "FAIL" if fails else "PASS", "set to 2.0s", fails, r)


def test_toggle_repeat(b: ReaperBridge) -> TestResult:
    r1 = b.call("GetSetRepeat", -1)
    r2 = b.call("Main_OnCommand", 1068, 0)
    r3 = b.call("GetSetRepeat", -1)
    b.call("Main_OnCommand", 1068, 0)  # toggle back
    fails = expect_ok(r2)
    return TestResult("toggle_repeat", "FAIL" if fails else "PASS", brief(r2), fails, r2)


# --- Phase 3: Tracks ---


class TrackFixture:
    indices: list[int] = []


def setup_tracks(b: ReaperBridge) -> TrackFixture:
    fix = TrackFixture()
    fix.indices = []
    for i, name in enumerate(["HarnessTrackA", "HarnessTrackB"]):
        count = b.call("CountTracks", 0).get("ret", 0)
        idx = int(count)
        b.call("InsertTrackAtIndex", idx, True)
        b.call("GetSetMediaTrackInfo_String", idx, "P_NAME", name, True)
        fix.indices.append(idx)
    return fix


def teardown_tracks(b: ReaperBridge, fix: TrackFixture):
    for idx in sorted(fix.indices, reverse=True):
        b.call("DeleteTrack", 0, idx)


def test_insert_track_with_name(b: ReaperBridge) -> TestResult:
    count = int(b.call("CountTracks", 0).get("ret", 0))
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "NameTest", True)
    r = b.call("GetTrackInfo", count)
    fails = expect_ok(r)
    info = r.get("info", r)
    name = info.get("name", "")
    if "NameTest" not in name:
        fails.append(f"name='{name}', expected 'NameTest'")
    b.call("DeleteTrack", 0, count)
    return TestResult("insert_track+name", "FAIL" if fails else "PASS", f"name={name}", fails, r)


def test_get_track(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("GetTrackInfo", fix.indices[0])
    fails = expect_ok(r) or check_fields(r, {"info": dict})
    if not fails:
        info = r["info"]
        fails = check_fields(info, {"name": str, "guid": str})
    return TestResult("get_track", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_all_tracks(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("GetAllTracksInfo")
    fails = expect_ok(r) or check_fields(r, {"tracks": list})
    if not fails and len(r["tracks"]) < 2:
        fails.append(f"expected >=2 tracks, got {len(r['tracks'])}")
    return TestResult("get_all_tracks", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_master_track(b: ReaperBridge) -> TestResult:
    r = b.call("GetTrackInfo", -1)
    fails = expect_ok(r)
    return TestResult("get_master_track", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_name(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("GetSetMediaTrackInfo_String", fix.indices[0], "P_NAME", "Renamed", True)
    fails = expect_ok(r)
    if not fails:
        r2 = b.call("GetTrackInfo", fix.indices[0])
        info = r2.get("info", r2)
        if info.get("name", "") != "Renamed":
            fails.append(f"name not updated: {info.get('name')}")
    b.call("GetSetMediaTrackInfo_String", fix.indices[0], "P_NAME", "HarnessTrackA", True)
    return TestResult("set_track_name", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_volume(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    linear = 10 ** (-6.0 / 20)
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_VOL", linear)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_VOL", 1.0)
    return TestResult("set_track_volume", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_pan(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_PAN", 0.5)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_PAN", 0.0)
    return TestResult("set_track_pan", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_mute(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "B_MUTE", 1)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "B_MUTE", 0)
    return TestResult("set_track_mute", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_solo(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_SOLO", 1)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_SOLO", 0)
    return TestResult("set_track_solo", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_track(b: ReaperBridge) -> TestResult:
    count = int(b.call("CountTracks", 0).get("ret", 0))
    b.call("InsertTrackAtIndex", count, True)
    r = b.call("DeleteTrack", 0, count)
    fails = expect_ok(r)
    new_count = int(b.call("CountTracks", 0).get("ret", 0))
    if new_count != count:
        fails.append(f"track count {new_count} after delete, expected {count}")
    return TestResult("delete_track", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_master_rejected(b: ReaperBridge) -> TestResult:
    return TestResult("delete_master", "SKIP", "Python-layer guard, not bridge-testable")


# --- Phase 4: FX ---


class FXFixture:
    track_idx: int = 0
    eq_idx: int = 0
    comp_idx: int = 1


def setup_fx(b: ReaperBridge) -> FXFixture:
    fix = FXFixture()
    count = int(b.call("CountTracks", 0).get("ret", 0))
    fix.track_idx = count
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "FXTest", True)
    r1 = b.call("TrackFX_AddByName", count, "ReaEQ", False, -1)
    fix.eq_idx = int(r1.get("ret", 0))
    r2 = b.call("TrackFX_AddByName", count, "ReaComp", False, -1)
    fix.comp_idx = int(r2.get("ret", 1))
    return fix


def teardown_fx(b: ReaperBridge, fix: FXFixture):
    b.call("DeleteTrack", 0, fix.track_idx)


def test_fx_get_count(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetCount", fix.track_idx)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    if not fails and int(r["ret"]) != 2:
        fails.append(f"expected 2 FX, got {r['ret']}")
    return TestResult("track_fx_get_count", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_list(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("GetTrackFXList", fix.track_idx)
    fails = expect_ok(r) or check_fields(r, {"fx": list, "track_index": (int, float)})
    if not fails:
        fx_list = r["fx"]
        if len(fx_list) < 2:
            fails.append(f"expected >=2 FX items, got {len(fx_list)}")
        elif not all(isinstance(f, dict) and "index" in f and "name" in f and "enabled" in f for f in fx_list):
            fails.append("FX items missing index/name/enabled keys")
    return TestResult("track_fx_get_list", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_name(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetFXName", fix.track_idx, fix.eq_idx)
    fails = expect_ok(r) or check_fields(r, {"ret": str})
    if not fails and "ReaEQ" not in r.get("ret", ""):
        fails.append(f"expected ReaEQ in name, got '{r.get('ret')}'")
    return TestResult("track_fx_get_name", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_enabled(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetEnabled", fix.track_idx, fix.eq_idx)
    fails = expect_ok(r) or check_fields(r, {"ret": bool})
    return TestResult("track_fx_get_enabled", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_set_enabled(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_SetEnabled", fix.track_idx, fix.eq_idx, False)
    fails = expect_ok(r)
    r2 = b.call("TrackFX_GetEnabled", fix.track_idx, fix.eq_idx)
    if r2.get("ret") is not False:
        fails.append(f"FX still enabled after disable: {r2.get('ret')}")
    b.call("TrackFX_SetEnabled", fix.track_idx, fix.eq_idx, True)
    return TestResult("track_fx_set_enabled", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_num_params(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetNumParams", fix.track_idx, fix.eq_idx)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    if not fails and int(r["ret"]) < 1:
        fails.append(f"expected >=1 params, got {r['ret']}")
    return TestResult("track_fx_get_num_params", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_param(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetParam", fix.track_idx, fix.eq_idx, 0)
    fails = expect_ok(r)
    has_value = "value" in r or "ret" in r
    if not fails and not has_value:
        fails.append("missing 'value' or 'ret' field")
    return TestResult("track_fx_get_param", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_set_param(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_SetParam", fix.track_idx, fix.eq_idx, 0, 0.5)
    fails = expect_ok(r)
    return TestResult("track_fx_set_param", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_get_param_name(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetParamName", fix.track_idx, fix.eq_idx, 0, "")
    fails = expect_ok(r) or check_fields(r, {"ret": str})
    return TestResult("track_fx_get_param_name", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_fx_add_delete(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r1 = b.call("TrackFX_AddByName", fix.track_idx, "ReaLimit", False, -1)
    fails = expect_ok(r1) or check_fields(r1, {"ret": (int, float)})
    if not fails:
        new_idx = int(r1["ret"])
        r2 = b.call("TrackFX_Delete", fix.track_idx, new_idx)
        fails = expect_ok(r2)
    return TestResult("track_fx_add+delete", "FAIL" if fails else "PASS", brief(r1), fails, r1)


# --- Phase 5: MIDI ---


class MIDIFixture:
    track_idx: int = 0
    item_idx: int = 0


def setup_midi(b: ReaperBridge) -> MIDIFixture:
    fix = MIDIFixture()
    count = int(b.call("CountTracks", 0).get("ret", 0))
    fix.track_idx = count
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "MIDITest", True)
    r = b.call("CreateMIDIItem", count, 0.0, 4.0)
    fix.item_idx = 0
    return fix


def teardown_midi(b: ReaperBridge, fix: MIDIFixture):
    b.call("DeleteTrack", 0, fix.track_idx)


def test_create_midi_item(b: ReaperBridge, fix: MIDIFixture) -> TestResult:
    r = b.call("GetMIDIItemInfo", fix.track_idx, fix.item_idx)
    fails = expect_ok(r)
    return TestResult("create_midi_item", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_add_midi_note(b: ReaperBridge, fix: MIDIFixture) -> TestResult:
    r = b.call(
        "MIDI_InsertNote", fix.track_idx, fix.item_idx,
        False, False, 0, 960, 0, 60, 100, False
    )
    fails = expect_ok(r)
    return TestResult("add_midi_note", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_midi_notes(b: ReaperBridge, fix: MIDIFixture) -> TestResult:
    r = b.call("GetMIDINotes", fix.track_idx, fix.item_idx)
    fails = expect_ok(r) or check_fields(r, {"notes": list})
    if not fails and len(r["notes"]) < 1:
        fails.append("expected >=1 note")
    return TestResult("get_midi_notes", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_midi_note(b: ReaperBridge, fix: MIDIFixture) -> TestResult:
    b.call("MIDI_InsertNote", fix.track_idx, fix.item_idx, False, False, 960, 1920, 0, 64, 90, False)
    r = b.call("MIDI_DeleteNote", fix.track_idx, fix.item_idx, 0)
    fails = expect_ok(r)
    return TestResult("delete_midi_note", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_clear_midi_item(b: ReaperBridge, fix: MIDIFixture) -> TestResult:
    b.call("MIDI_InsertNote", fix.track_idx, fix.item_idx, False, False, 0, 480, 0, 72, 80, False)
    r = b.call("ClearMIDIItem", fix.track_idx, fix.item_idx)
    fails = expect_ok(r)
    return TestResult("clear_midi_item", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 6: Items ---


class ItemFixture:
    track_idx: int = 0


def setup_items(b: ReaperBridge) -> ItemFixture:
    fix = ItemFixture()
    count = int(b.call("CountTracks", 0).get("ret", 0))
    fix.track_idx = count
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "ItemTest", True)
    b.call("CreateMIDIItem", count, 0.0, 4.0)
    return fix


def teardown_items(b: ReaperBridge, fix: ItemFixture):
    b.call("DeleteTrack", 0, fix.track_idx)


def test_get_track_items(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("GetTrackItems", fix.track_idx)
    fails = expect_ok(r) or check_fields(r, {"items": list})
    if not fails and len(r["items"]) < 1:
        fails.append("expected >=1 item")
    return TestResult("get_track_items", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_item_info(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("GetItemInfo", fix.track_idx, 0)
    fails = expect_ok(r)
    return TestResult("get_item_info", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_item_position(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_POSITION", 1.0)
    fails = expect_ok(r)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_POSITION", 0.0)
    return TestResult("set_item_position", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_item_length(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_LENGTH", 2.0)
    fails = expect_ok(r)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_LENGTH", 4.0)
    return TestResult("set_item_length", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_item_mute(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "B_MUTE", 1)
    fails = expect_ok(r)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "B_MUTE", 0)
    return TestResult("set_item_mute", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_item_volume(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_VOL", 0.5)
    fails = expect_ok(r)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_VOL", 1.0)
    return TestResult("set_item_volume", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_item_fades(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r1 = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_FADEINLEN", 0.1)
    r2 = b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_FADEOUTLEN", 0.1)
    fails = expect_ok(r1)
    if not fails:
        fails = expect_ok(r2)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_FADEINLEN", 0)
    b.call("SetMediaItemInfo_Value", fix.track_idx, 0, "D_FADEOUTLEN", 0)
    return TestResult("set_item_fades", "FAIL" if fails else "PASS", "fadein+fadeout", fails, r1)


def test_split_item(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    r = b.call("SplitMediaItem", fix.track_idx, 0, 2.0)
    fails = expect_ok(r)
    return TestResult("split_item", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_item(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    items_before = b.call("GetTrackItems", fix.track_idx)
    n_before = len(items_before.get("items", []))
    if n_before < 1:
        return TestResult("delete_item", "SKIP", "no items to delete")
    last_idx = n_before - 1
    r = b.call("DeleteTrackMediaItem", fix.track_idx, last_idx)
    fails = expect_ok(r)
    return TestResult("delete_item", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_insert_audio_file(b: ReaperBridge, fix: ItemFixture) -> TestResult:
    wav_path = os.path.join(tempfile.gettempdir(), "harness_silence.wav")
    create_silence_wav(wav_path)
    r = b.call("InsertAudioFile", fix.track_idx, wav_path, 5.0)
    fails = expect_ok(r)
    try:
        os.unlink(wav_path)
    except OSError:
        pass
    return TestResult("insert_audio_file", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 7: Routing ---


class RoutingFixture:
    track_a: int = 0
    track_b: int = 0


def setup_routing(b: ReaperBridge) -> RoutingFixture:
    fix = RoutingFixture()
    count = int(b.call("CountTracks", 0).get("ret", 0))
    fix.track_a = count
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "RouteSrc", True)
    fix.track_b = count + 1
    b.call("InsertTrackAtIndex", count + 1, True)
    b.call("GetSetMediaTrackInfo_String", count + 1, "P_NAME", "RouteDst", True)
    return fix


def teardown_routing(b: ReaperBridge, fix: RoutingFixture):
    for idx in sorted([fix.track_a, fix.track_b], reverse=True):
        b.call("DeleteTrack", 0, idx)


def test_create_send(b: ReaperBridge, fix: RoutingFixture) -> TestResult:
    r = b.call("CreateTrackSend", fix.track_a, fix.track_b)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    return TestResult("create_send", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_track_num_sends(b: ReaperBridge, fix: RoutingFixture) -> TestResult:
    r = b.call("GetTrackNumSends", fix.track_a, 0)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    if not fails and int(r["ret"]) < 1:
        fails.append(f"expected >=1 send, got {r['ret']}")
    return TestResult("get_track_num_sends", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_send_volume(b: ReaperBridge, fix: RoutingFixture) -> TestResult:
    linear = 10 ** (-6.0 / 20)
    r = b.call("SetTrackSendUIVol", fix.track_a, 0, linear, 0)
    fails = expect_ok(r)
    return TestResult("set_send_volume", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_send_dest_channels(b: ReaperBridge, fix: RoutingFixture) -> TestResult:
    r = b.call("SetTrackSendInfo_Value", fix.track_a, 0, 0, "I_DSTCHAN", 2)
    fails = expect_ok(r)
    return TestResult("set_send_dest_channels", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_send(b: ReaperBridge, fix: RoutingFixture) -> TestResult:
    r = b.call("RemoveTrackSend", fix.track_a, 0, 0)
    fails = expect_ok(r)
    return TestResult("delete_send", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 8: Markers ---


class MarkerFixture:
    marker_idx: int = -1
    region_idx: int = -1


def setup_markers(b: ReaperBridge) -> MarkerFixture:
    return MarkerFixture()


def teardown_markers(b: ReaperBridge, fix: MarkerFixture):
    if fix.region_idx >= 0:
        b.call("DeleteProjectMarker", 0, fix.region_idx, True)
    if fix.marker_idx >= 0:
        b.call("DeleteProjectMarker", 0, fix.marker_idx, False)


def test_add_marker(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    r = b.call("AddProjectMarker2", 0, False, 1.0, 0, "TestMarker", -1, 0)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    if not fails:
        fix.marker_idx = int(r["ret"])
    return TestResult("add_marker", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_add_region(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    r = b.call("AddProjectMarker2", 0, True, 0.0, 4.0, "TestRegion", -1, 0)
    fails = expect_ok(r) or check_fields(r, {"ret": (int, float)})
    if not fails:
        fix.region_idx = int(r["ret"])
    return TestResult("add_region", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_markers(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    r = b.call("GetProjectMarkers")
    fails = expect_ok(r) or check_fields(r, {"markers": list})
    return TestResult("get_markers", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_regions(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    r = b.call("GetProjectRegions")
    fails = expect_ok(r) or check_fields(r, {"regions": list})
    return TestResult("get_regions", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_go_to_marker(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    if fix.marker_idx < 0:
        return TestResult("go_to_marker", "SKIP", "no marker created")
    r = b.call("GoToMarker", 0, fix.marker_idx, False)
    fails = expect_ok(r)
    return TestResult("go_to_marker", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_go_to_region(b: ReaperBridge, fix: MarkerFixture) -> TestResult:
    if fix.region_idx < 0:
        return TestResult("go_to_region", "SKIP", "no region created")
    r = b.call("GoToRegion", 0, fix.region_idx, False)
    fails = expect_ok(r)
    return TestResult("go_to_region", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 9: Envelopes ---


class EnvelopeFixture:
    track_idx: int = 0


def setup_envelopes(b: ReaperBridge) -> EnvelopeFixture:
    fix = EnvelopeFixture()
    count = int(b.call("CountTracks", 0).get("ret", 0))
    fix.track_idx = count
    b.call("InsertTrackAtIndex", count, True)
    b.call("GetSetMediaTrackInfo_String", count, "P_NAME", "EnvTest", True)
    # Select the track and show volume envelope (action 40406)
    b.call("Main_OnCommand", 40297, 0)  # unselect all
    b.call("SetTrackSelected", count, True)
    b.call("Main_OnCommand", 40406, 0)  # show volume envelope for selected tracks
    time.sleep(0.1)
    return fix


def teardown_envelopes(b: ReaperBridge, fix: EnvelopeFixture):
    b.call("ClearEnvelope", fix.track_idx, "Volume")
    b.call("DeleteTrack", 0, fix.track_idx)


def test_add_envelope_point(b: ReaperBridge, fix: EnvelopeFixture) -> TestResult:
    r = b.call("InsertEnvelopePoint", fix.track_idx, "Volume", 1.0, 0.75, 0, 0, False, False)
    fails = expect_ok(r)
    return TestResult("add_envelope_point", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_envelope_point_count(b: ReaperBridge, fix: EnvelopeFixture) -> TestResult:
    r = b.call("CountEnvelopePoints", fix.track_idx, "Volume")
    fails = expect_ok(r)
    return TestResult("get_envelope_point_count", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_envelope_points(b: ReaperBridge, fix: EnvelopeFixture) -> TestResult:
    r = b.call("GetEnvelopePoints", fix.track_idx, "Volume")
    fails = expect_ok(r) or check_fields(r, {"points": list})
    return TestResult("get_envelope_points", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_delete_envelope_point(b: ReaperBridge, fix: EnvelopeFixture) -> TestResult:
    b.call("InsertEnvelopePoint", fix.track_idx, "Volume", 2.0, 0.5, 0, 0, False, False)
    r = b.call("DeleteEnvelopePoint", fix.track_idx, "Volume", 0)
    fails = expect_ok(r)
    return TestResult("delete_envelope_point", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_clear_envelope(b: ReaperBridge, fix: EnvelopeFixture) -> TestResult:
    b.call("InsertEnvelopePoint", fix.track_idx, "Volume", 0.5, 0.8, 0, 0, False, False)
    r = b.call("ClearEnvelope", fix.track_idx, "Volume")
    fails = expect_ok(r)
    return TestResult("clear_envelope", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 10: Selection ---


def test_select_track(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetTrackSelected", fix.indices[0], True)
    fails = expect_ok(r)
    return TestResult("select_track", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_unselect_all_tracks(b: ReaperBridge) -> TestResult:
    r = b.call("Main_OnCommand", 40297, 0)
    fails = expect_ok(r)
    return TestResult("unselect_all_tracks", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_select_all_tracks(b: ReaperBridge) -> TestResult:
    r = b.call("Main_OnCommand", 40296, 0)
    fails = expect_ok(r)
    b.call("Main_OnCommand", 40297, 0)
    return TestResult("select_all_tracks", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_selected_tracks(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    b.call("SetTrackSelected", fix.indices[0], True)
    r = b.call("GetSelectedTracks")
    fails = expect_ok(r) or check_fields(r, {"tracks": list})
    b.call("Main_OnCommand", 40297, 0)
    return TestResult("get_selected_tracks", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_time_selection(b: ReaperBridge) -> TestResult:
    r = b.call("SetTimeSelection", 1.0, 3.0)
    fails = expect_ok(r)
    return TestResult("set_time_selection", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_time_selection(b: ReaperBridge) -> TestResult:
    b.call("SetTimeSelection", 1.0, 3.0)
    r = b.call("GetTimeSelection")
    fails = expect_ok(r) or check_fields(r, {"start": (int, float), "end": (int, float)})
    return TestResult("get_time_selection", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_clear_time_selection(b: ReaperBridge) -> TestResult:
    r = b.call("Main_OnCommand", 40635, 0)
    fails = expect_ok(r)
    return TestResult("clear_time_selection", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 11: Mixer ---


def test_set_track_phase(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "B_PHASE", 1)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "B_PHASE", 0)
    return TestResult("set_track_phase", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_width(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_WIDTH", 0.5)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "D_WIDTH", 1.0)
    return TestResult("set_track_width", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_color(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    color = (255 | (0 << 8) | (0 << 16)) | 0x1000000
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_CUSTOMCOLOR", color)
    fails = expect_ok(r)
    return TestResult("set_track_color", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_set_track_as_folder(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_FOLDERDEPTH", 1)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_FOLDERDEPTH", 0)
    return TestResult("set_track_as_folder", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_arm_track(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_RECARM", 1)
    fails = expect_ok(r)
    b.call("SetMediaTrackInfo_Value", fix.indices[0], "I_RECARM", 0)
    return TestResult("arm_track", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_track_peak(b: ReaperBridge, fix: TrackFixture) -> TestResult:
    r = b.call("Track_GetPeakInfo", fix.indices[0], 0)
    fails = expect_ok(r)
    return TestResult("get_track_peak", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 12: FX Presets ---


def test_get_fx_presets(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetPresetList", fix.track_idx, fix.eq_idx)
    fails = expect_ok(r)
    return TestResult("get_fx_presets", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_fx_preset(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("TrackFX_GetPreset", fix.track_idx, fix.eq_idx, "")
    fails = expect_ok(r)
    return TestResult("get_fx_preset", "FAIL" if fails else "PASS", brief(r), fails, r)


def test_get_fx_chunk(b: ReaperBridge, fix: FXFixture) -> TestResult:
    r = b.call("GetFXChunk", fix.track_idx, fix.eq_idx)
    fails = expect_ok(r) or check_fields(r, {"chunk": str})
    return TestResult("get_track_fx_chunk", "FAIL" if fails else "PASS", brief(r), fails, r)


# --- Phase 13: Render ---


def test_render_project(b: ReaperBridge) -> TestResult:
    length = b.call("GetProjectLength", 0)
    proj_len = length.get("length", length.get("ret", 0))
    if not proj_len or proj_len < 0.1:
        return TestResult("render_project", "SKIP", "empty project, nothing to render")
    out = os.path.join(tempfile.gettempdir(), "harness_render.wav")
    r = b.call("RenderProject", out, None, None, 0)
    fails = expect_ok(r)
    if not fails and not os.path.exists(out):
        fails.append("output file not created")
    try:
        os.unlink(out)
    except OSError:
        pass
    return TestResult("render_project", "FAIL" if fails else "PASS", brief(r), fails, r)


# ===================================================================
# TEST GROUPS
# ===================================================================

GROUPS = [
    {
        "name": "Connectivity",
        "category": "connectivity",
        "tests": [
            ("connectivity", lambda b, _: test_connectivity(b)),
        ],
    },
    {
        "name": "Project Info",
        "category": "project",
        "tests": [
            ("get_track_count", lambda b, _: test_get_track_count(b)),
            ("get_tempo", lambda b, _: test_get_tempo(b)),
            ("get_time_signature", lambda b, _: test_get_time_signature(b)),
            ("get_project_name", lambda b, _: test_get_project_name(b)),
            ("get_project_path", lambda b, _: test_get_project_path(b)),
            ("get_project_length", lambda b, _: test_get_project_length(b)),
            ("get_project_summary", lambda b, _: test_get_project_summary(b)),
            ("get_cursor_position", lambda b, _: test_get_cursor_position(b)),
            ("get_play_state", lambda b, _: test_get_play_state(b)),
            ("get_play_position", lambda b, _: test_get_play_position(b)),
        ],
    },
    {
        "name": "Transport",
        "category": "transport",
        "tests": [
            ("stop", lambda b, _: test_stop(b)),
            ("play+stop", lambda b, _: test_play_stop(b)),
            ("set_cursor_position", lambda b, _: test_set_cursor_position(b)),
            ("toggle_repeat", lambda b, _: test_toggle_repeat(b)),
        ],
    },
    {
        "name": "Tracks",
        "category": "track",
        "setup": setup_tracks,
        "teardown": teardown_tracks,
        "tests": [
            ("insert_track+name", lambda b, _: test_insert_track_with_name(b)),
            ("get_track", lambda b, f: test_get_track(b, f)),
            ("get_all_tracks", lambda b, f: test_get_all_tracks(b, f)),
            ("get_master_track", lambda b, _: test_get_master_track(b)),
            ("set_track_name", lambda b, f: test_set_track_name(b, f)),
            ("set_track_volume", lambda b, f: test_set_track_volume(b, f)),
            ("set_track_pan", lambda b, f: test_set_track_pan(b, f)),
            ("set_track_mute", lambda b, f: test_set_track_mute(b, f)),
            ("set_track_solo", lambda b, f: test_set_track_solo(b, f)),
            ("delete_track", lambda b, _: test_delete_track(b)),
            ("delete_master", lambda b, _: test_delete_master_rejected(b)),
        ],
    },
    {
        "name": "FX",
        "category": "fx",
        "setup": setup_fx,
        "teardown": teardown_fx,
        "tests": [
            ("track_fx_get_count", lambda b, f: test_fx_get_count(b, f)),
            ("track_fx_get_list", lambda b, f: test_fx_get_list(b, f)),
            ("track_fx_get_name", lambda b, f: test_fx_get_name(b, f)),
            ("track_fx_get_enabled", lambda b, f: test_fx_get_enabled(b, f)),
            ("track_fx_set_enabled", lambda b, f: test_fx_set_enabled(b, f)),
            ("track_fx_get_num_params", lambda b, f: test_fx_get_num_params(b, f)),
            ("track_fx_get_param", lambda b, f: test_fx_get_param(b, f)),
            ("track_fx_set_param", lambda b, f: test_fx_set_param(b, f)),
            ("track_fx_get_param_name", lambda b, f: test_fx_get_param_name(b, f)),
            ("track_fx_add+delete", lambda b, f: test_fx_add_delete(b, f)),
        ],
    },
    {
        "name": "MIDI",
        "category": "midi",
        "setup": setup_midi,
        "teardown": teardown_midi,
        "tests": [
            ("create_midi_item", lambda b, f: test_create_midi_item(b, f)),
            ("add_midi_note", lambda b, f: test_add_midi_note(b, f)),
            ("get_midi_notes", lambda b, f: test_get_midi_notes(b, f)),
            ("delete_midi_note", lambda b, f: test_delete_midi_note(b, f)),
            ("clear_midi_item", lambda b, f: test_clear_midi_item(b, f)),
        ],
    },
    {
        "name": "Items",
        "category": "item",
        "setup": setup_items,
        "teardown": teardown_items,
        "tests": [
            ("get_track_items", lambda b, f: test_get_track_items(b, f)),
            ("get_item_info", lambda b, f: test_get_item_info(b, f)),
            ("set_item_position", lambda b, f: test_set_item_position(b, f)),
            ("set_item_length", lambda b, f: test_set_item_length(b, f)),
            ("set_item_mute", lambda b, f: test_set_item_mute(b, f)),
            ("set_item_volume", lambda b, f: test_set_item_volume(b, f)),
            ("set_item_fades", lambda b, f: test_set_item_fades(b, f)),
            ("split_item", lambda b, f: test_split_item(b, f)),
            ("insert_audio_file", lambda b, f: test_insert_audio_file(b, f)),
            ("delete_item", lambda b, f: test_delete_item(b, f)),
        ],
    },
    {
        "name": "Routing",
        "category": "routing",
        "setup": setup_routing,
        "teardown": teardown_routing,
        "tests": [
            ("create_send", lambda b, f: test_create_send(b, f)),
            ("get_track_num_sends", lambda b, f: test_get_track_num_sends(b, f)),
            ("set_send_volume", lambda b, f: test_set_send_volume(b, f)),
            ("set_send_dest_channels", lambda b, f: test_set_send_dest_channels(b, f)),
            ("delete_send", lambda b, f: test_delete_send(b, f)),
        ],
    },
    {
        "name": "Markers & Regions",
        "category": "marker",
        "setup": setup_markers,
        "teardown": teardown_markers,
        "tests": [
            ("add_marker", lambda b, f: test_add_marker(b, f)),
            ("add_region", lambda b, f: test_add_region(b, f)),
            ("get_markers", lambda b, f: test_get_markers(b, f)),
            ("get_regions", lambda b, f: test_get_regions(b, f)),
            ("go_to_marker", lambda b, f: test_go_to_marker(b, f)),
            ("go_to_region", lambda b, f: test_go_to_region(b, f)),
        ],
    },
    {
        "name": "Envelopes",
        "category": "envelope",
        "setup": setup_envelopes,
        "teardown": teardown_envelopes,
        "tests": [
            ("add_envelope_point", lambda b, f: test_add_envelope_point(b, f)),
            ("get_envelope_point_count", lambda b, f: test_get_envelope_point_count(b, f)),
            ("get_envelope_points", lambda b, f: test_get_envelope_points(b, f)),
            ("delete_envelope_point", lambda b, f: test_delete_envelope_point(b, f)),
            ("clear_envelope", lambda b, f: test_clear_envelope(b, f)),
        ],
    },
    {
        "name": "Selection",
        "category": "selection",
        "setup": setup_tracks,
        "teardown": teardown_tracks,
        "tests": [
            ("select_track", lambda b, f: test_select_track(b, f)),
            ("unselect_all_tracks", lambda b, _: test_unselect_all_tracks(b)),
            ("select_all_tracks", lambda b, _: test_select_all_tracks(b)),
            ("get_selected_tracks", lambda b, f: test_get_selected_tracks(b, f)),
            ("set_time_selection", lambda b, _: test_set_time_selection(b)),
            ("get_time_selection", lambda b, _: test_get_time_selection(b)),
            ("clear_time_selection", lambda b, _: test_clear_time_selection(b)),
        ],
    },
    {
        "name": "Mixer",
        "category": "mixer",
        "setup": setup_tracks,
        "teardown": teardown_tracks,
        "tests": [
            ("set_track_phase", lambda b, f: test_set_track_phase(b, f)),
            ("set_track_width", lambda b, f: test_set_track_width(b, f)),
            ("set_track_color", lambda b, f: test_set_track_color(b, f)),
            ("set_track_as_folder", lambda b, f: test_set_track_as_folder(b, f)),
            ("arm_track", lambda b, f: test_arm_track(b, f)),
            ("get_track_peak", lambda b, f: test_get_track_peak(b, f)),
        ],
    },
    {
        "name": "FX Presets",
        "category": "preset",
        "setup": setup_fx,
        "teardown": teardown_fx,
        "tests": [
            ("get_fx_presets", lambda b, f: test_get_fx_presets(b, f)),
            ("get_fx_preset", lambda b, f: test_get_fx_preset(b, f)),
            ("get_track_fx_chunk", lambda b, f: test_get_fx_chunk(b, f)),
        ],
    },
    {
        "name": "Render",
        "category": "render",
        "tests": [
            ("render_project", lambda b, _: test_render_project(b)),
        ],
    },
]


# ===================================================================
# RUNNER
# ===================================================================


def run_group(bridge: ReaperBridge, group: dict, verbose: bool = False) -> list[TestResult]:
    results = []
    fixture = None

    if "setup" in group:
        try:
            fixture = group["setup"](bridge)
        except Exception as e:
            results.append(TestResult(
                f"{group['name']}_setup", "ERROR", str(e),
            ))
            return results

    for test_name, test_fn in group["tests"]:
        start = time.time()
        try:
            result = test_fn(bridge, fixture)
            result.duration_ms = (time.time() - start) * 1000
        except Exception as e:
            result = TestResult(
                test_name, "ERROR", str(e),
                duration_ms=(time.time() - start) * 1000,
            )
        results.append(result)

    if "teardown" in group and fixture is not None:
        try:
            group["teardown"](bridge, fixture)
        except Exception:
            pass

    return results


# ===================================================================
# REPORT
# ===================================================================


STATUS_COLORS = {"PASS": GREEN, "FAIL": RED, "SKIP": YELLOW, "ERROR": MAGENTA}


def print_report(all_results: dict[str, list[TestResult]], verbose: bool = False):
    total = sum(len(r) for r in all_results.values())
    passed = sum(1 for rs in all_results.values() for r in rs if r.status == "PASS")
    failed = sum(1 for rs in all_results.values() for r in rs if r.status == "FAIL")
    skipped = sum(1 for rs in all_results.values() for r in rs if r.status == "SKIP")
    errors = sum(1 for rs in all_results.values() for r in rs if r.status == "ERROR")

    print()
    print(c(BOLD, "=" * 60))
    print(c(BOLD, " REAPER MCP Live Integration Test"))
    print(c(DIM, f" {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"))
    print(c(BOLD, "=" * 60))

    for group_name, results in all_results.items():
        print()
        print(c(CYAN, f"[{group_name}]"))
        for r in results:
            color = STATUS_COLORS.get(r.status, "")
            status = c(color, f"  {r.status:5s}")
            name = f"{r.name:<28s}"
            detail = r.detail[:40] if r.detail else ""
            ms = c(DIM, f"{r.duration_ms:6.0f}ms")
            print(f"{status} {name} {detail:<42s} {ms}")
            if r.status == "FAIL" and r.failures:
                for f in r.failures:
                    print(c(RED, f"        {f}"))
            if verbose and r.response:
                print(c(DIM, f"        {json.dumps(r.response, default=str)[:120]}"))

    print()
    print(c(BOLD, "=" * 60))
    summary_parts = [f"{c(GREEN, str(passed))} pass"]
    if failed:
        summary_parts.append(f"{c(RED, str(failed))} fail")
    if skipped:
        summary_parts.append(f"{c(YELLOW, str(skipped))} skip")
    if errors:
        summary_parts.append(f"{c(MAGENTA, str(errors))} error")
    print(f" {c(BOLD, 'TOTAL:')} {total} tests — {', '.join(summary_parts)}")
    print(c(BOLD, "=" * 60))

    if failed or errors:
        print()
        print(c(RED, " Failures:"))
        for group_name, results in all_results.items():
            for r in results:
                if r.status in ("FAIL", "ERROR"):
                    detail = "; ".join(r.failures) if r.failures else r.detail
                    print(f"   {r.name}: {detail}")


def print_json(all_results: dict[str, list[TestResult]]):
    output = {}
    for group_name, results in all_results.items():
        output[group_name] = [
            {
                "name": r.name,
                "status": r.status,
                "detail": r.detail,
                "failures": r.failures,
                "duration_ms": round(r.duration_ms, 1),
            }
            for r in results
        ]
    print(json.dumps(output, indent=2))


# ===================================================================
# MAIN
# ===================================================================


def main():
    parser = argparse.ArgumentParser(description="REAPER MCP Live Integration Test Harness")
    parser.add_argument("--category", help="Run only this category")
    parser.add_argument("--timeout", type=float, default=8.0, help="Bridge timeout (seconds)")
    parser.add_argument("--bridge-dir", help="Bridge directory override")
    parser.add_argument("--verbose", action="store_true", help="Show full responses")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--list", action="store_true", help="List categories and exit")
    args = parser.parse_args()

    if args.list:
        for g in GROUPS:
            tests = ", ".join(name for name, _ in g["tests"])
            print(f"  {g['category']:<14s} {g['name']:<20s} ({len(g['tests'])} tests)")
        return

    bridge = ReaperBridge(bridge_dir=args.bridge_dir, timeout=args.timeout)

    if not bridge.bridge_dir.exists():
        print(c(RED, f"Bridge directory not found: {bridge.bridge_dir}"))
        print("Make sure REAPER is running with the Lua bridge script loaded.")
        sys.exit(1)

    groups = GROUPS
    if args.category:
        groups = [g for g in GROUPS if g["category"] == args.category]
        if not groups:
            cats = ", ".join(g["category"] for g in GROUPS)
            print(c(RED, f"Unknown category '{args.category}'. Available: {cats}"))
            sys.exit(1)

    conn = test_connectivity(bridge)
    if conn.status != "PASS":
        print(c(RED, "Cannot reach REAPER bridge. Is REAPER running with the bridge script?"))
        if conn.failures:
            for f in conn.failures:
                print(c(RED, f"  {f}"))
        sys.exit(1)

    all_results: dict[str, list[TestResult]] = {}
    for group in groups:
        results = run_group(bridge, group, verbose=args.verbose)
        all_results[group["name"]] = results

    if args.json:
        print_json(all_results)
    else:
        print_report(all_results, verbose=args.verbose)

    has_failures = any(r.status in ("FAIL", "ERROR") for rs in all_results.values() for r in rs)
    sys.exit(1 if has_failures else 0)


if __name__ == "__main__":
    main()
