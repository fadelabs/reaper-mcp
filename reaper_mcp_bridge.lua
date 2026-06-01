-- REAPER MCP Bridge
-- This single bridge supports ALL profiles and includes:
-- - All ReaScript API functions (600+)
-- - All DSL (Domain Specific Language) functions for natural language control
-- Profile selection is handled by the Python MCP server, not this bridge

local bridge_dir = reaper.GetResourcePath() .. '/Scripts/mcp_bridge_data/'

-- Create bridge directory if it doesn't exist
local function ensure_dir()
    reaper.RecursiveCreateDirectory(bridge_dir, 0)
end

-- Simple JSON encoding (minimal implementation)
local function encode_json(v)
    if type(v) == "nil" then
        return "null"
    elseif type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "number" then
        return tostring(v)
    elseif type(v) == "string" then
        -- Escape backslashes first, then other special chars
        return string.format('"%s"', v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'))
    elseif type(v) == "table" then
        local parts = {}
        local is_array = v.__is_array or #v > 0
        if is_array then
            for i, item in ipairs(v) do
                table.insert(parts, encode_json(item))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, item in pairs(v) do
                if k ~= "__is_array" then
                    table.insert(parts, string.format('"%s":%s', k, encode_json(item)))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif type(v) == "userdata" then
        -- Handle userdata (pointers) by converting to a handle ID
        return encode_json({__ptr = tostring(v)})
    else
        return "null"
    end
end

-- Better JSON decoding that handles arrays properly
local function decode_json(str)
    if not str or str == "" then return nil end
    
    -- Remove whitespace
    str = str:gsub("^%s*(.-)%s*$", "%1")
    
    -- Very basic JSON decoder
    if str == "null" then return nil
    elseif str == "true" then return true
    elseif str == "false" then return false
    elseif str:match("^%-?%d+%.?%d*$") then return tonumber(str)
    elseif str:match('^"(.*)"$') then 
        -- Unescape string
        local s = str:match('^"(.*)"$')
        s = s:gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\"', '"')
        return s
    elseif str:match("^%[.*%]$") then
        -- Array - improved parsing
        local arr = {}
        local content = str:sub(2, -2)
        if content ~= "" then
            -- Handle nested structures better
            local i = 1
            local pos = 1
            local depth = 0
            local start = 1
            
            while pos <= #content do
                local char = content:sub(pos, pos)
                if char == '[' or char == '{' then
                    depth = depth + 1
                elseif char == ']' or char == '}' then
                    depth = depth - 1
                elseif char == ',' and depth == 0 then
                    -- Found a top-level comma
                    local value = content:sub(start, pos - 1)
                    arr[i] = decode_json(value:match("^%s*(.-)%s*$"))
                    i = i + 1
                    start = pos + 1
                end
                pos = pos + 1
            end
            
            -- Don't forget the last element
            if start <= #content then
                local value = content:sub(start)
                arr[i] = decode_json(value:match("^%s*(.-)%s*$"))
            end
        end
        return arr
    elseif str:match("^{.*}$") then
        -- Object - improved parsing
        local obj = {}
        local content = str:sub(2, -2)
        
        -- Better object parsing that handles nested values
        local pos = 1
        while pos <= #content do
            -- Find key
            local key_start = content:find('"', pos)
            if not key_start then break end
            local key_end = content:find('"', key_start + 1)
            if not key_end then break end
            local key = content:sub(key_start + 1, key_end - 1)
            
            -- Find colon
            local colon = content:find(':', key_end + 1)
            if not colon then break end
            
            -- Find value (handle nested structures)
            local value_start = colon + 1
            while value_start <= #content and content:sub(value_start, value_start):match("%s") do
                value_start = value_start + 1
            end
            
            local value_end = value_start
            local depth = 0
            local in_string = false
            local escape = false
            
            while value_end <= #content do
                local char = content:sub(value_end, value_end)
                
                if escape then
                    escape = false
                elseif char == '\\' then
                    escape = true
                elseif char == '"' and not escape then
                    in_string = not in_string
                elseif not in_string then
                    if char == '[' or char == '{' then
                        depth = depth + 1
                    elseif char == ']' or char == '}' then
                        depth = depth - 1
                    elseif (char == ',' or char == '}') and depth == 0 then
                        break
                    end
                end
                
                value_end = value_end + 1
            end
            
            local value = content:sub(value_start, value_end - 1)
            obj[key] = decode_json(value:match("^%s*(.-)%s*$"))
            
            pos = value_end + 1
        end
        
        return obj
    end
    return nil
end

-- Read file contents
local function read_file(filepath)
    local file = io.open(filepath, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

-- Write file contents
local function write_file(filepath, content)
    local file = io.open(filepath, "w")
    if not file then return false end
    file:write(content)
    file:close()
    return true
end

-- Check if file exists
local function file_exists(filepath)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Delete file
local function delete_file(filepath)
    os.remove(filepath)
end


-- ============================================================================
-- DSL HELPER FUNCTIONS
-- ============================================================================

-- ============================================================================
-- DSL HELPER FUNCTIONS
-- ============================================================================

-- Get detailed track information including MIDI/audio content and FX
local function GetTrackInfo(track_index)
    local track = nil
    if track_index == -1 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_index)
    end
    
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    -- Get track info
    local retval, name = reaper.GetTrackName(track)
    local retval, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    
    -- Check for MIDI and audio items
    local has_midi = false
    local has_audio = false
    local item_count = reaper.CountTrackMediaItems(track)
    
    for i = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item then
            local take = reaper.GetActiveTake(item)
            if take then
                if reaper.TakeIsMIDI(take) then
                    has_midi = true
                else
                    has_audio = true
                end
            end
        end
    end
    
    -- Get FX names
    local fx_names = {__is_array = true}
    local fx_count = reaper.TrackFX_GetCount(track)
    for i = 0, fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(track, i, "")
        if retval then
            table.insert(fx_names, fx_name)
        end
    end
    
    -- Check for role in track notes
    local retval, notes = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:role", "", false)
    local role = nil
    if notes and notes ~= "" then
        role = notes
    end
    
    return {
        ok = true,
        info = {
            guid = guid,
            name = name,
            has_midi = has_midi,
            has_audio = has_audio,
            fx_names = fx_names,
            role = role,
            muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1,
            soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0
        }
    }
end

-- Get list of all FX plugins on a track with index, name, and enabled state
local function GetTrackFXList(track_index)
    local track = nil
    if track_index == -1 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_index)
    end

    if not track then
        return {ok = false, error = "Track not found"}
    end

    local fx_count = reaper.TrackFX_GetCount(track)
    local fx_list = {}
    for i = 0, fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(track, i, "")
        local enabled = reaper.TrackFX_GetEnabled(track, i)
        table.insert(fx_list, {
            index = i,
            name = fx_name,
            enabled = enabled
        })
    end

    return {ok = true, track_index = track_index, fx = fx_list}
end

-- Get all tracks with detailed info
local function GetAllTracksInfo()
    local tracks = {__is_array = true}
    local count = reaper.CountTracks(0)
    
    for i = 0, count - 1 do
        local result = GetTrackInfo(i)
        if result.ok then
            local info = result.info
            info.index = i
            table.insert(tracks, info)
        end
    end
    
    return {ok = true, tracks = tracks}
end

-- Get selected tracks
local function GetSelectedTracks()
    local selected = {}
    local count = reaper.CountTracks(0)
    for i = 0, count - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.IsTrackSelected(track) then
            table.insert(selected, i)
        end
    end
    return {ok = true, tracks = selected}
end

-- Get/Set track notes (used for storing role)
local function SetTrackNotes(track_index, notes)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    -- Store in extended state
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:role", notes, true)
    return {ok = true}
end

-- Get current cursor position
local function GetCursorPosition()
    local pos = reaper.GetCursorPosition()
    return {ok = true, ret = pos}
end

-- Get time selection
local function GetTimeSelection()
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    return {ok = true, start = start_time, ["end"] = end_time}
end

-- Set time selection
local function SetTimeSelection(start_time, end_time)
    reaper.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
    return {ok = true}
end

-- Get loop time range
local function GetLoopTimeRange()
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
    return {ok = true, start = start_time, ["end"] = end_time}
end

-- Convert bars to time duration
local function BarsToTime(bars, start_pos)
    -- Get tempo at position
    local tempo = reaper.Master_GetTempo()
    local retval, num, denom = reaper.TimeMap_GetTimeSigAtTime(0, start_pos or 0)
    
    -- Calculate duration
    local beats_per_bar = num
    local total_beats = bars * beats_per_bar
    local duration = (total_beats / tempo) * 60
    
    return {ok = true, ret = duration}
end

-- Find region by name
local function FindRegion(name)
    local retval, num_markers, num_regions = reaper.CountProjectMarkers(0)
    
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, rgn_name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if isrgn and rgn_name == name then
            return {ok = true, found = true, start = pos, ["end"] = rgnend}
        end
    end
    
    return {ok = true, found = false}
end

-- Find marker by name
local function FindMarker(name)
    local retval, num_markers, num_regions = reaper.CountProjectMarkers(0)
    
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, marker_name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if not isrgn and marker_name == name then
            return {ok = true, found = true, position = pos}
        end
    end
    
    return {ok = true, found = false}
end

-- Get selected items
local function GetSelectedItems()
    local items = {__is_array = true}
    local count = reaper.CountSelectedMediaItems(0)
    
    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        if item then
            local track = reaper.GetMediaItem_Track(item)
            local track_index = -1
            
            -- Find track index
            for j = 0, reaper.CountTracks(0) - 1 do
                if reaper.GetTrack(0, j) == track then
                    track_index = j
                    break
                end
            end
            
            local take = reaper.GetActiveTake(item)
            local is_midi = take and reaper.TakeIsMIDI(take)
            local retval, name = reaper.GetTakeName(take or item)
            
            table.insert(items, {
                index = i,
                track_index = track_index,
                position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                name = name,
                is_midi = is_midi
            })
        end
    end
    
    return {ok = true, items = items}
end

-- Get all items
local function GetAllItems()
    local items = {__is_array = true}
    local track_count = reaper.CountTracks(0)
    
    for t = 0, track_count - 1 do
        local track = reaper.GetTrack(0, t)
        local item_count = reaper.CountTrackMediaItems(track)
        
        for i = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            if item then
                local take = reaper.GetActiveTake(item)
                local is_midi = take and reaper.TakeIsMIDI(take)
                local retval, name = reaper.GetTakeName(take or item)
                
                table.insert(items, {
                    index = i,
                    track_index = t,
                    position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                    length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                    name = name,
                    is_midi = is_midi
                })
            end
        end
    end
    
    return {ok = true, items = items}
end

-- Get items on specific track
local function GetTrackItems(track_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end

    local items = {__is_array = true}
    local item_count = reaper.CountTrackMediaItems(track)
    
    for i = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item then
            local take = reaper.GetActiveTake(item)
            local is_midi = take and reaper.TakeIsMIDI(take)
            local retval, name = reaper.GetTakeName(take or item)
            
            table.insert(items, {
                index = i,
                track_index = track_index,
                position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                name = name,
                is_midi = is_midi
            })
        end
    end
    
    return {ok = true, items = items}
end

-- Create MIDI item
local function CreateMIDIItem(track_index, start_pos, end_pos)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local item = reaper.CreateNewMIDIItemInProj(track, start_pos, end_pos, false)
    if not item then
        return {ok = false, error = "Failed to create MIDI item"}
    end
    
    -- Find item index on track
    local item_index = -1
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        if reaper.GetTrackMediaItem(track, i) == item then
            item_index = i
            break
        end
    end
    
    return {ok = true, item_index = item_index}
end

-- Create audio item (empty)
local function CreateAudioItem(track_index, start_pos, end_pos)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    -- Create empty item
    local item = reaper.AddMediaItemToTrack(track)
    if not item then
        return {ok = false, error = "Failed to create audio item"}
    end
    
    -- Set position and length
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", start_pos)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", end_pos - start_pos)
    
    -- Find item index on track
    local item_index = -1
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        if reaper.GetTrackMediaItem(track, i) == item then
            item_index = i
            break
        end
    end
    
    return {ok = true, item_index = item_index}
end

-- Insert audio file onto a specific track at a given position
local function InsertAudioFile(track_index, file_path, position)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found at index " .. tostring(track_index)}
    end

    local source = reaper.PCM_Source_CreateFromFile(file_path)
    if not source then
        return {ok = false, error = "Failed to create source from file: " .. tostring(file_path)}
    end

    local item = reaper.AddMediaItemToTrack(track)
    if not item then
        return {ok = false, error = "Failed to create media item"}
    end

    local take = reaper.AddTakeToMediaItem(item)
    if not take then
        return {ok = false, error = "Failed to create take"}
    end

    reaper.SetMediaItemTake_Source(take, source)
    reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0)

    local length = reaper.GetMediaSourceLength(source)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", position or 0)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)

    reaper.UpdateArrange()
    reaper.UpdateItemInProject(item)

    local item_index = -1
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
        if reaper.GetTrackMediaItem(track, i) == item then
            item_index = i
            break
        end
    end

    return {ok = true, item_index = item_index, length = length}
end

-- Set item loop source
local function SetItemLoopSource(track_index, item_index, loop_source)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", loop_source and 1 or 0)
    return {ok = true}
end

-- Insert MIDI note
local function InsertMIDINote(track_index, item_index, pitch, start_ppq, length_ppq, velocity, channel)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Not a MIDI take"}
    end
    
    -- Convert time to PPQ
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos + start_ppq)
    local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos + start_ppq + length_ppq)
    
    reaper.MIDI_InsertNote(take, false, false, ppq_start, ppq_end, channel or 0, pitch, velocity or 100, false)
    reaper.MIDI_Sort(take)
    
    return {ok = true}
end

-- Quantize item
local function QuantizeItem(track_index, item_index, strength, grid)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Not a MIDI take"}
    end
    
    -- Note: This is a simplified quantization
    -- In practice, you'd use MIDI editor actions or more complex logic
    -- For now, just return success
    return {ok = true}
end

-- Track operations
local function GetTrackVolume(track_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
    return {ok = true, ret = vol}
end

local function SetTrackVolume(track_index, volume)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", volume)
    return {ok = true}
end

local function GetTrackPan(track_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    local pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN")
    return {ok = true, ret = pan}
end

local function SetTrackPan(track_index, pan)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan)
    return {ok = true}
end

local function SetTrackMute(track_index, mute)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute and 1 or 0)
    return {ok = true}
end

local function SetTrackSolo(track_index, solo)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo and 1 or 0)
    return {ok = true}
end

-- Transport operations
local function Play()
    reaper.Main_OnCommand(1007, 0) -- Transport: Play
    return {ok = true}
end

local function Stop()
    reaper.Main_OnCommand(1016, 0) -- Transport: Stop
    return {ok = true}
end

local function GetTempo()
    local tempo = reaper.Master_GetTempo()
    return {ok = true, ret = tempo}
end

local function SetTempo(bpm)
    reaper.SetTempoTimeSigMarker(0, -1, -1, -1, -1, bpm, 0, 0, false)
    return {ok = true}
end

local function GetTimeSignature()
    local bpm, bpi = reaper.GetProjectTimeSignature2(0)
    -- TimeMap2_timeToBeats returns: full beats, measures, cml, fullbeats, cdenom
    local retval, measures, cml, fullbeats, cdenom = reaper.TimeMap2_timeToBeats(0, 0)
    local numerator = bpi
    local denominator = cdenom or 4
    return {ok = true, numerator = numerator, denominator = denominator, tempo = bpm}
