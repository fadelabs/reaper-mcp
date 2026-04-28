# Reaper MCP Server — Audit Fix Plan

**Date:** 2026-04-27
**Scope:** All issues found in deep audit of the reaper-mcp codebase
**Primary path:** MCP server (`reaper_mcp_server.py`) → file-based bridge (`reaper_mcp_bridge.lua`)
**Decision:** Deprecate the Python web server (`reaper_web_server.py`). The default communication mode is file-based (Lua bridge), which is the most complete implementation. The Python HTTP bridge is missing ~30 handlers and would require significant work to catch up. The Lua HTTP bridge (`reaper_web_server.lua`) remains as a secondary option for users who prefer HTTP. No work will be done on `reaper_web_server.py`.

---

## Phase 1: Critical Bugs (data loss / wrong behavior)

### 1.1 — `track_fx_get_list` returns wrong data
- **File:** `reaper_mcp_server.py:343`
- **Problem:** Calls `GetTrackInfo` which returns track name/volume/pan — not FX list
- **Fix:** Call a dedicated `GetTrackFXList` function that iterates FX on the track and returns name/index/enabled for each. Add handler to the Lua file bridge (`reaper_mcp_bridge.lua`) and Lua HTTP server (`reaper_web_server.lua`) that calls `TrackFX_GetCount` + `TrackFX_GetFXName` + `TrackFX_GetEnabled` per FX
- **Test:** Call `track_fx_get_list` on a track with known FX, verify response contains FX array

### 1.2 — `insert_track` sets name on wrong track
- **File:** `reaper_mcp_server.py:237`
- **Problem:** Passes extra `0` arg to `GetSetMediaTrackInfo_String`, so `args[0]` is `0` (project) not the track index — name always goes to track 0
- **Fix:** Change to `await reaper_call("GetSetMediaTrackInfo_String", index, "P_NAME", name, True)` — same arg signature as `set_track_name`
- **Test:** Insert a track with a name at the end of a multi-track project, verify the new track (not track 0) gets the name

### 1.3 — `create_project` ignores `name` parameter
- **File:** `reaper_mcp_server.py:1304-1317`
- **Problem:** Accepts `name` but just calls `Main_SaveProject` which doesn't rename anything
- **Fix:** Either remove the `name` parameter and document that projects must be saved/named manually, or pass the name as the save path. Simplest: remove `name`, add a docstring note. The "save if name" logic is misleading — saving a new untitled project just saves as "untitled"
- **Test:** Verify `create_project()` creates a new project without error

### 1.4 — Request counter collision in file-based bridge
- **File:** `reaper_mcp_server.py:57,102-103`
- **Problem:** Global counter wrapping at 999 with no lock; concurrent calls can collide
- **Fix:** Use a combination of PID + monotonic timestamp + counter for unique filenames, or use `uuid4().hex[:8]` for request IDs
- **Test:** N/A (race condition — fix is structural)

### 1.5 — `BRIDGE_DIR` default is Windows-only
- **File:** `reaper_mcp_server.py:43-46`
- **Problem:** `%APPDATA%` doesn't expand on macOS/Linux
- **Fix:** Detect platform and set appropriate default:
  - macOS: `~/Library/Application Support/REAPER/Scripts/mcp_bridge_data`
  - Linux: `~/.config/REAPER/Scripts/mcp_bridge_data`
  - Windows: `%APPDATA%/REAPER/Scripts/mcp_bridge_data`
- **Test:** Verify `BRIDGE_DIR` resolves to a real path on macOS

---

## Phase 2: Deprecate Python Web Server & Verify Lua Bridge Coverage

### 2.1 — Deprecate `reaper_web_server.py`
- **File:** `reaper_web_server.py`
- **Problem:** Missing ~30 function handlers vs the Lua bridge. The default communication mode is file-based (Lua), so this server is a secondary path that's significantly behind
- **Action:** Add a deprecation notice to the top of the file and the README. Do NOT backfill handlers — not worth the maintenance burden
- **Note:** Keep the file in the repo for now (some users may depend on it), but mark it as unsupported