end

-- Set multiple FX parameters in one bridge roundtrip
local function BatchSetFXParams(track_index, fx_index, params)
    local track = nil
    if track_index == -1 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_index)
    end
    if not track then
        return {ok = false, error = "Track not found"}
    end

    local num_params = reaper.TrackFX_GetNumParams(track, fx_index)
    if num_params == 0 then
        return {ok = false, error = "FX not found or has no parameters"}
    end

    local set_count = 0
    local failures = {__is_array = true}

    for _, p in ipairs(params) do
        local pi = p.param_index
        local val = p.value
        if pi < 0 or pi >= num_params then
            table.insert(failures, {param_index = pi, error = "out of range"})
        else
            local ok = reaper.TrackFX_SetParam(track, fx_index, pi, val)
            if ok then
                set_count = set_count + 1
            else
                table.insert(failures, {param_index = pi, error = "set failed"})
            end
        end
    end

    return {
        ok = #failures == 0,
        set_count = set_count,
        total_requested = #params,
        failures = failures
    }
end

-- Get all FX parameter names in one bridge roundtrip
local function GetAllFXParamNames(track_index, fx_index)
    local track = nil
    if track_index == -1 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_index)
    end
    if not track then
        return {ok = false, error = "Track not found"}
    end

    local num_params = reaper.TrackFX_GetNumParams(track, fx_index)
    if num_params == 0 then
        return {ok = false, error = "FX not found or has no parameters"}
    end

    local names = {__is_array = true}
    for i = 0, num_params - 1 do
        local retval, name = reaper.TrackFX_GetParamName(track, fx_index, i, "")
        table.insert(names, {index = i, name = name or ""})
    end

    return {ok = true, params = names, count = num_params}
end

-- Get comprehensive project summary for Claude context
local function GetProjectSummary()
    -- Helper to convert linear volume to dB
    local function linear_to_db(vol)
        if vol <= 0 then return -150 end
        return 20 * math.log(vol) / math.log(10)
    end

    -- Get project name and path
    local retval, project_path = reaper.EnumProjects(-1, "")
    local project_name = ""
    if project_path and project_path ~= "" then
        project_name = project_path:match("([^/\\]+)%.rpp$") or project_path:match("([^/\\]+)$") or ""
    end

    -- Get tempo and time signature
    local bpm, bpi = reaper.GetProjectTimeSignature2(0)

    -- Get project length
    local project_length = reaper.GetProjectLength(0)

    -- Get track count
    local track_count = reaper.CountTracks(0)

    -- Get all tracks info
    local tracks = {__is_array = true}
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local retval, name = reaper.GetTrackName(track)
            local vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
            local pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN")
            local mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1
            local solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") > 0

            -- Get FX info
            local fx_count = reaper.TrackFX_GetCount(track)
            local fx_names = {__is_array = true}
            for j = 0, fx_count - 1 do
                local retval, fx_name = reaper.TrackFX_GetFXName(track, j, "")
                if retval then
                    table.insert(fx_names, fx_name)
                end
            end

            table.insert(tracks, {
                index = i,
                name = name,
                volume_db = linear_to_db(vol),
                pan = pan,
                mute = mute,
                solo = solo,
                fx_count = fx_count,
                fx_names = fx_names
            })
        end
    end

    -- Get master track info
    local master = reaper.GetMasterTrack(0)
    local master_vol = reaper.GetMediaTrackInfo_Value(master, "D_VOL")
    local master_fx_count = reaper.TrackFX_GetCount(master)
    local master_fx_names = {__is_array = true}
    for j = 0, master_fx_count - 1 do
        local retval, fx_name = reaper.TrackFX_GetFXName(master, j, "")
        if retval then
            table.insert(master_fx_names, fx_name)
        end
    end

    local master_info = {
        volume_db = linear_to_db(master_vol),
        fx_count = master_fx_count,
        fx_names = master_fx_names
    }

    -- Get markers and regions
    local markers = {__is_array = true}
    local regions = {__is_array = true}
    local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval then
            if isrgn then
                table.insert(regions, {
                    index = markrgnindexnumber,
                    start = pos,
                    ["end"] = rgnend,
                    name = name
                })
            else
                table.insert(markers, {
                    index = markrgnindexnumber,
                    position = pos,
                    name = name
                })
            end
        end
    end

    return {
        ok = true,
        project_name = project_name,
        project_path = project_path,
        tempo = bpm,
        time_signature = {numerator = bpi, denominator = ({reaper.TimeMap2_timeToBeats(0, 0)})[5] or 4},
        project_length = project_length,
        track_count = track_count,
        tracks = tracks,
        master = master_info,
        markers = markers,
        regions = regions
    }
end

-- ---------------------------------------------------------------------------
-- Envelope automation functions
-- ---------------------------------------------------------------------------

local function GetEnvelopeByName(track_index, envelope_name)
    local track
    if track_index == -1 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_index)
    end
    if not track then return nil end
    local count = reaper.CountTrackEnvelopes(track)
    for i = 0, count - 1 do
        local env = reaper.GetTrackEnvelope(track, i)
        local retval, name = reaper.GetEnvelopeName(env)
        if retval and name == envelope_name then
            return env
        end
    end
    -- Envelope not visible yet — try to show it
    if envelope_name == "Volume" then
        local env = reaper.GetTrackEnvelopeByName(track, "Volume")
        if env then return env end
    elseif envelope_name == "Pan" then
        local env = reaper.GetTrackEnvelopeByName(track, "Pan")
        if env then return env end
    end
    return nil
end

local function InsertEnvelopePoint(track_index, envelope_name, time, value, shape, tension, selected, no_sort)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope '" .. tostring(envelope_name) .. "' not found on track " .. tostring(track_index)}
    end
    local result = reaper.InsertEnvelopePoint(env, time, value, shape or 0, tension or 0, selected or false, no_sort or false)
    if result then
        reaper.Envelope_SortPoints(env)
        local count = reaper.CountEnvelopePoints(env)
        return {ok = true, point_index = count - 1}
    end
    return {ok = false, error = "Failed to insert envelope point"}
end

local function GetEnvelopePoints(track_index, envelope_name)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope '" .. tostring(envelope_name) .. "' not found"}
    end
    local count = reaper.CountEnvelopePoints(env)
    local points = {__is_array = true}
    for i = 0, count - 1 do
        local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
        if retval then
            table.insert(points, {index = i, time = time, value = value, shape = shape})
        end
    end
    return {ok = true, points = points, count = count}
end

local function CountEnvelopePoints(track_index, envelope_name)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope not found"}
    end
    return {ok = true, count = reaper.CountEnvelopePoints(env)}
end

local function DeleteEnvelopePoint(track_index, envelope_name, point_index)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope not found"}
    end
    local result = reaper.DeleteEnvelopePointRange(env, point_index, point_index + 1)
    return {ok = true}
end

local function ClearEnvelope(track_index, envelope_name)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope not found"}
    end
    local count = reaper.CountEnvelopePoints(env)
    if count > 0 then
        local retval, time_start = reaper.GetEnvelopePoint(env, 0)
        local retval2, time_end = reaper.GetEnvelopePoint(env, count - 1)
        reaper.DeleteEnvelopePointRange(env, time_start - 1, time_end + 1)
    end
    return {ok = true}
end

local function SetEnvelopeArm(track_index, envelope_name, arm)
    local env = GetEnvelopeByName(track_index, envelope_name)
    if not env then
        return {ok = false, error = "Envelope not found"}
    end
    local br = reaper.BR_EnvAlloc(env, false)
    if br then
        local active, visible, armed, inLane, laneHeight, defaultShape, minValue, maxValue, centerValue, envType, faderScaling, automationItemIdx = reaper.BR_EnvGetProperties(br)
        reaper.BR_EnvSetProperties(br, active, visible, arm, inLane, laneHeight, defaultShape, faderScaling)
        reaper.BR_EnvFree(br, true)
        return {ok = true}
    end
    return {ok = false, error = "Could not access envelope properties (SWS extension may be required)"}
end

-- ---------------------------------------------------------------------------
-- Item query functions
-- ---------------------------------------------------------------------------

local function GetItemInfo(track_index, item_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local volume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
    local mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1
    local fade_in = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    local fade_out = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")

    local take_count = reaper.CountTakes(item)
    local take_info = nil
    if take_count > 0 then
        local take = reaper.GetActiveTake(item)
        if take then
            local retval, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            local source = reaper.GetMediaItemTake_Source(take)
            local source_file = ""
            if source then
                source_file = reaper.GetMediaSourceFileName(source)
            end
            take_info = {
                name = take_name,
                source_file = source_file,
                is_midi = reaper.TakeIsMIDI(take)
            }
        end
    end

    return {
        ok = true,
        position = position,
        length = length,
        volume = volume,
        mute = mute,
        fade_in = fade_in,
        fade_out = fade_out,
        take_count = take_count,
        take = take_info
    }
end

-- ---------------------------------------------------------------------------
-- MIDI note functions
-- ---------------------------------------------------------------------------

local function MIDI_InsertNote(track_index, item_index, selected, muted, start_ppq, end_ppq, channel, pitch, velocity, no_sort)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Item is not a MIDI item"}
    end
    local result = reaper.MIDI_InsertNote(take, selected or false, muted or false, start_ppq, end_ppq, channel or 0, pitch, velocity, no_sort or false)
    if result then
        reaper.MIDI_Sort(take)
        local note_count = ({reaper.MIDI_CountEvts(take)})[2]
        return {ok = true, note_index = note_count - 1}
    end
    return {ok = false, error = "Failed to insert MIDI note"}
end

local function GetMIDINotes(track_index, item_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Item is not a MIDI item"}
    end
    local retval, note_count = reaper.MIDI_CountEvts(take)
    local notes = {__is_array = true}
    for i = 0, note_count - 1 do
        local retval, selected, muted, start_ppq, end_ppq, channel, pitch, velocity = reaper.MIDI_GetNote(take, i)
        if retval then
            table.insert(notes, {
                index = i,
                pitch = pitch,
                velocity = velocity,
                start_ppq = start_ppq,
                end_ppq = end_ppq,
                channel = channel,
                selected = selected,
                muted = muted
            })
        end
    end
    return {ok = true, notes = notes, count = note_count}
end

local function MIDI_DeleteNote(track_index, item_index, note_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Item is not a MIDI item"}
    end
    local result = reaper.MIDI_DeleteNote(take, note_index)
    if result then
        reaper.MIDI_Sort(take)
        return {ok = true}
    end
    return {ok = false, error = "Failed to delete MIDI note"}
end

local function ClearMIDIItem(track_index, item_index)
    local track = reaper.GetTrack(0, track_index)
    if not track then
        return {ok = false, error = "Track not found"}
    end
    local item = reaper.GetTrackMediaItem(track, item_index)
    if not item then
        return {ok = false, error = "Item not found"}
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        return {ok = false, error = "Item is not a MIDI item"}
    end
    local retval, note_count = reaper.MIDI_CountEvts(take)
    for i = note_count - 1, 0, -1 do
        reaper.MIDI_DeleteNote(take, i)
    end
    reaper.MIDI_Sort(take)
    return {ok = true, deleted = note_count}
end

-- ---------------------------------------------------------------------------
-- Render functions
-- ---------------------------------------------------------------------------

local function RenderProject(output_path, start_time, end_time, tail_seconds)
    -- Set render bounds
    if start_time and end_time then
        reaper.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
        reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "I_AUTOMODE", 1)
    end

    -- Set render file
    local retval, project_path = reaper.EnumProjects(-1, "")
    if output_path then
        local dir = output_path:match("(.+)[/\\]")
        local file = output_path:match("([^/\\]+)$")
        if dir and file then
            reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
            reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", file:gsub("%.wav$", ""):gsub("%.mp3$", ""):gsub("%.flac$", ""), true)
        end
    end

    -- Set render tail
    if tail_seconds and tail_seconds > 0 then
        reaper.GetSetProjectInfo(0, "RENDER_TAILMS", tail_seconds * 1000, true)
    end

    -- Execute render
    reaper.Main_OnCommand(41824, 0)  -- File: Render project, using the most recent render settings

    return {ok = true, output_path = output_path}
end

local function RenderRegion(region_index, output_path)
    -- Find the region
    local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local found = false
    local rgn_start, rgn_end
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval and isrgn and markrgnindexnumber == region_index then
            rgn_start = pos
            rgn_end = rgnend
            found = true
            break
        end
    end
    if not found then
        return {ok = false, error = "Region " .. tostring(region_index) .. " not found"}
    end

    return RenderProject(output_path, rgn_start, rgn_end, 0)
end

local function GetProjectLength()
    return {ok = true, length = reaper.GetProjectLength(0)}
end

-- ---------------------------------------------------------------------------
-- Transport functions
-- ---------------------------------------------------------------------------

local function GetPlayPosition()
    return {ok = true, position = reaper.GetPlayPosition()}
end

local function Pause()
    reaper.Main_OnCommand(1008, 0)  -- Transport: Pause
    return {ok = true}
end

local function Record()
    reaper.Main_OnCommand(1013, 0)  -- Transport: Record
    return {ok = true}
end

local function GetRepeatState()
    local state = reaper.GetSetRepeat(-1)
    return {ok = true, repeat_state = state == 1}
end

-- ---------------------------------------------------------------------------
-- Marker/Region functions
-- ---------------------------------------------------------------------------

local function GetProjectMarkers()
    local markers = {__is_array = true}
    local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval and not isrgn then
            table.insert(markers, {
                index = markrgnindexnumber,
                position = pos,
                name = name
            })
        end
    end
    return {ok = true, markers = markers}
end

local function GetProjectRegions()
    local regions = {__is_array = true}
    local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
        if retval and isrgn then
            table.insert(regions, {
                index = markrgnindexnumber,
                start = pos,
                ["end"] = rgnend,
                name = name
            })
        end
    end
    return {ok = true, regions = regions}
end

-- Export function table for DSL
DSL_FUNCTIONS = {
    -- Track info
    GetTrackInfo = GetTrackInfo,
    GetTrackFXList = GetTrackFXList,
    GetAllTracksInfo = GetAllTracksInfo,
    GetSelectedTracks = GetSelectedTracks,
    SetTrackNotes = SetTrackNotes,
    
    -- Time operations
    GetCursorPosition = GetCursorPosition,
    GetTimeSelection = GetTimeSelection,
    SetTimeSelection = SetTimeSelection,
    GetLoopTimeRange = GetLoopTimeRange,
    BarsToTime = BarsToTime,
    FindRegion = FindRegion,
    FindMarker = FindMarker,
    
    -- Item operations
    GetSelectedItems = GetSelectedItems,
    GetAllItems = GetAllItems,
    GetTrackItems = GetTrackItems,
    CreateMIDIItem = CreateMIDIItem,
    CreateAudioItem = CreateAudioItem,
    InsertAudioFile = InsertAudioFile,
    SetItemLoopSource = SetItemLoopSource,
    InsertMIDINote = InsertMIDINote,
    QuantizeItem = QuantizeItem,
    
    -- Track operations
    GetTrackVolume = GetTrackVolume,
    SetTrackVolume = SetTrackVolume,
    GetTrackPan = GetTrackPan,
    SetTrackPan = SetTrackPan,
    SetTrackMute = SetTrackMute,
    SetTrackSolo = SetTrackSolo,
    
    -- Transport
    Play = Play,
    Stop = Stop,
    GetTempo = GetTempo,
    SetTempo = SetTempo,
    GetTimeSignature = GetTimeSignature,
    GetPlayPosition = GetPlayPosition,
    Pause = Pause,
    Record = Record,
    GetRepeatState = GetRepeatState,

    -- Envelope automation
    InsertEnvelopePoint = InsertEnvelopePoint,
    GetEnvelopePoints = GetEnvelopePoints,
    CountEnvelopePoints = CountEnvelopePoints,
    DeleteEnvelopePoint = DeleteEnvelopePoint,
    ClearEnvelope = ClearEnvelope,
    SetEnvelopeArm = SetEnvelopeArm,

    -- Item queries
    GetItemInfo = GetItemInfo,

    -- MIDI notes
    MIDI_InsertNote = MIDI_InsertNote,
    GetMIDINotes = GetMIDINotes,
    MIDI_DeleteNote = MIDI_DeleteNote,
    ClearMIDIItem = ClearMIDIItem,

    -- Render
    RenderProject = RenderProject,
    RenderRegion = RenderRegion,
    GetProjectLength = GetProjectLength,

    -- Markers/Regions
    GetProjectMarkers = GetProjectMarkers,
    GetProjectRegions = GetProjectRegions,

    -- Project summary
    GetProjectSummary = GetProjectSummary,

    -- Batch operations
    BatchSetFXParams = BatchSetFXParams,
    GetAllFXParamNames = GetAllFXParamNames
}

-- Helper to resolve track index to track pointer (-1 = master, 0+ = regular)
local function get_track(track_index)
    if track_index == -1 then
        return reaper.GetMasterTrack(0)
    end
    local count = reaper.CountTracks(0)
    if track_index >= 0 and track_index < count then
        return reaper.GetTrack(0, track_index)
    end
    return nil
end

-- Main processing function
local function process_request()
    -- Enumerate pending request files up front (unpredictable ids), so deleting
    -- one mid-loop cannot disturb the EnumerateFiles cursor.
    local req_ids = {}
    local eidx = 0
    while true do
        local entry = reaper.EnumerateFiles(bridge_dir, eidx)
        if not entry then break end
        local rid = entry:match('^request_(.+)%.json$')
        if rid then req_ids[#req_ids + 1] = rid end
        eidx = eidx + 1
    end

    for _, req_id in ipairs(req_ids) do
        local numbered_request_file = bridge_dir .. 'request_' .. req_id .. '.json'
        local numbered_response_file = bridge_dir .. 'response_' .. req_id .. '.json'

        if file_exists(numbered_request_file) then
            -- Wrap in pcall to catch any errors
            local ok, err = pcall(function()
                -- Read and process request
                local request_data = read_file(numbered_request_file)
                if request_data then
                    reaper.ShowConsoleMsg("Processing request " .. req_id .. ": " .. request_data .. "\n")
                    
                    -- Parse the request
                    local request = decode_json(request_data)
                    if request and request.func then
                        local fname = request.func
                        local args = request.args or {}
                    
                    -- Call the REAPER function
                    local response = {ok = false}
                    
                    -- Handle all API functions
                                        if DSL_FUNCTIONS[fname] then
                        local result = DSL_FUNCTIONS[fname](table.unpack(args))
                        -- Copy all fields from result to response
                        for k, v in pairs(result) do
                            response[k] = v
                        end
                    
                    elseif fname == "InsertTrackAtIndex" then
                        if #args >= 2 then
                            reaper.InsertTrackAtIndex(args[1], args[2])
                            response.ok = true
                        else
                            response.error = "InsertTrackAtIndex requires 2 arguments"
                        end
                    
                    elseif fname == "CountTracks" then
                        local count = reaper.CountTracks(args[1] or 0)
                        response.ok = true
                        response.ret = count
                    
                    elseif fname == "GetAppVersion" then
                        local version = reaper.GetAppVersion()
                        response.ok = true
                        response.ret = version
                    
                    elseif fname == "GetTrack" then
                        if #args >= 2 then
                            local track = reaper.GetTrack(args[1], args[2])
                            response.ok = true
                            response.ret = track
                        else
                            response.error = "GetTrack requires 2 arguments"
                        end
                    
                    elseif fname == "CreateTrackSend" then
                        -- Create a send between two tracks
                        if #args >= 2 then
                            local src_track = nil
                            local dest_track = nil
                            
                            -- Handle source track
                            if type(args[1]) == "number" then
                                src_track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use source track pointer from previous call - use track index instead"
                                response.ok = false
                            elseif type(args[1]) == "userdata" then
                                src_track = args[1]
                            end
                            
                            -- Handle destination track
                            if src_track and type(args[2]) == "number" then
                                dest_track = reaper.GetTrack(0, args[2])
                            elseif src_track and type(args[2]) == "table" and args[2].__ptr then
                                response.error = "Cannot use destination track pointer from previous call - use track index instead"
                                response.ok = false
                                src_track = nil  -- Clear to prevent partial operation
                            elseif src_track and type(args[2]) == "userdata" then
                                dest_track = args[2]
                            end
                            
                            if src_track and dest_track then
                                local send_idx = reaper.CreateTrackSend(src_track, dest_track)
                                response.ok = true
                                response.ret = send_idx
                            elseif not src_track then
                                if not response.error then
                                    response.error = "Source track not found"
                                end
                                response.ok = false
                            else
                                if not response.error then
                                    response.error = "Destination track not found"
                                end
                                response.ok = false
                            end
                        else
                            response.error = "CreateTrackSend requires 2 arguments (source_track, dest_track)"
                            response.ok = false
                        end
                    
                    elseif fname == "SetTrackSendUIVol" then
                        -- Set track send UI volume
                        if #args >= 4 then
                            local track = nil
                            
                            -- Handle track parameter
                            if type(args[1]) == "number" then
                                track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                            elseif type(args[1]) == "userdata" then
                                track = args[1]
                            end
                            
                            if track then
                                local send_idx = args[2]
                                local volume = args[3]
                                local relative = args[4]
                                
                                local result = reaper.SetTrackSendUIVol(track, send_idx, volume, relative)
                                response.ok = true
                                response.ret = result
                            else
                                if not response.error then
                                    response.error = "Track not found"
                                end
                                response.ok = false
                            end
                        else
                            response.error = "SetTrackSendUIVol requires 4 arguments (track, send_index, volume, relative)"
                            response.ok = false
                        end
                    
                    elseif fname == "SetTrackSendUIPan" then
                        -- Set track send UI pan
                        if #args >= 4 then
                            local track = nil
                            
                            -- Handle track parameter
                            if type(args[1]) == "number" then
                                track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                            elseif type(args[1]) == "userdata" then
                                track = args[1]
                            end
                            
                            if track then
                                local send_idx = args[2]
                                local pan = args[3]
                                local relative = args[4]
                                
                                local result = reaper.SetTrackSendUIPan(track, send_idx, pan, relative)
                                response.ok = true
                                response.ret = result
                            else
                                if not response.error then
                                    response.error = "Track not found"
                                end
                                response.ok = false
                            end
                        else
                            response.error = "SetTrackSendUIPan requires 4 arguments (track, send_index, pan, relative)"
                            response.ok = false
                        end
                    
                    elseif fname == "SetTrackSendInfo_Value" then
                        -- Set track send info value
                        if #args >= 5 then
                            local track = nil
                            
                            -- Handle track parameter
                            if type(args[1]) == "number" then
                                track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                            elseif type(args[1]) == "userdata" then
                                track = args[1]
                            end
                            
                            if track then
                                local category = args[2]
                                local send_idx = args[3]
                                local param_name = args[4]
                                local value = args[5]
                                
                                local result = reaper.SetTrackSendInfo_Value(track, category, send_idx, param_name, value)
                                response.ok = true
                                response.ret = result
                            else
                                if not response.error then
                                    response.error = "Track not found"
                                end
                                response.ok = false
                            end
                        else
                            response.error = "SetTrackSendInfo_Value requires 5 arguments (track, category, send_index, param_name, value)"
                            response.ok = false
                        end

                    elseif fname == "RemoveTrackSend" then
                        -- Remove a track send
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                track = reaper.GetTrack(0, args[1])
                            end
                            if track then
                                local category = args[2]
                                local send_idx = args[3]
                                local result = reaper.RemoveTrackSend(track, category, send_idx)
                                response.ok = result
                                response.ret = result
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "RemoveTrackSend requires 3 arguments (track_index, category, send_index)"
                            response.ok = false
                        end

                    elseif fname == "GetTrackNumSends" then
                        -- Get number of sends from a track
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                track = reaper.GetTrack(0, args[1])
                            end
                            if track then
                                local category = args[2]
                                local result = reaper.GetTrackNumSends(track, category)
                                response.ok = true
                                response.ret = result
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "GetTrackNumSends requires 2 arguments (track_index, category)"
                            response.ok = false
                        end

                    elseif fname == "GetFXChunk" then
                        -- Get FX state chunk (for reading VSTi state like EZkeys)
                        if #args >= 2 then
                            local track = nil
                            local track_index = args[1]
                            local fx_index = args[2]

                            if track_index == -1 then
                                track = reaper.GetMasterTrack(0)
                            else
                                track = reaper.GetTrack(0, track_index)
                            end

                            if track then
                                -- Get the full track state chunk
                                local retval, chunk = reaper.GetTrackStateChunk(track, "", false)
                                if retval and chunk then
                                    -- Parse out the specific FX chunk
                                    -- FX are in <FXCHAIN> section, each FX starts with <VST or <JS etc
                                    local fx_count = 0
                                    local in_fxchain = false
                                    local fx_start = nil
                                    local bracket_depth = 0
                                    local fx_chunk = nil

                                    -- Find the FX chain section
                                    local fxchain_start = chunk:find("<FXCHAIN")
                                    if fxchain_start then
                                        local fxchain_section = chunk:sub(fxchain_start)

                                        -- Find all FX entries (VST, VST3, JS, etc)
                                        local pos = 1
                                        local current_fx = -1

                                        while true do
                                            -- Look for FX start markers
                                            local vst_pos = fxchain_section:find("\n%s*<VST[^>]*>", pos)
                                            local vst3_pos = fxchain_section:find("\n%s*<VST3[^>]*>", pos)
                                            local js_pos = fxchain_section:find("\n%s*<JS[^>]*>", pos)

                                            -- Find earliest match
                                            local next_fx = nil
                                            local next_pos = nil

                                            if vst_pos and (not next_pos or vst_pos < next_pos) then
                                                next_pos = vst_pos
                                            end
                                            if vst3_pos and (not next_pos or vst3_pos < next_pos) then
                                                next_pos = vst3_pos
                                            end
                                            if js_pos and (not next_pos or js_pos < next_pos) then
                                                next_pos = js_pos
                                            end

                                            if not next_pos then break end

                                            current_fx = current_fx + 1

                                            if current_fx == fx_index then
                                                -- Found the target FX, extract its chunk
                                                -- Find the matching closing >
                                                local depth = 1
                                                local i = next_pos + 1
                                                -- Skip to first <
                                                while i <= #fxchain_section and fxchain_section:sub(i, i) ~= "<" do
                                                    i = i + 1
                                                end
                                                local fx_chunk_start = i
                                                i = i + 1

                                                while i <= #fxchain_section and depth > 0 do
                                                    local c = fxchain_section:sub(i, i)
                                                    if c == "<" then
                                                        depth = depth + 1
                                                    elseif c == ">" then
                                                        depth = depth - 1
                                                    end
                                                    i = i + 1
                                                end

                                                fx_chunk = fxchain_section:sub(fx_chunk_start, i - 1)
                                                break
                                            end

                                            pos = next_pos + 1
                                        end

                                        if fx_chunk then
                                            response.ok = true
                                            response.chunk = fx_chunk
                                            response.fx_index = fx_index
                                        else
                                            response.ok = false
                                            response.error = "FX not found at index " .. tostring(fx_index)
                                        end
                                    else
                                        response.ok = false
                                        response.error = "No FX chain found on track"
                                    end
                                else
                                    response.ok = false
                                    response.error = "Could not get track state chunk"
                                end
                            else
                                response.ok = false
                                response.error = "Track not found"
                            end
                        else
                            response.error = "GetFXChunk requires 2 arguments (track_index, fx_index)"
                            response.ok = false
                        end

                    elseif fname == "InsertEnvelopePoint" then
                        -- Insert envelope point
                        if #args >= 7 then
                            local envelope = args[1]
                            
                            -- Handle envelope pointer
                            if type(envelope) == "table" and envelope.__ptr then
                                response.error = "Cannot use envelope pointer from previous call - envelope objects cannot be reused"
                                response.ok = false
                            elseif type(envelope) == "userdata" then
                                -- It's a valid envelope object
                                local time = args[2]
                                local value = args[3]
                                local shape = args[4]
                                local tension = args[5]
                                local selected = args[6]
                                local noSort = args[7]
                                
                                local result = reaper.InsertEnvelopePoint(envelope, time, value, shape, tension, selected, noSort)
                                response.ok = result
                                response.ret = result
                            else
                                response.error = "Invalid envelope parameter"
                                response.ok = false
                            end
                        else
                            response.error = "InsertEnvelopePoint requires 7 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetTrackSelected" then
                        if #args >= 2 then
                            local track = reaper.GetTrack(0, args[1])
                            if track then
                                reaper.SetTrackSelected(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                            end
                        else
                            response.error = "SetTrackSelected requires 2 arguments"
                        end
                    
                    elseif fname == "GetTrackName" then
                        if #args >= 1 then
                            local track = args[1]
                            -- Handle track index or pointer object
                            if type(args[1]) == "number" then
                                -- It's a track index
                                if args[1] == -1 then
                                    -- Special case for master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                                if not track then
                                    response.error = "Track not found at index " .. tostring(args[1])
                                    response.ok = false
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer object - we can't use it
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                                track = nil
                            elseif type(args[1]) == "userdata" then
                                -- It's already a track object
                                track = args[1]
                            end
                            
                            if track then
                                local retval, name = reaper.GetTrackName(track)
                                response.ok = true
                                response.ret = name
                            end
                        else
                            response.error = "GetTrackName requires 1 argument"
                        end
                    
                    elseif fname == "SetTrackName" then
                        if #args >= 2 then
                            local track = reaper.GetTrack(0, args[1])
                            if track then
                                reaper.GetSetMediaTrackInfo_String(track, "P_NAME", args[2], true)
                                response.ok = true
                            else
                                response.error = "Track not found"
                            end
                        else
                            response.error = "SetTrackName requires 2 arguments"
                        end
                    
                    elseif fname == "GetMasterTrack" then
                        local track = reaper.GetMasterTrack(args[1] or 0)
                        response.ok = true
                        response.ret = track
                    
                    elseif fname == "DeleteTrack" then
                        if args[1] then
                            -- Check if it's a track index or a pointer object
                            local track = nil
                            if type(args[1]) == "number" then
                                -- It's a track index
                                track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer object - we can't use it directly
                                -- For now, return an error
                                response.error = "Cannot use track pointer from previous call - use DeleteTrackByIndex instead"
                                response.ok = false
                            else
                                track = args[1]  -- Assume it's already a track
                            end
                            
                            if track then
                                reaper.DeleteTrack(track)
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "DeleteTrack requires track pointer or index"
                        end
                    
                    elseif fname == "DeleteTrackByIndex" then
                        if args[1] then
                            local track = reaper.GetTrack(0, args[1])
                            if track then
                                reaper.DeleteTrack(track)
                                response.ok = true
                            else
                                response.error = "Track not found at index " .. tostring(args[1])
                                response.ok = false
                            end
                        else
                            response.error = "DeleteTrackByIndex requires track index"
                        end
                    
                    elseif fname == "GetMediaTrackInfo_Value" then
                        if #args >= 2 then
                            local track = args[1]
                            -- Handle track index or pointer object
                            if type(args[1]) == "number" then
                                -- It's a track index
                                if args[1] == -1 then
                                    -- Special case for master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                                if not track then
                                    response.error = "Track not found at index " .. tostring(args[1])
                                    response.ok = false
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer object - we can't use it
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                                track = nil
                            end
                            
                            if track then
                                local value = reaper.GetMediaTrackInfo_Value(track, args[2])
                                response.ok = true
                                response.ret = value
                            end
                        else
                            response.error = "GetMediaTrackInfo_Value requires 2 arguments"
                        end
                    
                    elseif fname == "SetMediaTrackInfo_Value" then
                        if #args >= 3 then
                            local track = args[1]
                            -- Handle track index or pointer object
                            if type(args[1]) == "number" then
                                -- It's a track index
                                if args[1] == -1 then
                                    -- Special case for master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                                if not track then
                                    response.error = "Track not found at index " .. tostring(args[1])
                                    response.ok = false
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer object - we can't use it
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                                track = nil
                            end
                            
                            if track then
                                reaper.SetMediaTrackInfo_Value(track, args[2], args[3])
                                response.ok = true
                            end
                        else
                            response.error = "SetMediaTrackInfo_Value requires 3 arguments"
                        end
                    
                    elseif fname == "GetSetMediaTrackInfo_String" then
                        if #args >= 4 then
                            local track = args[1]
                            local param = args[2]
                            local newvalue = args[3]
                            local setnewvalue = args[4]
                            -- Convert string to boolean if needed
                            if type(setnewvalue) == "string" then
                                setnewvalue = (setnewvalue == "true" or setnewvalue == "1")
                            end
                            
                            -- Handle track index or pointer object
                            if type(args[1]) == "number" then
                                -- It's a track index
                                if args[1] == -1 then
                                    -- Special case for master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                                if not track then
                                    response.error = "Track not found at index " .. tostring(args[1])
                                    response.ok = false
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer object - we can't use it
                                response.error = "Cannot use track pointer from previous call - use track index instead"
                                response.ok = false
                                track = nil
                            elseif type(args[1]) == "userdata" then
                                -- It's already a track object
                                track = args[1]
                            end
                            
                            if track then
                                local ok, strval = reaper.GetSetMediaTrackInfo_String(track, param, newvalue, setnewvalue)
                                response.ok = ok
                                response.ret = strval
                            end
                        else
                            response.error = "GetSetMediaTrackInfo_String requires 4 arguments"
                        end
                    
                    elseif fname == "AddMediaItemToTrack" then
                        if args[1] then
                            local track = nil
                            -- Check if it's a track index (number) or a track object
                            if type(args[1]) == "number" then
                                -- It's a track index, get the track
                                track = reaper.GetTrack(0, args[1])
                            elseif type(args[1]) == "userdata" then
                                -- It's already a track object
                                track = args[1]
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use track pointer from previous call - bridge limitation"
                                response.ok = false
                            end
                            
                            if track then
                                local item = reaper.AddMediaItemToTrack(track)
                                response.ok = true
                                response.ret = item
                            else
                                response.error = "Invalid track parameter - provide track index or valid track object"
                                response.ok = false
                            end
                        else
                            response.error = "AddMediaItemToTrack requires track index or track object"
                        end
                    
                    elseif fname == "CountMediaItems" then
                        local count = reaper.CountMediaItems(args[1] or 0)
                        response.ok = true
                        response.ret = count
                    
                    elseif fname == "AddTakeToMediaItem" then
                        if args[1] then
                            local item = nil
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "userdata" then
                                -- It's already an item object
                                item = args[1]
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use item pointer from previous call - use item index instead"
                                response.ok = false
                            end
                            
                            if item then
                                local take = reaper.AddTakeToMediaItem(item)
                                response.ok = true
                                response.ret = take
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "AddTakeToMediaItem requires item index or item object"
                        end
                    
                    elseif fname == "GetMediaItem" then
                        if #args >= 2 then
                            local item = reaper.GetMediaItem(args[1], args[2])
                            response.ok = true
                            response.ret = item
                        else
                            response.error = "GetMediaItem requires 2 arguments"
                        end
                    
                    elseif fname == "GetMediaItemTake" then
                        if #args >= 2 then
                            local item = nil
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "userdata" then
                                -- It's already an item object
                                item = args[1]
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference
                                response.error = "Cannot use item pointer from previous call"
                                response.ok = false
                            end
                            
                            if item then
                                local take = reaper.GetMediaItemTake(item, args[2])
                                response.ok = true
                                response.ret = take
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "GetMediaItemTake requires 2 arguments"
                        end
                    
                    elseif fname == "CountTakes" then
                        if #args >= 1 then
                            local item = nil
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "userdata" then
                                -- It's already an item object
                                item = args[1]
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference
                                response.error = "Cannot use item pointer from previous call"
                                response.ok = false
                            end
                            
                            if item then
                                local count = reaper.CountTakes(item)
                                response.ok = true
                                response.ret = count
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "CountTakes requires 1 argument"
                        end
                    
                    elseif fname == "GetTrackMediaItem" then
                        if #args >= 2 then
                            local item = reaper.GetTrackMediaItem(args[1], args[2])
                            response.ok = true
                            response.ret = item
                        else
                            response.error = "GetTrackMediaItem requires 2 arguments"
                        end
                    
                    elseif fname == "DeleteTrackMediaItem" then
                        if #args >= 2 then
                            local track_index = args[1]
                            local item_index = args[2]
                            
                            -- Get track by index
                            local track
                            if track_index == -1 then
                                track = reaper.GetMasterTrack(0)
                            else
                                track = reaper.GetTrack(0, track_index)
                            end
                            
                            if not track then
                                response.error = "Track not found at index " .. tostring(track_index)
                                response.ok = false
                            else
                                -- Get item on track
                                local item = reaper.GetTrackMediaItem(track, item_index)
                                if not item then
                                    response.error = "Media item not found at index " .. tostring(item_index) .. " on track"
                                    response.ok = false
                                else
                                    -- Delete the item
                                    local result = reaper.DeleteTrackMediaItem(track, item)
                                    response.ok = result
                                end
                            end
                        else
                            response.error = "DeleteTrackMediaItem requires 2 arguments"
                        end
                    
                    elseif fname == "GetMediaItemInfo_Value" then
                        if #args >= 2 then
                            local item = args[1]
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                                if not item then
                                    response.error = "Item not found at index " .. tostring(args[1])
                                    response.ok = false
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use item pointer from previous call - use item index instead"
                                response.ok = false
                                item = nil
                            elseif type(args[1]) == "userdata" then
                                -- It's already an item object
                                item = args[1]
                            end
                            
                            if item then
                                local value = reaper.GetMediaItemInfo_Value(item, args[2])
                                response.ok = true
                                response.ret = value
                            end
                        else
                            response.error = "GetMediaItemInfo_Value requires 2 arguments"
                        end
                    
                    elseif fname == "SetMediaItemLength" then
                        if #args >= 3 then
                            local item = args[1]
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use item pointer from previous call - use item index instead"
                                response.ok = false
                                item = nil
                            end
                            
                            if item then
                                reaper.SetMediaItemLength(item, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "SetMediaItemLength requires 3 arguments"
                        end
                    
                    elseif fname == "SetMediaItemPosition" then
                        if #args >= 3 then
                            local item = args[1]
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use item pointer from previous call - use item index instead"
                                response.ok = false
                                item = nil
                            end
                            
                            if item then
                                reaper.SetMediaItemPosition(item, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "SetMediaItemPosition requires 3 arguments"
                        end
                    
                    elseif fname == "SetMediaItemSelected" then
                        if #args >= 2 then
                            local item = args[1]
                            -- Handle item index or pointer
                            if type(args[1]) == "number" then
                                -- It's an item index
                                item = reaper.GetMediaItem(0, args[1])
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference from a previous call - we can't use it
                                response.error = "Cannot use item pointer from previous call - use item index instead"
                                response.ok = false
                                item = nil
                            end
                            
                            if item then
                                reaper.SetMediaItemSelected(item, args[2])
                                response.ok = true
                            else
                                response.error = "Invalid item parameter"
                                response.ok = false
                            end
                        else
                            response.error = "SetMediaItemSelected requires 2 arguments"
                        end
                    
                    elseif fname == "GetProjectName" then
                        local retval, project_name = reaper.GetProjectName(args[1] or 0, "", 512)
                        response.ok = true
                        response.ret = project_name or ""
                        response.name = project_name or ""
                    
                    elseif fname == "GetProjectPath" then
                        local path = reaper.GetProjectPath("", 2048)
                        response.ok = true
                        response.ret = path
                    
                    elseif fname == "Main_SaveProject" then
                        reaper.Main_SaveProject(args[1] or 0, args[2] or false)
                        response.ok = true
                    
                    elseif fname == "GetCursorPosition" then
                        local pos = reaper.GetCursorPosition()
                        response.ok = true
                        response.ret = pos
                    
                    elseif fname == "SetEditCurPos" then
                        if #args >= 1 then
                            reaper.SetEditCurPos(args[1], args[2] or true, args[3] or false)
                            response.ok = true
                        else
                            response.error = "SetEditCurPos requires at least 1 argument"
                        end
                    
                    elseif fname == "GetPlayState" then
                        local state = reaper.GetPlayState()
                        response.ok = true
                        response.ret = state
                    
                    elseif fname == "Main_OnCommand" then
                        if #args >= 2 then
                            reaper.Main_OnCommand(args[1], args[2])
                            response.ok = true
                        else
                            response.error = "Main_OnCommand requires 2 arguments"
                        end
                    
                    elseif fname == "SetPlayState" then
                        if #args >= 3 then
                            local play = args[1] and 1 or 0
                            local pause = args[2] and 2 or 0
                            local rec = args[3] and 4 or 0
                            -- Use Main_OnCommand instead of CSurf_SetPlayState
                            -- Play = 1007, Pause = 1008, Stop = 1016, Record = 1013
                            if rec > 0 then
                                reaper.Main_OnCommand(1013, 0)  -- Record
                            elseif play > 0 then
                                reaper.Main_OnCommand(1007, 0)  -- Play
                            elseif pause > 0 then
                                reaper.Main_OnCommand(1008, 0)  -- Pause
                            else
                                reaper.Main_OnCommand(1016, 0)  -- Stop
                            end
                            response.ok = true
                        else
                            response.error = "SetPlayState requires 3 arguments"
                        end
                    
                    elseif fname == "GetSetRepeat" then
                        if #args >= 1 then
                            local prev = reaper.GetSetRepeat(args[1])
                            response.ok = true
                            response.ret = prev
                        else
                            response.error = "GetSetRepeat requires 1 argument"
                        end
                    
                    elseif fname == "Undo_BeginBlock" then
                        reaper.Undo_BeginBlock()
                        response.ok = true
                    
                    elseif fname == "Undo_EndBlock" then
                        if #args >= 1 then
                            reaper.Undo_EndBlock(args[1], args[2] or -1)
                            response.ok = true
                        else
                            response.error = "Undo_EndBlock requires at least 1 argument"
                        end
                    
                    elseif fname == "UpdateArrange" then
                        reaper.UpdateArrange()
                        response.ok = true
                    
                    elseif fname == "UpdateTimeline" then
                        reaper.UpdateTimeline()
                        response.ok = true
                    
                    elseif fname == "AddProjectMarker" then
                        if #args >= 5 then
                            local index = reaper.AddProjectMarker(args[1], args[2], args[3], args[4], args[5], args[6] or -1)
                            response.ok = true
                            response.ret = index
                        else
                            response.error = "AddProjectMarker requires at least 5 arguments"
                        end
                    
                    elseif fname == "DeleteProjectMarker" then
                        if #args >= 3 then
                            local result = reaper.DeleteProjectMarker(args[1], args[2], args[3])
                            response.ok = result
                        else
                            response.error = "DeleteProjectMarker requires 3 arguments"
                        end
                    
                    elseif fname == "CountProjectMarkers" then
                        local ret, num_markers, num_regions = reaper.CountProjectMarkers(args[1] or 0)
                        response.ok = true
                        response.ret = {num_markers, num_regions}
                    
                    elseif fname == "EnumProjectMarkers" then
                        if #args >= 1 then
                            local ret, is_region, pos, region_end, name, idx = reaper.EnumProjectMarkers(args[1])
                            if ret then
                                response.ok = true
                                response.ret = {ret, is_region, pos, region_end, name, idx}
                            else
                                response.ok = true
                                response.ret = {}
                            end
                        else
                            response.error = "EnumProjectMarkers requires 1 argument"
                        end

                    elseif fname == "GetProjectMarkers" then
                        -- Get all markers (not regions) in the project
                        local markers = {__is_array = true}
                        local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
                        for i = 0, num_markers + num_regions - 1 do
                            local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
                            if retval and not isrgn then
                                table.insert(markers, {
                                    index = markrgnindexnumber,
                                    position = pos,
                                    name = name
                                })
                            end
                        end
                        response.ok = true
                        response.markers = markers

                    elseif fname == "GetProjectRegions" then
                        -- Get all regions in the project
                        local regions = {__is_array = true}
                        local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
                        for i = 0, num_markers + num_regions - 1 do
                            local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(i)
                            if retval and isrgn then
                                table.insert(regions, {
                                    index = markrgnindexnumber,
                                    start = pos,
                                    ["end"] = rgnend,
                                    name = name
                                })
                            end
                        end
                        response.ok = true
                        response.regions = regions
                    
                    elseif fname == "GetSet_LoopTimeRange" then
                        if #args >= 2 then
                            if args[1] then  -- Set mode
                                if #args >= 5 then
                                    reaper.GetSet_LoopTimeRange(true, args[2], args[3], args[4], args[5])
                                    response.ok = true
                                else
                                    response.error = "GetSet_LoopTimeRange set mode requires 5 arguments"
                                end
                            else  -- Get mode
                                local start_time, end_time = reaper.GetSet_LoopTimeRange(false, args[2], 0, 0, false)
                                response.ok = true
                                response.ret = {start_time, end_time}
                            end
                        else
                            response.error = "GetSet_LoopTimeRange requires at least 2 arguments"
                        end
                    
                    elseif fname == "MIDI_CountEvts" then
                        if #args >= 1 then
                            local take = args[1]
                            -- Handle take object or pointer
                            if type(args[1]) == "table" and args[1].__ptr then
                                -- It's a pointer reference - we can't use it
                                response.error = "Cannot use take pointer from previous call"
                                response.ok = false
                            else
                                local retval, notes, cc, text = reaper.MIDI_CountEvts(take)
                                response.ok = true
                                response.retval = retval
                                response.notes = notes
                                response.cc = cc
                                response.text = text
                            end
                        else
                            response.error = "MIDI_CountEvts requires 1 argument (take)"
                        end
                    
                    elseif fname == "GetItemTakeAndCountMIDI" then
                        -- Combined function to get item, take and count MIDI events
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Count MIDI events
                                    local retval, notes, cc, text = reaper.MIDI_CountEvts(take)
                                    response.ok = true
                                    response.retval = retval
                                    response.notes = notes
                                    response.cc = cc
                                    response.text = text
                                end
                            end
                        else
                            response.error = "GetItemTakeAndCountMIDI requires 2 arguments (item_index, take_index)"
                        end
                    
                    elseif fname == "InsertMIDINoteToItemTake" then
                        -- Combined function to insert MIDI note
                        if #args >= 11 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local pitch = args[3]
                            local velocity = args[4]
                            local start_time = args[5]
                            local duration = args[6]
                            local channel = args[7]
                            local selected = args[8]
                            local muted = args[9]
                            -- args[10] reserved for future use
                            -- args[11] reserved for future use
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Convert time to PPQ
                                    local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, start_time)
                                    local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(take, start_time + duration)
                                    
                                    -- Insert note
                                    local result = reaper.MIDI_InsertNote(take, selected, muted, ppq_start, ppq_end, channel, pitch, velocity, true)
                                    response.ok = result
                                    if not result then
                                        response.error = "Failed to insert MIDI note"
                                    end
                                end
                            end
                        else
                            response.error = "InsertMIDINoteToItemTake requires 11 arguments"
                        end
                    
                    elseif fname == "GetMIDIScaleFromItemTake" then
                        -- Combined function to get MIDI scale
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Get scale
                                    local root, scale, name = reaper.MIDI_GetScale(take)
                                    response.ok = true
                                    response.root = root
                                    response.scale = scale
                                    response.name = name or ""
                                end
                            end
                        else
                            response.error = "GetMIDIScaleFromItemTake requires 2 arguments (item_index, take_index)"
                        end
                    
                    elseif fname == "SortMIDIInItemTake" then
                        -- Combined function to sort MIDI
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Sort MIDI
                                    reaper.MIDI_Sort(take)
                                    response.ok = true
                                end
                            end
                        else
                            response.error = "SortMIDIInItemTake requires 2 arguments (item_index, take_index)"
                        end
                    
                    elseif fname == "InsertMIDICCToItemTake" then
                        -- Combined function to insert MIDI CC
                        if #args >= 7 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local time = args[3]
                            local channel = args[4]
                            local cc_number = args[5]
                            local value = args[6]
                            local selected = args[7]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Convert time to PPQ
                                    local ppq_pos = reaper.MIDI_GetPPQPosFromProjTime(take, time)
                                    
                                    -- Insert CC event
                                    local inserted = reaper.MIDI_InsertCC(take, selected, false, ppq_pos, 0xB0, channel, cc_number, value)
                                    if inserted then
                                        response.ok = true
                                    else
                                        response.ok = false
                                        response.error = "Failed to insert MIDI CC"
                                    end
                                end
                            end
                        else
                            response.error = "InsertMIDICCToItemTake requires 7 arguments"
                        end
                    
                    elseif fname == "SetMIDIScaleToItemTake" then
                        -- Combined function to set MIDI scale
                        if #args >= 5 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local root = args[3]
                            local scale = args[4]
                            local name = args[5] or ""
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Set scale
                                    local result = reaper.MIDI_SetScale(take, root, scale, name)
                                    response.ok = result
                                    if not result then
                                        response.error = "Failed to set MIDI scale"
                                    end
                                end
                            end
                        else
                            response.error = "SetMIDIScaleToItemTake requires 5 arguments"
                        end
                    
                    elseif fname == "SelectAllMIDIInItemTake" then
                        -- Combined function to select all MIDI events
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Select all MIDI events
                                    reaper.MIDI_SelectAll(take, true)
                                    response.ok = true
                                end
                            end
                        else
                            response.error = "SelectAllMIDIInItemTake requires 2 arguments"
                        end
                    
                    elseif fname == "GetAllMIDIEventsFromItemTake" then
                        -- Combined function to get all MIDI events
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Failed to find media item at index " .. tostring(item_index)
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Failed to find take at index " .. tostring(take_index)
                                    response.ok = false
                                else
                                    -- Get all events
                                    local retval, events = reaper.MIDI_GetAllEvts(take, "")
                                    response.ok = retval
                                    response.ret = events
                                    if not retval then
                                        response.error = "Failed to get MIDI events"
                                    end
                                end
                            end
                        else
                            response.error = "GetAllMIDIEventsFromItemTake requires 2 arguments"
                        end
                    
                    elseif fname == "TrackFX_AddByName" then
                        -- Add FX to track by name
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local fx_index = reaper.TrackFX_AddByName(track, args[2], args[3] or false, args[4] or -1)
                                response.ok = true
                                response.ret = fx_index
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_AddByName requires at least 3 arguments"
                        end
                    
                    elseif fname == "TrackFX_GetCount" then
                        -- Get FX count for track
                        if #args >= 1 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    -- Master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local count = reaper.TrackFX_GetCount(track)
                                response.ok = true
                                response.ret = count
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetCount requires 1 argument"
                        end
                    
                    elseif fname == "GetTrackEnvelopeByName" then
                        -- Get envelope by name
                        if #args >= 2 then
                            local track = nil
                            local track_index = args[1]
                            
                            -- Handle case where args[1] might be a table with a numeric value
                            if type(track_index) == "table" then
                                -- Try multiple ways to extract numeric value from table
                                -- Check for direct numeric index
                                if track_index[1] and type(track_index[1]) == "number" then
                                    track_index = track_index[1]
                                -- Check for 'value' key
                                elseif track_index.value and type(track_index.value) == "number" then
                                    track_index = track_index.value
                                -- Check for 'track_index' key
                                elseif track_index.track_index and type(track_index.track_index) == "number" then
                                    track_index = track_index.track_index
                                else
                                    -- Try to find any numeric value in table
                                    for k, v in pairs(track_index) do
                                        if type(v) == "number" then
                                            track_index = v
                                            break
                                        end
                                    end
                                end
                            end
                            
                            if type(track_index) == "number" then
                                if track_index == -1 then
                                    -- Master track
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, track_index)
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                response.error = "Invalid track index type: " .. type(args[1]) .. " (could not extract number from table)"
                                response.ok = false
                            end
                            
                            if track then
                                local envelope = reaper.GetTrackEnvelopeByName(track, args[2])
                                response.ok = true
                                response.ret = envelope
                            elseif response.ok ~= false then
                                -- Only set error if not already set
                                local track_count = reaper.CountTracks(0)
                                response.error = "Track not found at index " .. tostring(track_index) .. " (project has " .. track_count .. " tracks)"
                                response.ok = false
                            end
                        else
                            response.error = "GetTrackEnvelopeByName requires 2 arguments"
                        end
                    
                    elseif fname == "GetTrackAutomationMode" then
                        -- Get track automation mode
                        if #args >= 1 then
                            local track = nil
                            local track_index = args[1]
                            
                            -- Handle case where args[1] might be a table with a numeric value
                            if type(track_index) == "table" then
                                -- Try multiple ways to extract numeric value from table
                                if track_index[1] and type(track_index[1]) == "number" then
                                    track_index = track_index[1]
                                elseif track_index.value and type(track_index.value) == "number" then
                                    track_index = track_index.value
                                elseif track_index.track_index and type(track_index.track_index) == "number" then
                                    track_index = track_index.track_index
                                else
                                    -- Try to find any numeric value in table
                                    for k, v in pairs(track_index) do
                                        if type(v) == "number" then
                                            track_index = v
                                            break
                                        end
                                    end
                                end
                            end
                            
                            if type(track_index) == "number" then
                                track = reaper.GetTrack(0, track_index)
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local mode = reaper.GetTrackAutomationMode(track)
                                response.ok = true
                                response.ret = mode
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "GetTrackAutomationMode requires 1 argument"
                        end
                    
                    elseif fname == "SetTrackAutomationMode" then
                        -- Set track automation mode
                        if #args >= 2 then
                            local track = nil
                            local track_index = args[1]
                            
                            -- Handle case where args[1] might be a table with a numeric value
                            if type(track_index) == "table" then
                                -- Try multiple ways to extract numeric value from table
                                if track_index[1] and type(track_index[1]) == "number" then
                                    track_index = track_index[1]
                                elseif track_index.value and type(track_index.value) == "number" then
                                    track_index = track_index.value
                                elseif track_index.track_index and type(track_index.track_index) == "number" then
                                    track_index = track_index.track_index
                                else
                                    -- Try to find any numeric value in table
                                    for k, v in pairs(track_index) do
                                        if type(v) == "number" then
                                            track_index = v
                                            break
                                        end
                                    end
                                end
                            end
                            
                            if type(track_index) == "number" then
                                track = reaper.GetTrack(0, track_index)
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.SetTrackAutomationMode(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "SetTrackAutomationMode requires 2 arguments"
                        end
                    
                    elseif fname == "TrackFX_Delete" then
                        -- Delete FX from track
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.TrackFX_Delete(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_Delete requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetEnabled" then
                        -- Get FX enabled state
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_GetEnabled(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetEnabled requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_SetEnabled" then
                        -- Set FX enabled state
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.TrackFX_SetEnabled(track, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_SetEnabled requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetFXName" then
                        -- Get FX name (args: track_index, fx_index [, buf_string, buf_size])
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local retval, name = reaper.TrackFX_GetFXName(track, args[2], "", args[4] or 256)
                                if retval then
                                    response.ret = name
                                    response.ok = true
                                else
                                    response.error = "Failed to get FX name"
                                    response.ok = false
                                end
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetFXName requires at least 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetNumParams" then
                        -- Get FX parameter count
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_GetNumParams(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetNumParams requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetParam" then
                        -- Get FX parameter value
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local retval, minval, maxval = reaper.TrackFX_GetParam(track, args[2], args[3])
                                response.value = retval
                                response.min = minval
                                response.max = maxval
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetParam requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_SetParam" then
                        -- Set FX parameter value
                        if #args >= 4 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_SetParam(track, args[2], args[3], args[4])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_SetParam requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetParamName" then
                        -- Get FX parameter name
                        if #args >= 4 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local retval, name = reaper.TrackFX_GetParamName(track, args[2], args[3], "", args[4] or 256)
                                if retval then
                                    response.ret = name
                                    response.ok = true
                                else
                                    response.error = "Failed to get parameter name"
                                    response.ok = false
                                end
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetParamName requires at least 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetPreset" then
                        -- Get FX preset name
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                local retval, name = reaper.TrackFX_GetPreset(track, args[2], "", args[3] or 256)
                                if retval then
                                    response.ret = name
                                    response.ok = true
                                else
                                    response.error = "Failed to get preset name"
                                    response.ok = false
                                end
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetPreset requires at least 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_SetPreset" then
                        -- Set FX preset
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_SetPreset(track, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_SetPreset requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_Show" then
                        -- Show/hide FX window
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.TrackFX_Show(track, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_Show requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetOpen" then
                        -- Get FX window open state
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_GetOpen(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetOpen requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_SetOpen" then
                        -- Set FX window open state
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.TrackFX_SetOpen(track, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_SetOpen requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetChainVisible" then
                        -- Get FX chain visibility
                        if #args >= 1 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_GetChainVisible(track)
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetChainVisible requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_CopyToTrack" then
                        -- Copy/move FX between tracks
                        if #args >= 5 then
                            local src_track = nil
                            local dest_track = nil

                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    src_track = reaper.GetMasterTrack(0)
                                else
                                    src_track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use source track pointer from previous call"
                                response.ok = false
                            else
                                src_track = args[1]
                            end

                            if type(args[3]) == "number" then
                                if args[3] == -1 then
                                    dest_track = reaper.GetMasterTrack(0)
                                else
                                    dest_track = reaper.GetTrack(0, args[3])
                                end
                            elseif type(args[3]) == "table" and args[3].__ptr then
                                response.error = "Cannot use destination track pointer from previous call"
                                response.ok = false
                            else
                                dest_track = args[3]
                            end
                            
                            if src_track and dest_track then
                                reaper.TrackFX_CopyToTrack(src_track, args[2], dest_track, args[4], args[5])
                                response.ok = true
                            else
                                if not src_track then
                                    response.error = "Source track not found"
                                else
                                    response.error = "Destination track not found"
                                end
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_CopyToTrack requires 5 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_GetOffline" then
                        -- Get FX offline state
                        if #args >= 2 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                response.ret = reaper.TrackFX_GetOffline(track, args[2])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_GetOffline requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TrackFX_SetOffline" then
                        -- Set FX offline state
                        if #args >= 3 then
                            local track = nil
                            if type(args[1]) == "number" then
                                if args[1] == -1 then
                                    track = reaper.GetMasterTrack(0)
                                else
                                    track = reaper.GetTrack(0, args[1])
                                end
                            elseif type(args[1]) == "table" and args[1].__ptr then
                                response.error = "Cannot use track pointer from previous call"
                                response.ok = false
                            else
                                track = args[1]
                            end
                            
                            if track then
                                reaper.TrackFX_SetOffline(track, args[2], args[3])
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "TrackFX_SetOffline requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetGlobalAutomationOverride" then
                        -- Get global automation override
                        local mode = reaper.GetGlobalAutomationOverride()
                        response.ok = true
                        response.ret = mode
                    
                    elseif fname == "SetGlobalAutomationOverride" then
                        -- Set global automation override
                        if #args >= 1 then
                            reaper.SetGlobalAutomationOverride(args[1])
                            response.ok = true
                        else
                            response.error = "SetGlobalAutomationOverride requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMainHwnd" then
                        -- Get main window handle
                        local hwnd = reaper.GetMainHwnd()
                        response.ok = true
                        response.ret = hwnd
                    
                    elseif fname == "GetMousePosition" then
                        -- Get current mouse position
                        local x, y = reaper.GetMousePosition()
                        response.ok = true
                        response.ret = {x, y}
                    
                    elseif fname == "GetCursorContext" then
                        -- Get cursor context
                        local context = reaper.GetCursorContext()
                        response.ok = true
                        response.ret = context
                    
                    elseif fname == "ShowMessageBox" then
                        -- Show message box
                        if #args >= 3 then
                            local result = reaper.ShowMessageBox(args[1], args[2], args[3])
                            response.ok = true
                            response.ret = result
                        else
                            response.error = "ShowMessageBox requires 3 arguments (message, title, type)"
                            response.ok = false
                        end
                    
                    elseif fname == "ShowConsoleMsg" then
                        -- Show console message
                        if #args >= 1 then
                            reaper.ShowConsoleMsg(args[1])
                            response.ok = true
                        else
                            response.error = "ShowConsoleMsg requires 1 argument (message)"
                            response.ok = false
                        end
                    
                    elseif fname == "ClearConsole" then
                        -- Clear console
                        reaper.ClearConsole()
                        response.ok = true
                    
                    elseif fname == "PCM_Source_CreateFromFile" then
                        -- Create PCM source from file
                        if #args >= 1 then
                            local source = reaper.PCM_Source_CreateFromFile(args[1])
                            response.ok = true
                            response.ret = source
                        else
                            response.error = "PCM_Source_CreateFromFile requires 1 argument (filename)"
                            response.ok = false
                        end
                    
                    elseif fname == "SetMediaItemTake_Source" then
                        -- Set media source on take
                        if #args >= 2 then
                            local retval = reaper.SetMediaItemTake_Source(args[1], args[2])
                            response.ok = true
                            response.ret = retval
                        else
                            response.error = "SetMediaItemTake_Source requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaItemTake_Source" then
                        -- Get media source from take
                        if #args >= 1 then
                            local source = reaper.GetMediaItemTake_Source(args[1])
                            response.ok = true
                            response.ret = source
                        else
                            response.error = "GetMediaItemTake_Source requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaSourceSampleRate" then
                        -- Get sample rate from media source
                        if #args >= 1 then
                            local samplerate = reaper.GetMediaSourceSampleRate(args[1])
                            response.ok = true
                            response.ret = samplerate
                        else
                            response.error = "GetMediaSourceSampleRate requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaSourceNumChannels" then
                        -- Get channel count from media source
                        if #args >= 1 then
                            local channels = reaper.GetMediaSourceNumChannels(args[1])
                            response.ok = true
                            response.ret = channels
                        else
                            response.error = "GetMediaSourceNumChannels requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "DB2SLIDER" then
                        -- Convert dB to slider value
                        if #args >= 1 then
                            local slider = reaper.DB2SLIDER(args[1])
                            response.ok = true
                            response.ret = slider
                        else
                            response.error = "DB2SLIDER requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "SLIDER2DB" then
                        -- Convert slider value to dB
                        if #args >= 1 then
                            local db = reaper.SLIDER2DB(args[1])
                            response.ok = true
                            response.ret = db
                        else
                            response.error = "SLIDER2DB requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "AddTakeToMediaItem" then
                        -- Add take to media item
                        if #args >= 1 then
                            local take = reaper.AddTakeToMediaItem(args[1])
                            response.ok = true
                            response.ret = take
                        else
                            response.error = "AddTakeToMediaItem requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "CountTakes" then
                        -- Count takes in media item
                        if #args >= 1 then
                            local count = reaper.CountTakes(args[1])
                            response.ok = true
                            response.ret = count
                        else
                            response.error = "CountTakes requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetTake" then
                        -- Get take from item by indices
                        if #args >= 2 then
                            local item = reaper.GetMediaItem(0, args[1])
                            if item then
                                local take = reaper.GetMediaItemTake(item, args[2])
                                response.ok = true
                                response.ret = take
                            else
                                response.error = "Item not found"
                                response.ok = false
                            end
                        else
                            response.error = "GetTake requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "IsTrackVisible" then
                        -- Check if track is visible in TCP/MCP
                        if #args >= 2 then
                            local visible = reaper.IsTrackVisible(args[1], args[2])
                            response.ok = true
                            response.ret = visible
                        else
                            response.error = "IsTrackVisible requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetOnlyTrackSelected" then
                        -- Set only one track selected
                        if #args >= 1 then
                            local track = args[1]
                            -- Handle track index
                            if type(track) == "number" then
                                track = reaper.GetTrack(0, track)
                            end
                            if track then
                                reaper.SetOnlyTrackSelected(track)
                                response.ok = true
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "SetOnlyTrackSelected requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "NamedCommandLookup" then
                        -- Look up named command
                        if #args >= 1 then
                            local cmd_id = reaper.NamedCommandLookup(args[1])
                            response.ok = true
                            response.ret = cmd_id
                        else
                            response.error = "NamedCommandLookup requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "ReverseNamedCommandLookup" then
                        -- Reverse command lookup
                        if #args >= 2 then
                            local name = reaper.ReverseNamedCommandLookup(args[1], args[2])
                            response.ok = true
                            response.ret = name or ""
                        else
                            response.error = "ReverseNamedCommandLookup requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetToggleCommandStateEx" then
                        -- Get toggle command state for section
                        if #args >= 2 then
                            local state = reaper.GetToggleCommandStateEx(args[1], args[2])
                            response.ok = true
                            response.ret = state
                        else
                            response.error = "GetToggleCommandStateEx requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "RefreshToolbar" then
                        -- Refresh toolbar
                        if #args >= 1 then
                            reaper.RefreshToolbar(args[1])
                            response.ok = true
                        else
                            response.error = "RefreshToolbar requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "EnumerateFiles" then
                        -- Enumerate files
                        if #args >= 2 then
                            local file = reaper.EnumerateFiles(args[1], args[2])
                            response.ok = true
                            response.ret = file or ""
                        else
                            response.error = "EnumerateFiles requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "EnumerateSubdirectories" then
                        -- Enumerate subdirectories
                        if #args >= 2 then
                            local dir = reaper.EnumerateSubdirectories(args[1], args[2])
                            response.ok = true
                            response.ret = dir or ""
                        else
                            response.error = "EnumerateSubdirectories requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetProjectPath" then
                        -- Get project path
                        if #args >= 1 then
                            local path = reaper.GetProjectPath(args[1])
                            response.ok = true
                            response.ret = path or ""
                        else
                            response.error = "GetProjectPath requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetProjectName" then
                        -- Get project name
                        if #args >= 1 then
                            local name = reaper.GetProjectName(args[1])
                            response.ok = true
                            response.ret = name or ""
                        else
                            response.error = "GetProjectName requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "IsProjectDirty" then
                        -- Check if project is dirty
                        if #args >= 1 then
                            local dirty = reaper.IsProjectDirty(args[1])
                            response.ok = true
                            response.ret = dirty
                        else
                            response.error = "IsProjectDirty requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetResourcePath" then
                        -- Get resource path
                        local path = reaper.GetResourcePath()
                        response.ok = true
                        response.ret = path
                    
                    elseif fname == "GetExePath" then
                        -- Get exe path
                        local path = reaper.GetExePath()
                        response.ok = true
                        response.ret = path
                    
                    elseif fname == "GetExtState" then
                        -- Get extended state
                        if #args >= 2 then
                            local value = reaper.GetExtState(args[1], args[2])
                            response.ok = true
                            response.ret = value or ""
                        else
                            response.error = "GetExtState requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetExtState" then
                        -- Set extended state
                        if #args >= 4 then
                            reaper.SetExtState(args[1], args[2], args[3], args[4])
                            response.ok = true
                        else
                            response.error = "SetExtState requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "HasExtState" then
                        -- Check if extended state exists
                        if #args >= 2 then
                            local exists = reaper.HasExtState(args[1], args[2])
                            response.ok = true
                            response.ret = exists
                        else
                            response.error = "HasExtState requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DeleteExtState" then
                        -- Delete extended state
                        if #args >= 3 then
                            reaper.DeleteExtState(args[1], args[2], args[3])
                            response.ok = true
                        else
                            response.error = "DeleteExtState requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DockWindowActivate" then
                        -- Activate docker window
                        if #args >= 1 then
                            reaper.DockWindowActivate(args[1])
                            response.ok = true
                        else
                            response.error = "DockWindowActivate requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "DockWindowAddEx" then
                        -- Add window to docker
                        if #args >= 4 then
                            reaper.DockWindowAddEx(args[1], args[2], args[3], args[4])
                            response.ok = true
                        else
                            response.error = "DockWindowAddEx requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DockWindowRefresh" then
                        -- Refresh docker windows
                        reaper.DockWindowRefresh()
                        response.ok = true
                    
                    elseif fname == "DockWindowRefreshByName" then
                        -- Refresh docker window by name
                        if #args >= 1 then
                            reaper.DockWindowRefreshByName(args[1])
                            response.ok = true
                        else
                            response.error = "DockWindowRefreshByName requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "DockGetPosition" then
                        -- Get docker position
                        if #args >= 1 then
                            local pos = reaper.DockGetPosition(args[1])
                            response.ok = true
                            response.ret = pos
                        else
                            response.error = "DockGetPosition requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "DeleteTakeFromMediaItem" then
                        -- Delete take from item
                        if #args >= 1 then
                            local result = reaper.DeleteTakeFromMediaItem(args[1])
                            response.ok = result
                        else
                            response.error = "DeleteTakeFromMediaItem requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetNumTakeMarkers" then
                        -- Get number of take markers
                        if #args >= 1 then
                            local count = reaper.GetNumTakeMarkers(args[1])
                            response.ok = true
                            response.ret = count
                        else
                            response.error = "GetNumTakeMarkers requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetTakeMarker" then
                        -- Get take marker info
                        if #args >= 2 then
                            local position, name, color = reaper.GetTakeMarker(args[1], args[2])
                            response.ok = true
                            response.position = position
                            response.name = name or ""
                            response.color = color or 0
                        else
                            response.error = "GetTakeMarker requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetTakeMarker" then
                        -- Set/add take marker
                        if #args >= 5 then
                            local idx = reaper.SetTakeMarker(args[1], args[2], args[3], args[4], args[5])
                            response.ok = true
                            response.ret = idx
                        else
                            response.error = "SetTakeMarker requires 5 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DeleteTakeMarker" then
                        -- Delete take marker
                        if #args >= 2 then
                            local result = reaper.DeleteTakeMarker(args[1], args[2])
                            response.ok = result
                        else
                            response.error = "DeleteTakeMarker requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "CountTakeEnvelopes" then
                        -- Count take envelopes
                        if #args >= 1 then
                            local count = reaper.CountTakeEnvelopes(args[1])
                            response.ok = true
                            response.ret = count
                        else
                            response.error = "CountTakeEnvelopes requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetTakeEnvelopeByName" then
                        -- Get take envelope by name
                        if #args >= 2 then
                            local env = reaper.GetTakeEnvelopeByName(args[1], args[2])
                            response.ok = true
                            response.ret = env
                        else
                            response.error = "GetTakeEnvelopeByName requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "EnumProjectMarkers" then
                        -- Enumerate project markers
                        if #args >= 1 then
                            local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(args[1])
                            response.ok = retval > 0
                            response.isrgn = isrgn
                            response.pos = pos
                            response.rgnend = rgnend
                            response.name = name or ""
                            response.markrgnindexnumber = markrgnindexnumber
                        else
                            response.error = "EnumProjectMarkers requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "EnumProjectMarkers3" then
                        -- Enumerate project markers with color
                        if #args >= 2 then
                            local retval, isrgn, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3(args[1], args[2])
                            response.ok = retval > 0
                            response.isrgn = isrgn
                            response.pos = pos
                            response.rgnend = rgnend
                            response.name = name or ""
                            response.markrgnindexnumber = markrgnindexnumber
                            response.color = color
                        else
                            response.error = "EnumProjectMarkers3 requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "CountProjectMarkers" then
                        -- Count project markers
                        if #args >= 1 then
                            local num_markers, num_regions = reaper.CountProjectMarkers(args[1])
                            response.ok = true
                            response.num_markers = num_markers
                            response.num_regions = num_regions
                        else
                            response.error = "CountProjectMarkers requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "SetProjectMarker" then
                        -- Set project marker
                        if #args >= 5 then
                            local result = reaper.SetProjectMarker(args[1], args[2], args[3], args[4], args[5])
                            response.ok = result
                        else
                            response.error = "SetProjectMarker requires 5 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetProjectMarker3" then
                        -- Set project marker with color
                        if #args >= 7 then
                            local result = reaper.SetProjectMarker3(args[1], args[2], args[3], args[4], args[5], args[6], args[7])
                            response.ok = result
                        else
                            response.error = "SetProjectMarker3 requires 7 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DeleteProjectMarker" then
                        -- Delete project marker
                        if #args >= 3 then
                            local result = reaper.DeleteProjectMarker(args[1], args[2], args[3])
                            response.ok = true
                            response.ret = result
                        else
                            response.error = "DeleteProjectMarker requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GoToMarker" then
                        -- Go to marker
                        if #args >= 3 then
                            reaper.GoToMarker(args[1], args[2], args[3])
                            response.ok = true
                        else
                            response.error = "GoToMarker requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "CountTrackEnvelopes" then
                        -- Count track envelopes
                        if #args >= 1 then
                            local count = reaper.CountTrackEnvelopes(args[1])
                            response.ok = true
                            response.ret = count
                        else
                            response.error = "CountTrackEnvelopes requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetTrackName" then
                        -- Get track name
                        if #args >= 1 then
                            local track = reaper.GetTrack(0, args[1])
                            if track then
                                local retval, name = reaper.GetTrackName(track)
                                response.ok = retval
                                response.ret = name or ""
                            else
                                response.error = "Track not found"
                                response.ok = false
                            end
                        else
                            response.error = "GetTrackName requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaItem_Track" then
                        -- Get item's track
                        if #args >= 1 then
                            local track = reaper.GetMediaItem_Track(args[1])
                            response.ok = true
                            response.ret = track
                        else
                            response.error = "GetMediaItem_Track requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "TakeIsMIDI" then
                        -- Check if take is MIDI
                        if #args >= 1 then
                            local ismidi = reaper.TakeIsMIDI(args[1])
                            response.ok = true
                            response.ret = ismidi
                        else
                            response.error = "TakeIsMIDI requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "MIDI_GetNote" then
                        -- Get MIDI note
                        if #args >= 2 then
                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(args[1], args[2])
                            response.ok = retval
                            response.selected = selected
                            response.muted = muted
                            response.startppqpos = startppqpos
                            response.endppqpos = endppqpos
                            response.chan = chan
                            response.pitch = pitch
                            response.vel = vel
                        else
                            response.error = "MIDI_GetNote requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "TransposeMIDINotes" then
                        -- Transpose MIDI notes by item/take indices
                        if #args >= 4 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local semitones = args[3]
                            local selected_only = args[4]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Count notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        local transposed = 0
                                        
                                        -- Transpose each note
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            
                                            if retval and (not selected_only or selected) then
                                                local new_pitch = math.max(0, math.min(127, pitch + semitones))
                                                reaper.MIDI_SetNote(take, i, selected, muted, startppqpos, endppqpos, chan, new_pitch, vel, false)
                                                transposed = transposed + 1
                                            end
                                        end
                                        
                                        -- Sort notes
                                        reaper.MIDI_Sort(take)
                                        
                                        response.ok = true
                                        response.transposed = transposed
                                        response.notes = notes
                                    end
                                end
                            end
                        else
                            response.error = "TransposeMIDINotes requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "QuantizeMIDINotes" then
                        -- Quantize MIDI notes by item/take indices
                        if #args >= 4 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local grid_size = args[3]  -- In PPQ
                            local strength = args[4]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Count notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        local quantized = 0
                                        
                                        -- Quantize each note
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            
                                            if retval then
                                                -- Calculate quantized position
                                                local nearest_grid = math.floor(startppqpos / grid_size + 0.5) * grid_size
                                                -- Apply strength
                                                local new_pos = startppqpos + (nearest_grid - startppqpos) * strength
                                                -- Calculate new end position (maintain length)
                                                local length = endppqpos - startppqpos
                                                local new_end = new_pos + length
                                                
                                                reaper.MIDI_SetNote(take, i, selected, muted, new_pos, new_end, chan, pitch, vel, false)
                                                quantized = quantized + 1
                                            end
                                        end
                                        
                                        -- Sort notes
                                        reaper.MIDI_Sort(take)
                                        
                                        response.ok = true
                                        response.quantized = quantized
                                        response.notes = notes
                                    end
                                end
                            end
                        else
                            response.error = "QuantizeMIDINotes requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "HumanizeMIDITiming" then
                        -- Humanize MIDI notes by item/take indices
                        if #args >= 4 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local timing_amount = args[3]  -- In seconds
                            local velocity_amount = args[4]  -- 0-1 range
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Count notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        local humanized = 0
                                        
                                        local ppq_per_quarter = 960
                                        local max_timing_shift = timing_amount * ppq_per_quarter
                                        
                                        -- Humanize each note
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            
                                            if retval then
                                                -- Randomize timing
                                                local timing_shift = (math.random() * 2 - 1) * max_timing_shift
                                                local new_start = math.max(0, startppqpos + timing_shift)
                                                local new_end = endppqpos + timing_shift
                                                
                                                -- Randomize velocity
                                                local vel_shift = (math.random() * 2 - 1) * velocity_amount * 127
                                                local new_vel = math.max(1, math.min(127, math.floor(vel + vel_shift)))
                                                
                                                reaper.MIDI_SetNote(take, i, selected, muted, new_start, new_end, chan, pitch, new_vel, false)
                                                humanized = humanized + 1
                                            end
                                        end
                                        
                                        -- Sort notes
                                        reaper.MIDI_Sort(take)
                                        
                                        response.ok = true
                                        response.humanized = humanized
                                        response.notes = notes
                                    end
                                end
                            end
                        else
                            response.error = "HumanizeMIDITiming requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "AnalyzeMIDIPattern" then
                        -- Analyze MIDI pattern by item/take indices
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Count notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        
                                        -- Analyze first few notes for patterns
                                        local pitches = {}
                                        local velocities = {}
                                        local max_notes = math.min(notes, 50)
                                        
                                        for i = 0, max_notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            if retval then
                                                table.insert(pitches, pitch)
                                                table.insert(velocities, vel)
                                            end
                                        end
                                        
                                        if #pitches == 0 then
                                            response.ok = true
                                            response.analysis = "No notes to analyze"
                                        else
                                            -- Basic pattern analysis
                                            local min_pitch = math.min(table.unpack(pitches))
                                            local max_pitch = math.max(table.unpack(pitches))
                                            local pitch_range = max_pitch - min_pitch
                                            
                                            local total_vel = 0
                                            for _, v in ipairs(velocities) do
                                                total_vel = total_vel + v
                                            end
                                            local avg_velocity = total_vel / #velocities
                                            
                                            -- Detect intervals
                                            local ascending = true
                                            local descending = true
                                            for i = 2, #pitches do
                                                if pitches[i] <= pitches[i-1] then
                                                    ascending = false
                                                end
                                                if pitches[i] >= pitches[i-1] then
                                                    descending = false
                                                end
                                            end
                                            
                                            local pattern_type = "mixed"
                                            if ascending then pattern_type = "ascending"
                                            elseif descending then pattern_type = "descending"
                                            end
                                            
                                            response.ok = true
                                            response.notes_analyzed = #pitches
                                            response.pitch_range = pitch_range
                                            response.pattern_type = pattern_type
                                            response.avg_velocity = avg_velocity
                                        end
                                    end
                                end
                            end
                        else
                            response.error = "AnalyzeMIDIPattern requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GenerateMIDIChordSequence" then
                        -- Generate MIDI chord sequence by item/take indices
                        if #args >= 4 then
                            local item_index = args[1]
                            local take_index = args[2]
                            local chord_progression = args[3]  -- Table of chord names
                            local duration = args[4]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Chord definitions (simplified)
                                        local chord_types = {
                                            maj = {0, 4, 7},
                                            min = {0, 3, 7},
                                            ["7"] = {0, 4, 7, 10},
                                            maj7 = {0, 4, 7, 11},
                                            min7 = {0, 3, 7, 10},
                                            dim = {0, 3, 6},
                                            aug = {0, 4, 8}
                                        }
                                        
                                        -- Note name to MIDI mapping
                                        local note_map = {C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11}
                                        
                                        local ppq_per_quarter = 960
                                        local current_pos = 0
                                        local chords_added = 0
                                        
                                        for _, chord_name in ipairs(chord_progression) do
                                            -- Parse chord (e.g., "Cmaj", "Am7")
                                            local root_note = nil
                                            local chord_type = nil
                                            
                                            -- Find root note
                                            for note, value in pairs(note_map) do
                                                if string.sub(chord_name, 1, #note) == note then
                                                    root_note = value + 60  -- Middle octave
                                                    local rest = string.sub(chord_name, #note + 1)
                                                    
                                                    -- Handle sharps/flats
                                                    if string.sub(rest, 1, 1) == "#" then
                                                        root_note = root_note + 1
                                                        rest = string.sub(rest, 2)
                                                    elseif string.sub(rest, 1, 1) == "b" then
                                                        root_note = root_note - 1
                                                        rest = string.sub(rest, 2)
                                                    end
                                                    
                                                    -- Find chord type
                                                    chord_type = chord_types[rest] or chord_types.maj
                                                    break
                                                end
                                            end
                                            
                                            if root_note then
                                                -- Insert chord notes
                                                for _, interval in ipairs(chord_type) do
                                                    local pitch = root_note + interval
                                                    reaper.MIDI_InsertNote(take, false, false, current_pos, 
                                                                          current_pos + (duration * ppq_per_quarter),
                                                                          0, pitch, 80, false)
                                                end
                                                chords_added = chords_added + 1
                                                current_pos = current_pos + (duration * ppq_per_quarter)
                                            end
                                        end
                                        
                                        -- Sort notes
                                        reaper.MIDI_Sort(take)
                                        
                                        response.ok = true
                                        response.chords_added = chords_added
                                        response.progression = table.concat(chord_progression, " → ")
                                    end
                                end
                            end
                        else
                            response.error = "GenerateMIDIChordSequence requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DetectMIDIChordProgressions" then
                        -- Detect chord progressions by item/take indices
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Get all notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        
                                        -- Group notes by time to find chords
                                        local time_groups = {}
                                        
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            if retval then
                                                -- Quantize time to group simultaneous notes
                                                local time_key = math.floor(startppqpos / 240) * 240  -- Quarter note quantization
                                                
                                                if not time_groups[time_key] then
                                                    time_groups[time_key] = {}
                                                end
                                                table.insert(time_groups[time_key], pitch)
                                            end
                                        end
                                        
                                        -- Analyze chords
                                        local chords = {}
                                        local sorted_times = {}
                                        for time, _ in pairs(time_groups) do
                                            table.insert(sorted_times, time)
                                        end
                                        table.sort(sorted_times)
                                        
                                        local count = 0
                                        for _, time in ipairs(sorted_times) do
                                            if count >= 10 then break end  -- First 10 chords
                                            
                                            local pitches = time_groups[time]
                                            if #pitches >= 3 then  -- At least 3 notes for a chord
                                                -- Sort pitches
                                                table.sort(pitches)
                                                
                                                -- Basic chord detection
                                                local root = pitches[1] % 12
                                                local note_names = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
                                                local chord_name = note_names[root + 1]
                                                
                                                -- Check for major/minor (simplified)
                                                if #pitches >= 3 then
                                                    local third = (pitches[2] - pitches[1]) % 12
                                                    if third == 4 then
                                                        chord_name = chord_name .. " major"
                                                    elseif third == 3 then
                                                        chord_name = chord_name .. " minor"
                                                    end
                                                end
                                                
                                                table.insert(chords, chord_name)
                                                count = count + 1
                                            end
                                        end
                                        
                                        if #chords > 0 then
                                            response.ok = true
                                            response.progression = table.concat(chords, " → ")
                                        else
                                            response.ok = true
                                            response.progression = "No clear chord progression detected"
                                        end
                                    end
                                end
                            end
                        else
                            response.error = "DetectMIDIChordProgressions requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMIDINoteDistribution" then
                        -- Get MIDI note distribution by item/take indices
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Get all notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        
                                        -- Count note occurrences
                                        local pitch_counts = {}
                                        local total_velocity = 0
                                        
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            if retval then
                                                pitch_counts[pitch] = (pitch_counts[pitch] or 0) + 1
                                                total_velocity = total_velocity + vel
                                            end
                                        end
                                        
                                        -- Build distribution info
                                        local distribution = {}
                                        for pitch, count in pairs(pitch_counts) do
                                            table.insert(distribution, {pitch=pitch, count=count})
                                        end
                                        
                                        -- Sort by count
                                        table.sort(distribution, function(a, b) return a.count > b.count end)
                                        
                                        response.ok = true
                                        response.notes_total = notes
                                        response.distribution = distribution
                                        response.avg_velocity = notes > 0 and (total_velocity / notes) or 0
                                    end
                                end
                            end
                        else
                            response.error = "GetMIDINoteDistribution requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DetectMIDIKeySignature" then
                        -- Detect key signature by item/take indices
                        if #args >= 2 then
                            local item_index = args[1]
                            local take_index = args[2]
                            
                            -- Get item
                            local item = reaper.GetMediaItem(0, item_index)
                            if not item then
                                response.error = "Item not found"
                                response.ok = false
                            else
                                -- Get take
                                local take = reaper.GetMediaItemTake(item, take_index)
                                if not take then
                                    response.error = "Take not found"
                                    response.ok = false
                                else
                                    -- Check if MIDI
                                    if not reaper.TakeIsMIDI(take) then
                                        response.error = "Take is not MIDI"
                                        response.ok = false
                                    else
                                        -- Get all notes
                                        local retval, notes = reaper.MIDI_CountEvts(take)
                                        
                                        -- Count pitch classes
                                        local pitch_classes = {}
                                        for i = 0, 11 do
                                            pitch_classes[i] = 0
                                        end
                                        
                                        for i = 0, notes - 1 do
                                            local retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                            if retval then
                                                local pitch_class = pitch % 12
                                                pitch_classes[pitch_class] = pitch_classes[pitch_class] + 1
                                            end
                                        end
                                        
                                        -- Key profiles (simplified)
                                        local major_profile = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88}
                                        local minor_profile = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}
                                        
                                        local note_names = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
                                        
                                        -- Calculate correlation with each key
                                        local best_major_key = nil
                                        local best_major_score = -1
                                        local best_minor_key = nil
                                        local best_minor_score = -1
                                        
                                        for root = 0, 11 do
                                            -- Calculate major correlation
                                            local major_score = 0
                                            local minor_score = 0
                                            
                                            for i = 0, 11 do
                                                local shifted_idx = (i + root) % 12
                                                major_score = major_score + pitch_classes[shifted_idx] * major_profile[i + 1]
                                                minor_score = minor_score + pitch_classes[shifted_idx] * minor_profile[i + 1]
                                            end
                                            
                                            if major_score > best_major_score then
                                                best_major_score = major_score
                                                best_major_key = root
                                            end
                                            
                                            if minor_score > best_minor_score then
                                                best_minor_score = minor_score
                                                best_minor_key = root
                                            end
                                        end
                                        
                                        -- Determine major or minor
                                        local key, confidence
                                        if best_major_score > best_minor_score then
                                            key = note_names[best_major_key + 1] .. " major"
                                            confidence = (best_major_score / (best_major_score + best_minor_score)) * 100
                                        else
                                            key = note_names[best_minor_key + 1] .. " minor"
                                            confidence = (best_minor_score / (best_major_score + best_minor_score)) * 100
                                        end
                                        
                                        response.ok = true
                                        response.key = key
                                        response.confidence = confidence
                                        response.notes_analyzed = notes
                                    end
                                end
                            end
                        else
                            response.error = "DetectMIDIKeySignature requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "Master_GetTempo" then
                        -- Get master tempo
                        local tempo = reaper.Master_GetTempo()
                        response.ok = true
                        response.ret = tempo
                    
                    elseif fname == "CountTempoTimeSigMarkers" then
                        -- Count tempo/time sig markers
                        if #args >= 1 then
                            local count = reaper.CountTempoTimeSigMarkers(args[1])
                            response.ok = true
                            response.ret = count
                        else
                            response.error = "CountTempoTimeSigMarkers requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "PCM_Source_GetSectionInfo" then
                        -- Get PCM source section info
                        if #args >= 2 then
                            local source = args[1]
                            local offset = args[2]
                            -- Note: This is a simplified version - real API has more params
                            -- For video detection, we'll check file extension
                            local filename_result = reaper.GetMediaSourceFileName(source, "")
                            local has_video = false
                            if filename_result and filename_result ~= "" then
                                local ext = filename_result:match("%.([^%.]+)$")
                                if ext then
                                    ext = ext:lower()
                                    has_video = (ext == "mp4" or ext == "mov" or ext == "avi" or 
                                               ext == "mkv" or ext == "webm" or ext == "wmv")
                                end
                            end
                            response.ok = true
                            response.has_video = has_video
                            response.ret = true
                        else
                            response.error = "PCM_Source_GetSectionInfo requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaSourceFileName" then
                        -- Get media source filename
                        if #args >= 2 then
                            local filename = reaper.GetMediaSourceFileName(args[1], args[2])
                            response.ok = true
                            response.ret = filename
                        else
                            response.error = "GetMediaSourceFileName requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetProjectInfo" then
                        -- Get project info (simplified)
                        if #args >= 2 then
                            local proj = args[1]
                            local param = args[2]
                            if param == "PROJECT_FRAMERATE" then
                                -- Get project frame rate (default 30)
                                local fps = 30.0  -- Default
                                response.ok = true
                                response.ret = fps
                            else
                                response.error = "Unknown project info parameter: " .. param
                                response.ok = false
                            end
                        else
                            response.error = "GetProjectInfo requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "SetEditCurPos" then
                        -- Set edit cursor position
                        if #args >= 3 then
                            reaper.SetEditCurPos(args[1], args[2], args[3])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "SetEditCurPos requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "PCM_Source_BuildPeaks" then
                        -- Build peaks for PCM source
                        if #args >= 2 then
                            local ret = reaper.PCM_Source_BuildPeaks(args[1], args[2])
                            response.ok = true
                            response.ret = ret
                        else
                            response.error = "PCM_Source_BuildPeaks requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "UpdateItemInProject" then
                        -- Update item in project
                        if #args >= 1 then
                            reaper.UpdateItemInProject(args[1])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "UpdateItemInProject requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetSet_ArrangeView2" then
                        -- Get/set arrange view
                        if #args >= 4 then
                            local screen_x_start, screen_x_end = reaper.GetSet_ArrangeView2(args[1], args[2], args[3], args[4])
                            response.ok = true
                            response.start_time = screen_x_start
                            response.end_time = screen_x_end
                            response.ret = true
                        else
                            response.error = "GetSet_ArrangeView2 requires 4 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetMediaItemTakeInfo_Value" then
                        -- Get take info value
                        if #args >= 2 then
                            local value = reaper.GetMediaItemTakeInfo_Value(args[1], args[2])
                            response.ok = true
                            response.ret = value
                        else
                            response.error = "GetMediaItemTakeInfo_Value requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "DeleteExtState" then
                        -- Delete extended state
                        if #args >= 3 then
                            reaper.DeleteExtState(args[1], args[2], args[3])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "DeleteExtState requires 3 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetResourcePath" then
                        -- Get REAPER resource path
                        local path = reaper.GetResourcePath()
                        response.ok = true
                        response.ret = path
                    
                    elseif fname == "ShowConsoleMsg" then
                        -- Show console message
                        if #args >= 1 then
                            reaper.ShowConsoleMsg(args[1])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "ShowConsoleMsg requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "ValidatePtr" then
                        -- Validate pointer
                        if #args >= 2 then
                            local ptr = reaper.ValidatePtr(args[1], args[2])
                            response.ok = true
                            response.ret = ptr
                        else
                            response.error = "ValidatePtr requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "GetCurrentProjectInLoadSave" then
                        -- Get current project
                        local proj = reaper.GetCurrentProjectInLoadSave()
                        response.ok = true
                        response.ret = proj
                    
                    elseif fname == "Main_openProject" then
                        -- Open project
                        if #args >= 1 then
                            reaper.Main_openProject(args[1])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "Main_openProject requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetProjectName" then
                        -- Get project name
                        if #args >= 2 then
                            local name = reaper.GetProjectName(args[1], args[2])
                            response.ok = true
                            response.ret = name
                        else
                            response.error = "GetProjectName requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "IsProjectDirty" then
                        -- Check if project is dirty
                        if #args >= 1 then
                            local dirty = reaper.IsProjectDirty(args[1])
                            response.ok = true
                            response.ret = dirty
                        else
                            response.error = "IsProjectDirty requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "GetProjectNotes" then
                        -- Get project notes
                        if #args >= 1 then
                            local notes = reaper.GetProjectNotes(args[1])
                            response.ok = true
                            response.ret = notes
                        else
                            response.error = "GetProjectNotes requires 1 argument"
                            response.ok = false
                        end
                    
                    elseif fname == "SetProjectNotes" then
                        -- Set project notes
                        if #args >= 2 then
                            reaper.SetProjectNotes(args[1], args[2])
                            response.ok = true
                            response.ret = true
                        else
                            response.error = "SetProjectNotes requires 2 arguments"
                            response.ok = false
                        end
                    
                    elseif fname == "MIDI_SetNote" then
                        -- Set MIDI note properties
                        if #args >= 9 then
                            local retval = reaper.MIDI_SetNote(args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9])
                            response.ok = retval
                            response.ret = retval
                        else
                            response.error = "MIDI_SetNote requires 9 arguments"
                            response.ok = false
                        end
                    
                    -- Transport
                    elseif fname == "OnPlayButton" then
                        reaper.OnPlayButton()
                        response.ok = true

                    elseif fname == "OnStopButton" then
                        reaper.OnStopButton()
                        response.ok = true

                    elseif fname == "OnPauseButton" then
                        reaper.OnPauseButton()
                        response.ok = true

                    elseif fname == "OnRecordButton" then
                        reaper.OnRecordButton()
                        response.ok = true

                    elseif fname == "GetPlayPosition" then
                        response.ok = true
                        response.ret = reaper.GetPlayPosition()

                    -- Undo/Redo
                    elseif fname == "Undo_DoUndo2" then
                        response.ok = true
                        response.ret = reaper.Undo_DoUndo2(args[1] or 0)

                    elseif fname == "Undo_DoRedo2" then
                        response.ok = true
                        response.ret = reaper.Undo_DoRedo2(args[1] or 0)

                    elseif fname == "GetUndoState" then
                        response.ok = true
                        response.can_undo = reaper.Undo_CanUndo2(0) or ""
                        response.can_redo = reaper.Undo_CanRedo2(0) or ""

                    -- Project
                    elseif fname == "GetProjectLength" then
                        response.ok = true
                        response.ret = reaper.GetProjectLength(args[1] or 0)

                    elseif fname == "SetCurrentBPM" then
                        reaper.SetCurrentBPM(args[1] or 0, args[2], args[3])
                        response.ok = true

                    elseif fname == "SetTimeSignature" then
                        -- Use tempo/time sig marker at position 0
                        local tempo = reaper.Master_GetTempo()
                        reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, tempo, args[1], args[2], false)
                        reaper.UpdateTimeline()
                        response.ok = true

                    elseif fname == "Main_OnCommandEx" then
                        local cmd = args[1]
                        if type(cmd) == "string" then
                            cmd = reaper.NamedCommandLookup(cmd)
                        end
                        reaper.Main_OnCommand(cmd, args[2] or 0)
                        response.ok = true

                    -- Markers/Regions
                    elseif fname == "AddProjectMarker2" then
                        local idx = reaper.AddProjectMarker2(args[1] or 0, args[2], args[3], args[4], args[5] or "", args[6] or -1, args[7] or 0)
                        response.ok = true
                        response.ret = idx

                    elseif fname == "GoToRegion" then
                        reaper.GoToRegion(args[1] or 0, args[2], args[3] or false)
                        response.ok = true

                    -- Media Items
                    elseif fname == "GetItemInfo" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                response.ok = true
                                response.position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                                response.length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                                response.mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1
                                response.volume = reaper.GetMediaItemInfo_Value(item, "D_VOL")
                                response.fadein = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
                                response.fadeout = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
                            end
                        end

                    elseif fname == "SetMediaItemInfo_Value" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                reaper.SetMediaItemInfo_Value(item, args[3], args[4])
                                reaper.UpdateArrange()
                                response.ok = true
                            end
                        end

                    elseif fname == "SplitMediaItem" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local new_item = reaper.SplitMediaItem(item, args[3])
                                response.ok = new_item ~= nil
                                if not response.ok then
                                    response.error = "Split failed - position may be outside item bounds"
                                end
                            end
                        end

                    elseif fname == "DuplicateItem" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                reaper.Main_OnCommand(40289, 0) -- Unselect all items
                                reaper.SetMediaItemSelected(item, true)
                                reaper.Main_OnCommand(41295, 0) -- Duplicate items
                                response.ok = true
                            end
                        end

                    -- MIDI Operations
                    elseif fname == "CreateMIDIItem" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.CreateNewMIDIItemInProj(track, args[2], args[3])
                            response.ok = item ~= nil
                            if not response.ok then
                                response.error = "Failed to create MIDI item"
                            end
                        end

                    elseif fname == "GetMIDIItemInfo" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local take = reaper.GetActiveTake(item)
                                if not take or not reaper.TakeIsMIDI(take) then
                                    response.ok = false
                                    response.error = "Item is not a MIDI item"
                                else
                                    local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
                                    response.ok = true
                                    response.position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                                    response.length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                                    response.note_count = note_count
                                end
                            end
                        end

                    elseif fname == "MIDI_InsertNote" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local take = reaper.GetActiveTake(item)
                                if not take then
                                    response.ok = false
                                    response.error = "No active take"
                                else
                                    -- args: track, item, selected, muted, start_ppq, end_ppq, chan, pitch, vel, noSort
                                    local ret = reaper.MIDI_InsertNote(take, args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10] or false)
                                    reaper.MIDI_Sort(take)
                                    response.ok = ret
                                end
                            end
                        end

                    elseif fname == "GetMIDINotes" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local take = reaper.GetActiveTake(item)
                                if not take then
                                    response.ok = false
                                    response.error = "No active take"
                                else
                                    local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
                                    local notes = {__is_array = true}
                                    for i = 0, note_count - 1 do
                                        local retval, sel, muted, start_ppq, end_ppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
                                        table.insert(notes, {
                                            index = i,
                                            selected = sel,
                                            muted = muted,
                                            start_ppq = start_ppq,
                                            end_ppq = end_ppq,
                                            channel = chan,
                                            pitch = pitch,
                                            velocity = vel
                                        })
                                    end
                                    response.ok = true
                                    response.notes = notes
                                end
                            end
                        end

                    elseif fname == "MIDI_DeleteNote" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local take = reaper.GetActiveTake(item)
                                if not take then
                                    response.ok = false
                                    response.error = "No active take"
                                else
                                    local ret = reaper.MIDI_DeleteNote(take, args[3])
                                    reaper.MIDI_Sort(take)
                                    response.ok = ret
                                end
                            end
                        end

                    elseif fname == "ClearMIDIItem" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local item = reaper.GetTrackMediaItem(track, args[2])
                            if not item then
                                response.ok = false
                                response.error = "Item not found"
                            else
                                local take = reaper.GetActiveTake(item)
                                if not take then
                                    response.ok = false
                                    response.error = "No active take"
                                else
                                    local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
                                    for i = note_count - 1, 0, -1 do
                                        reaper.MIDI_DeleteNote(take, i)
                                    end
                                    reaper.MIDI_Sort(take)
                                    response.ok = true
                                    response.deleted = note_count
                                end
                            end
                        end

                    -- Envelope Operations
                    elseif fname == "CountEnvelopePoints" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local env = reaper.GetTrackEnvelopeByName(track, args[2])
                            if not env then
                                response.ok = false
                                response.error = "Envelope not found: " .. tostring(args[2])
                            else
                                response.ok = true
                                response.ret = reaper.CountEnvelopePoints(env)
                            end
                        end

                    elseif fname == "GetEnvelopePoints" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local env = reaper.GetTrackEnvelopeByName(track, args[2])
                            if not env then
                                response.ok = false
                                response.error = "Envelope not found: " .. tostring(args[2])
                            else
                                local count = reaper.CountEnvelopePoints(env)
                                local points = {__is_array = true}
                                for i = 0, count - 1 do
                                    local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
                                    table.insert(points, {
                                        index = i,
                                        time = time,
                                        value = value,
                                        shape = shape,
                                        tension = tension,
                                        selected = selected
                                    })
                                end
                                response.ok = true
                                response.points = points
                            end
                        end

                    elseif fname == "DeleteEnvelopePoint" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local env = reaper.GetTrackEnvelopeByName(track, args[2])
                            if not env then
                                response.ok = false
                                response.error = "Envelope not found: " .. tostring(args[2])
                            else
                                local point_idx = args[3]
                                local retval, pt_time = reaper.GetEnvelopePoint(env, point_idx)
                                if retval then
                                    reaper.DeleteEnvelopePointRange(env, pt_time - 0.0001, pt_time + 0.0001)
                                    response.ok = true
                                else
                                    response.ok = false
                                    response.error = "Point index out of range: " .. tostring(point_idx)
                                end
                            end
                        end

                    elseif fname == "ClearEnvelope" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local env = reaper.GetTrackEnvelopeByName(track, args[2])
                            if not env then
                                response.ok = false
                                response.error = "Envelope not found: " .. tostring(args[2])
                            else
                                local count = reaper.CountEnvelopePoints(env)
                                if count > 0 then
                                    local _, last_time = reaper.GetEnvelopePoint(env, count - 1)
                                    reaper.DeleteEnvelopePointRange(env, 0, last_time + 1)
                                end
                                response.ok = true
                            end
                        end

                    elseif fname == "SetEnvelopeArm" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local env = reaper.GetTrackEnvelopeByName(track, args[2])
                            if not env then
                                response.ok = false
                                response.error = "Envelope not found: " .. tostring(args[2])
                            else
                                local _, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
                                local arm_val = args[3] and "1" or "0"
                                chunk = chunk:gsub("ARM %d", "ARM " .. arm_val)
                                reaper.SetEnvelopeStateChunk(env, chunk, false)
                                response.ok = true
                            end
                        end

                    -- Track Peak
                    elseif fname == "Track_GetPeakInfo" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local peak = reaper.Track_GetPeakInfo(track, args[2] or 0)
                            local peak_db = -150
                            if peak > 0 then
                                peak_db = 20 * math.log(peak, 10)
                            end
                            response.ok = true
                            response.ret = peak
                            response.peak_db = peak_db
                        end

                    -- FX Presets
                    elseif fname == "TrackFX_GetPresetList" then
                        local track = get_track(args[1])
                        if not track then
                            response.ok = false
                            response.error = "Track not found"
                        else
                            local presets = {__is_array = true}
                            local retval, num_presets = reaper.TrackFX_GetPresetIndex(track, args[2])
                            for i = 0, num_presets - 1 do
                                reaper.TrackFX_SetPresetByIndex(track, args[2], i)
                                local _, preset_name = reaper.TrackFX_GetPreset(track, args[2], "")
                                table.insert(presets, preset_name)
                            end
                            -- Restore original preset
                            if retval >= 0 then
                                reaper.TrackFX_SetPresetByIndex(track, args[2], retval)
                            end
                            response.ok = true
                            response.presets = presets
                        end

                    elseif fname == "TrackFX_SavePreset" then
                        -- No direct API; save via preset mechanism
                        response.ok = false
                        response.error = "TrackFX_SavePreset is not supported via the bridge. Save presets manually in REAPER."

                    -- Render
                    elseif fname == "RenderProject" then
                        -- args: output_path, start_time (or nil), end_time (or nil), tail_seconds
                        local output_path = args[1]
                        local start_time = args[2]
                        local end_time = args[3]
                        local tail_seconds = args[4] or 0

                        if not output_path then
                            response.ok = false
                            response.error = "output_path is required"
                        else
                            -- Split output_path into directory and filename
                            local dir = output_path:match("(.+)[/\\]")
                            local filename = output_path:match("[/\\]([^/\\]+)$") or output_path

                            -- Set render output directory and filename pattern
                            reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir or "", true)
                            reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", filename, true)

                            -- Set render bounds
                            if start_time and end_time then
                                -- Custom time range (bounds flag 2 = custom time range)
                                reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 2, true)
                                reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", start_time, true)
                                reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", end_time, true)
                            else
                                -- Entire project (bounds flag 0)
                                reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)
                            end

                            -- Set tail length
                            if tail_seconds > 0 then
                                reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 1, true)
                                reaper.GetSetProjectInfo(0, "RENDER_TAILMS", tail_seconds * 1000, true)
                            else
                                reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
                            end

                            -- Render with auto-close dialog
                            reaper.Main_OnCommand(42230, 0)

                            response.ok = true
                            response.output_path = output_path
                            response.note = "Render triggered. Audio format uses the project's current render format settings. Check Reaper's render dialog (Cmd+Alt+R) to verify format if needed."
                        end

                    elseif fname == "RenderRegion" then
                        -- args: region_index, output_path
                        local region_index = args[1]
                        local output_path = args[2]

                        if not region_index or not output_path then
                            response.ok = false
                            response.error = "region_index and output_path are required"
                        else
                            -- Find the region by index
                            local num_markers, num_regions = reaper.CountProjectMarkers(0)
                            local region_start = nil
                            local region_end = nil
                            local region_name = nil

                            for i = 0, num_markers + num_regions - 1 do
                                local retval, isrgn, pos, rgnend, name, markrgnidx = reaper.EnumProjectMarkers(i)
                                if isrgn and markrgnidx == region_index then
                                    region_start = pos
                                    region_end = rgnend
                                    region_name = name
                                    break
                                end
                            end

                            if not region_start then
                                response.ok = false
                                response.error = "Region not found at index " .. tostring(region_index)
                            else
                                -- Split output_path into directory and filename
                                local dir = output_path:match("(.+)[/\\]")
                                local filename = output_path:match("[/\\]([^/\\]+)$") or output_path

                                -- Set render output
                                reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir or "", true)
                                reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", filename, true)

                                -- Set custom time range to region bounds
                                reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 2, true)
                                reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", region_start, true)
                                reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", region_end, true)
                                reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)

                                -- Render with auto-close
                                reaper.Main_OnCommand(42230, 0)

                                response.ok = true
                                response.output_path = output_path
                                response.region_name = region_name
                                response.region_start = region_start
                                response.region_end = region_end
                            end
                        end

                    else
                        -- Strict allowlist: no generic reaper[fname] fallback.
                        -- Every supported tool is handled by DSL_FUNCTIONS or an
                        -- explicit branch above; anything else is rejected so a
                        -- spoofed request file cannot reach arbitrary reaper.* APIs.
                        response.ok = false
                        response.error = "Unknown function: " .. fname
                    end
                    
                    -- Write response
                    local response_json = encode_json(response)
                    reaper.ShowConsoleMsg("Sending response " .. req_id .. ": " .. response_json .. "\n")
                    write_file(numbered_response_file, response_json)
                end
            end
            end)
            
            if not ok then
                -- Error occurred, write error response
                reaper.ShowConsoleMsg("ERROR processing request " .. req_id .. ": " .. tostring(err) .. "\n")
                local error_response = {ok = false, error = "Bridge error: " .. tostring(err)}
                write_file(numbered_response_file, encode_json(error_response))
            end
            
            -- Always clean up request file
            delete_file(numbered_request_file)
        end
    end
end

-- Main loop
ensure_dir()
reaper.ShowConsoleMsg("REAPER MCP Bridge (File-based, Full API) started\n")
reaper.ShowConsoleMsg("Bridge directory: " .. bridge_dir .. "\n")

function main()
    process_request()
    reaper.defer(main)
end

main()