### 2.2 — Verify Lua file bridge covers all MCP tool functions
- **File:** `reaper_mcp_bridge.lua`
- **Problem:** Need to confirm the Lua file bridge (default path) has handlers for every function the MCP server calls
- **Action:** Cross-reference every `reaper_call("FunctionName", ...)` in `reaper_mcp_server.py` against handlers in `reaper_mcp_bridge.lua`. Add any missing handlers to the Lua bridge
- **Key functions to verify exist:**
  - `GetTrackFXList` (new, for fix 1.1)
  - `SetTrackSendUIVol`
  - `SetTimeSelection`
  - `GetProjectSummary`
  - `RenderProject` / `RenderRegion`
  - `SetTimeSignature`
  - `Main_openProject`
  - `Main_OnCommandEx`
  - All MIDI functions (`MIDI_InsertNote`, `GetMIDINotes`, `MIDI_DeleteNote`, `ClearMIDIItem`, `MIDI_SetNote`, `CreateMIDIItem`, `GetMIDIItemInfo`)
  - All envelope functions (`CountEnvelopePoints`, `InsertEnvelopePoint`, `GetEnvelopePoints`, `DeleteEnvelopePoint`, `ClearEnvelope`, `SetEnvelopeArm`, `GetTrackEnvelopeByName`)
  - All FX preset functions (`TrackFX_GetPresetList`, `TrackFX_GetPreset`, `TrackFX_SetPreset`, `TrackFX_SavePreset`, `GetFXChunk`)
  - `Track_GetPeakInfo`
  - `InsertAudioFile`, `DuplicateItem`, `SplitMediaItem`, `DeleteTrackMediaItem`, `GetItemInfo`

### 2.3 — Verify Lua HTTP server covers all MCP tool functions (secondary)
- **File:** `reaper_web_server.lua`
- **Action:** Same cross-reference as 2.2 but for the Lua HTTP server's `handle_function_call()`. Lower priority since this is the secondary path, but it should match the file bridge for users who prefer HTTP

---

## Phase 3: Security & Reliability

### 3.1 — Replace sync HTTP client with async
- **File:** `reaper_mcp_server.py:60-68, 73-97`
- **Problem:** `httpx.Client` (sync) blocks the async event loop
- **Fix:** Replace with `httpx.AsyncClient`, change `client.post()` to `await client.post()`. Add proper lifecycle management (create on first use, close on shutdown)

### 3.2 — Close HTTP client on shutdown
- **File:** `reaper_mcp_server.py`
- **Fix:** Add `atexit` handler or use `contextlib.asynccontextmanager` to close the client. Or create/close per-request if connection pooling isn't critical

### 3.3 — Lua `json_decode` code injection
- **File:** `reaper_web_server.lua:102-118`
- **Problem:** `load("return " .. str)` executes arbitrary Lua from HTTP request bodies
- **Fix:** Replace with a proper recursive-descent JSON parser (like the one already in `reaper_mcp_bridge.lua:48-158`). Copy that implementation to `reaper_web_server.lua`
- **Impact:** Prevents arbitrary code execution via crafted HTTP requests

### 3.4 — Restrict CORS to localhost
- **File:** `reaper_web_server.lua:167`
- **Problem:** `Access-Control-Allow-Origin: *` lets any website control REAPER
- **Fix:** Change to `Access-Control-Allow-Origin: http://localhost` or remove CORS headers entirely (MCP server connects locally, doesn't need CORS)

### 3.5 — Fix bare `except:` clauses
- **File:** `reaper_mcp_server.py:117,133-134,144`
- **Fix:** Change to `except OSError:` or `except (OSError, PermissionError):` — only catch filesystem errors

### 3.6 — Atomic file writes in file-based bridge
- **File:** `reaper_mcp_server.py:121`
- **Fix:** Write to a temp file in the same directory, then `os.rename()` to the target path. Rename is atomic on the same filesystem

---

## Phase 4: Error Handling & Robustness

### 4.1 — `add_mastering_chain` should check each FX add
- **File:** `reaper_mcp_server.py:784-793`
- **Fix:** Check each `result.get("ret", -1)` — if negative, the plugin wasn't found. Collect failures and report them. Only return `"ok": True` if all FX were added

### 4.2 — `add_parallel_compression` should check track creation
- **File:** `reaper_mcp_server.py:816-833`
- **Fix:** Check `InsertTrackAtIndex` result, check `CreateTrackSend` result, check `TrackFX_AddByName` result. Return early with error details if any step fails

### 4.3 — `create_bus` should check track creation
- **File:** `reaper_mcp_server.py:855-873`
- **Fix:** Same pattern — verify track was created before creating sends

### 4.4 — `setup_sidechain_send` should validate send_index
- **File:** `reaper_mcp_server.py:577-598`
- **Fix:** Check `send_result.get("ok")` before using `send_result.get("ret")`. Don't default to 0

### 4.5 — Add input validation for common parameters
- **File:** `reaper_mcp_server.py` (various tools)
- **Fix:** Add bounds checking where practical:
  - `velocity`: clamp 1-127
  - `pitch`: clamp 0-127
  - `channel`: clamp 0-15
  - `pan`: already clamped (line 287) — good
  - `width`: already clamped (line 1845) — good

---

## Phase 5: Cleanup & Consistency

### 5.1 — Fix `COMM_MODE` documentation
- **File:** `reaper_mcp_server.py:51,165-166`
- **Problem:** Comment on line 166 says "auto (default)" but code defaults to "file"
- **Fix:** Either change the default to "auto" (recommended — http with file fallback makes more sense) or update the comment

### 5.2 — Deduplicate JSON encode/decode in Lua files
- **Files:** `reaper_mcp_bridge.lua`, `reaper_web_server.lua`
- **Fix:** Extract shared JSON module or pick the better implementation (bridge version handles more edge cases) and use it in both. Note: Lua module loading in REAPER is constrained, so the pragmatic fix may be to just ensure both implementations match

### 5.3 — Empty table serialization in Lua JSON encoder
- **File:** `reaper_web_server.lua:83`
- **Fix:** Handle empty tables explicitly — default to `[]` for empty tables in array context (or add an explicit marker)

### 5.4 — Remove `name` param from `create_project` or implement it
- **File:** `reaper_mcp_server.py:1304-1317`
- **Fix:** Remove the parameter since it doesn't work as advertised. Update docstring

---

## Execution Order

| Priority | Phase | Risk | Effort |
|----------|-------|------|--------|
| 1 | 1.1 — `track_fx_get_list` wrong data | High | Small |
| 2 | 1.2 — `insert_track` names wrong track | High | Small |
| 3 | 3.3 — Lua code injection | High | Medium |
| 4 | 2.1 — Deprecate Python web server | High | Small |
| 5 | 2.2 — Verify Lua file bridge coverage | High | Medium |
| 6 | 3.1 — Async HTTP client | High | Small |
| 7 | 1.5 — Bridge dir platform detection | Medium | Small |
| 8 | 3.4 — CORS restriction | Medium | Small |
| 9 | 4.1-4.5 — Error handling | Medium | Medium |
| 10 | 2.3 — Verify Lua HTTP server coverage | Medium | Medium |
| 11 | 3.5 — Bare excepts | Low | Small |
| 12 | 3.6 — Atomic file writes | Low | Small |
| 13 | 1.4 — Request counter collision | Low | Small |
| 14 | 5.1-5.4 — Cleanup | Low | Small |
| 15 | 1.3 — `create_project` name param | Low | Small |

---

## Architecture Decision: Deprecate Python Web Server

The three bridge implementations (Python HTTP, Lua HTTP, Lua file-based) create a maintenance burden where every new function handler must be added in three places. The Python web server is ~30 handlers behind and would take significant effort to backfill.

**Decision:** Focus on the two Lua paths only.

- **Primary:** Lua file-based bridge (`reaper_mcp_bridge.lua`) — default `COMM_MODE`, most complete, no extra dependencies
- **Secondary:** Lua HTTP server (`reaper_web_server.lua`) — for users who prefer HTTP, already more complete than Python
- **Deprecated:** Python HTTP server (`reaper_web_server.py`) — mark as unsupported, keep in repo

This reduces the maintenance surface from 3 implementations to 2. Both Lua implementations share the same REAPER API patterns and can share JSON encode/decode code (see 5.2).

## Notes

- The Lua file bridge is the default path and should be the primary target for all fixes
- When adding new MCP tools in the future, add handlers to both Lua files (bridge + HTTP server) — skip the Python web server
- The MCP server itself (`reaper_mcp_server.py`) still needs all fixes in Phases 1, 3, 4, and 5 since it's the entry point regardless of bridge choice
