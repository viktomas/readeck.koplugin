local Dates = require("readeck.core.dates")

local Highlights = {}

local READECK_HIGHLIGHT_COLORS = {
    blue = "blue",
    cyan = "blue",
    gray = "yellow",
    green = "green",
    none = "none",
    olive = "green",
    orange = "yellow",
    purple = "blue",
    red = "red",
    yellow = "yellow",
}

local KOREADER_HIGHLIGHT_COLORS = {
    blue = "blue",
    green = "green",
    none = "none",
    red = "red",
    yellow = "yellow",
}

local MAX_NOTE_LENGTH = 1024

local UNSAFE_BOUNDARY_ELEMENTS = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
}

local function split_path(selector)
    local parts = {}
    for part in tostring(selector or ""):gmatch("[^/]+") do
        table.insert(parts, part)
    end
    return parts
end

function Highlights.selector_last_element(selector)
    local last
    for _, part in ipairs(split_path(selector)) do
        last = part
    end
    if not last then
        return nil
    end
    return tostring(last):match("^([^%[]+)"):lower()
end

function Highlights.is_safe_boundary_selector(selector)
    local element = Highlights.selector_last_element(selector)
    return element ~= nil and not UNSAFE_BOUNDARY_ELEMENTS[element]
end

function Highlights.selector_parent(selector)
    return tostring(selector or ""):match("^(.*)/[^/]+$") or ""
end

function Highlights.text_length(text)
    text = tostring(text or "")
    local count = 0
    for i = 1, #text do
        local byte = text:byte(i)
        if byte < 128 or byte >= 192 then
            count = count + 1
        end
    end
    return count
end

-- KOReader xpointers into a Readeck EPUB are absolute: the article HTML that
-- Readeck resolves selectors against sits inside <main> of the EPUB page.
-- Current crengine writes every step with an explicit index
-- (/body[1]/DocFragment[1]/body[1]/main[1]/section[1]/...); older builds wrote
-- the bare form (/body/DocFragment/body/main/section/...). Both must reduce to
-- the article-relative path, or Readeck answers 'element "/body[1]/..." not
-- found' for every highlight - found by the e2e suite with a real KOReader.
local KOREADER_PREFIX = "^/body%[?%d*%]?/DocFragment%[?%d*%]?/body%[?%d*%]?/main%[?%d*%]?/"

function Highlights.clean_selector(selector)
    if not selector then
        return ""
    end
    return (
        tostring(selector)
            :gsub(KOREADER_PREFIX, "")
            :gsub("/body/DocFragment/body/main/", "")
            :gsub("/text%(%)%[%d+%]$", "")
            :gsub("/text%(%)$", "")
    )
end

function Highlights.is_later_text_node(selector)
    local index = tostring(selector or ""):match("/text%(%)%[(%d+)%]$")
    return index ~= nil and tonumber(index) > 1
end

function Highlights.normalize_selector(selector)
    if not selector then
        return ""
    end

    local parts = {}
    for _, part in ipairs(split_path(selector)) do
        if not part:find("%[") then
            part = part .. "[1]"
        end
        table.insert(parts, part)
    end

    return table.concat(parts, "/"):gsub("%[(%d+)%]", function(d)
        return string.format("[%05d]", tonumber(d))
    end)
end

function Highlights.compare_points(s1, o1, s2, o2)
    local norm_s1 = Highlights.normalize_selector(s1)
    local norm_s2 = Highlights.normalize_selector(s2)

    if norm_s1 < norm_s2 then
        return -1
    end
    if norm_s1 > norm_s2 then
        return 1
    end

    o1 = tonumber(o1) or 0
    o2 = tonumber(o2) or 0
    if o1 < o2 then
        return -1
    end
    if o1 > o2 then
        return 1
    end
    return 0
end

-- Both annotations as [start, end) ranges of the article's Readeck text, when
-- the EPUB's PositionMap can resolve them: exact, whatever element each
-- selector names (p[2] vs p[2]/em[1]).
local function mapped_range(h, position_map)
    local g0 = position_map:readeck_to_global(h.start_selector, h.start_offset)
    local g1 = position_map:readeck_to_global(h.end_selector, h.end_offset)
    if not (g0 and g1) then
        return nil
    end
    if g0 > g1 then
        g0, g1 = g1, g0
    end
    return g0, g1
end

function Highlights.overlap(h1, h2, position_map)
    if not (h1 and h1.start_selector and h1.end_selector and h1.start_offset and h1.end_offset) then
        return false
    end
    if not (h2 and h2.start_selector and h2.end_selector and h2.start_offset and h2.end_offset) then
        return false
    end
    if position_map then
        local a0, a1 = mapped_range(h1, position_map)
        local b0, b1 = mapped_range(h2, position_map)
        if a0 and b0 then
            return a0 < b1 and b0 < a1
        end
    end

    local h2_start_s, h2_start_o, h2_end_s, h2_end_o
    local clean_s1 = Highlights.clean_selector(h2.start_selector)
    local clean_s2 = Highlights.clean_selector(h2.end_selector)
    if Highlights.compare_points(clean_s1, h2.start_offset, clean_s2, h2.end_offset) <= 0 then
        h2_start_s, h2_start_o, h2_end_s, h2_end_o = clean_s1, h2.start_offset, clean_s2, h2.end_offset
    else
        h2_start_s, h2_start_o, h2_end_s, h2_end_o = clean_s2, h2.end_offset, clean_s1, h2.start_offset
    end

    local start1_before_end2 = Highlights.compare_points(h1.start_selector, h1.start_offset, h2_end_s, h2_end_o) < 0
    local start2_before_end1 = Highlights.compare_points(h2_start_s, h2_start_o, h1.end_selector, h1.end_offset) < 0

    return start1_before_end2 and start2_before_end1
end

function Highlights.local_matches_remote_id(local_highlight, remote_highlight)
    return remote_highlight
        and remote_highlight.id
        and local_highlight
        and tostring(local_highlight.readeck_annotation_id or "") == tostring(remote_highlight.id)
end

function Highlights.normalize_note(note)
    note = type(note) == "string" and note or ""
    if #note > MAX_NOTE_LENGTH then
        note = note:sub(1, MAX_NOTE_LENGTH)
    end
    return note
end

function Highlights.local_note(local_highlight, profile)
    if not (profile and profile.notes) then
        return nil
    end
    return Highlights.normalize_note(local_highlight and local_highlight.note)
end

function Highlights.remote_note(remote_highlight, profile)
    if not (profile and profile.notes) then
        return nil
    end
    return Highlights.normalize_note(remote_highlight and remote_highlight.note)
end

function Highlights.local_color(local_highlight, profile)
    local color = READECK_HIGHLIGHT_COLORS[tostring(local_highlight and local_highlight.color or ""):lower()]
        or "yellow"
    if color == "none" and not (profile and profile.none_color) then
        return "yellow"
    end
    return color
end

function Highlights.remote_color(remote_highlight, profile)
    local color = READECK_HIGHLIGHT_COLORS[tostring(remote_highlight and remote_highlight.color or ""):lower()]
        or "yellow"
    if color == "none" and not (profile and profile.none_color) then
        return "yellow"
    end
    return color
end

function Highlights.remote_color_to_local(color)
    return KOREADER_HIGHLIGHT_COLORS[tostring(color or ""):lower()] or "yellow"
end

function Highlights.apply_sync_snapshot(local_highlight, source, profile)
    if type(local_highlight) ~= "table" or type(source) ~= "table" then
        return
    end
    if profile and profile.notes then
        local_highlight.readeck_synced_note = Highlights.remote_note(source, profile) or ""
    else
        local_highlight.readeck_synced_note = nil
    end
    local_highlight.readeck_synced_color = Highlights.remote_color(source, profile)
    local_highlight.readeck_synced_at = os.date("%Y-%m-%d %H:%M:%S")
end

function Highlights.merge_notes(local_note, remote_note)
    local_note = Highlights.normalize_note(local_note)
    remote_note = Highlights.normalize_note(remote_note)
    if local_note == remote_note then
        return local_note
    end
    if local_note == "" then
        return remote_note
    end
    if remote_note == "" then
        return local_note
    end
    return Highlights.normalize_note("KOReader note:\n" .. local_note .. "\n\nReadeck note:\n" .. remote_note)
end

function Highlights.set_local_note(local_highlight, note)
    note = Highlights.normalize_note(note)
    local current = Highlights.normalize_note(local_highlight.note)
    if current == note then
        return false
    end
    local_highlight.note = note ~= "" and note or nil
    return true
end

function Highlights.set_local_color(local_highlight, remote_color)
    local local_color = Highlights.remote_color_to_local(remote_color)
    local current = local_highlight.color or "yellow"
    if current == local_color then
        return false
    end
    local_highlight.color = local_color
    return true
end

function Highlights.plan_linked_sync(local_highlight, remote_highlight, profile, policy)
    profile = profile or {}
    policy = policy or "merge"

    local local_note = Highlights.local_note(local_highlight, profile)
    local remote_note = Highlights.remote_note(remote_highlight, profile)
    local final_note = local_note
    local note_conflict = false

    if profile.notes then
        if policy == "remote_wins" then
            final_note = remote_note
        elseif policy == "local_wins" then
            final_note = local_note
        else
            local base_note = type(local_highlight.readeck_synced_note) == "string"
                    and Highlights.normalize_note(local_highlight.readeck_synced_note)
                or nil
            if base_note then
                local local_changed = local_note ~= base_note
                local remote_changed = remote_note ~= base_note
                if local_changed and remote_changed and local_note ~= remote_note then
                    final_note = Highlights.merge_notes(local_note, remote_note)
                    note_conflict = true
                elseif remote_changed then
                    final_note = remote_note
                else
                    final_note = local_note
                end
            elseif local_note == remote_note then
                final_note = local_note
            elseif local_note == "" or remote_note == "" then
                final_note = local_note ~= "" and local_note or remote_note
            else
                final_note = Highlights.merge_notes(local_note, remote_note)
                note_conflict = true
            end
        end
    end

    local local_color = Highlights.local_color(local_highlight, profile)
    local remote_color = Highlights.remote_color(remote_highlight, profile)
    local final_color = local_color
    local color_conflict = false

    if policy == "remote_wins" then
        final_color = remote_color
    elseif policy == "local_wins" then
        final_color = local_color
    else
        local base_color = type(local_highlight.readeck_synced_color) == "string"
                and Highlights.remote_color({ color = local_highlight.readeck_synced_color }, profile)
            or nil
        if base_color then
            local local_changed = local_color ~= base_color
            local remote_changed = remote_color ~= base_color
            if local_changed and remote_changed and local_color ~= remote_color then
                final_color = local_color
                color_conflict = true
            elseif remote_changed then
                final_color = remote_color
            else
                final_color = local_color
            end
        elseif local_color ~= remote_color then
            final_color = local_color
            color_conflict = true
        end
    end

    local local_update = {}
    if profile.notes and final_note ~= local_note then
        local_update.note = final_note
    end
    if final_color ~= local_color then
        local_update.color = final_color
    end

    local remote_update
    if (profile.notes and final_note ~= remote_note) or final_color ~= remote_color then
        remote_update = {
            color = final_color,
        }
        if profile.notes then
            remote_update.note = final_note
        end
    end

    return {
        local_update = next(local_update) ~= nil and local_update or nil,
        remote_update = remote_update,
        snapshot = {
            note = final_note,
            color = final_color,
        },
        conflict = note_conflict or color_conflict,
    }
end

-- Readeck's `created` is UTC ("2026-05-06T17:47:45.123Z"); KOReader's
-- `datetime` is local wall-clock time, as os.date writes it.
function Highlights.local_datetime(value)
    local timestamp = Dates.parse(value)
    if not timestamp then
        return nil
    end
    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

local function collapse_whitespace(text)
    return (tostring(text or ""):gsub("[ \t\r\n]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Readeck (selectors, offsets) -> crengine xpointers of the downloaded EPUB,
-- through its PositionMap. Returns pos0, pos1, text or nil and a reason.
function Highlights.remote_positions(remote_highlight, position_map)
    if not position_map then
        return nil, "no_position_map"
    end
    local start_offset = tonumber(remote_highlight.start_offset)
    local end_offset = tonumber(remote_highlight.end_offset)
    if type(remote_highlight.start_selector) ~= "string" or type(remote_highlight.end_selector) ~= "string" then
        return nil, "invalid_position"
    end
    if start_offset == nil or end_offset == nil then
        return nil, "invalid_position"
    end
    local g0 = position_map:readeck_to_global(remote_highlight.start_selector, start_offset)
    local g1 = position_map:readeck_to_global(remote_highlight.end_selector, end_offset)
    if not (g0 and g1) then
        return nil, "unresolved_position"
    end
    local start_selector, end_selector = remote_highlight.start_selector, remote_highlight.end_selector
    if g0 > g1 then
        start_selector, end_selector = end_selector, start_selector
        start_offset, end_offset = end_offset, start_offset
        g0, g1 = g1, g0
    end
    local pos0 = position_map:to_xpointer(start_selector, start_offset, false)
    local pos1 = position_map:to_xpointer(end_selector, end_offset, true)
    if not (pos0 and pos1) or g0 == g1 then
        return nil, "unresolved_position"
    end
    return pos0, pos1, collapse_whitespace(position_map:readeck_text(g0, g1))
end

function Highlights.remote_to_local_annotation(remote_highlight, profile, position_map)
    if type(remote_highlight) ~= "table" then
        return nil, "invalid_annotation"
    end

    local pos0, pos1, text = Highlights.remote_positions(remote_highlight, position_map)
    if not pos0 then
        return nil, pos1
    end
    if text == "" and type(remote_highlight.text) == "string" then
        text = collapse_whitespace(remote_highlight.text)
    end

    local note = type(remote_highlight.note) == "string" and remote_highlight.note or nil
    if note == "" then
        note = nil
    end

    local local_annotation = {
        page = pos0,
        pos0 = pos0,
        pos1 = pos1,
        text = text,
        chapter = position_map.title,
        datetime = Highlights.local_datetime(remote_highlight.created or remote_highlight.updated),
        drawer = "lighten",
        color = Highlights.remote_color_to_local(remote_highlight.color),
        note = note,
        readeck_annotation_id = remote_highlight.id,
    }
    if profile then
        Highlights.apply_sync_snapshot(local_annotation, remote_highlight, profile)
    end
    return local_annotation
end

local function finish_payload(h, profile, start_selector, start_offset, end_selector, end_offset)
    local payload = {
        text = h.text,
        color = Highlights.local_color(h, profile),
        start_selector = start_selector,
        start_offset = start_offset,
        end_selector = end_selector,
        end_offset = end_offset,
    }
    if profile.notes then
        payload.note = Highlights.normalize_note(h.note)
    end
    return payload
end

-- KOReader xpointers -> Readeck selectors and offsets, through the EPUB's
-- PositionMap: text-node offsets become element offsets, crengine's collapsed
-- whitespace becomes raw characters, Readeck's own <mark>/noteref markup in
-- the EPUB is accounted for.
local function build_mapped_payload(h, profile, position_map)
    local g0 = position_map:xpointer_to_global(h.pos0, false)
    local g1 = position_map:xpointer_to_global(h.pos1, true)
    if not (g0 and g1) then
        return nil, "unsupported_selector"
    end
    local pos0, pos1 = h.pos0, h.pos1
    if g0 > g1 then
        pos0, pos1 = pos1, pos0
    end
    local start_selector, start_offset = position_map:to_readeck(pos0, false)
    local end_selector, end_offset = position_map:to_readeck(pos1, true)
    if not (start_selector and end_selector) then
        return nil, "unsupported_selector"
    end
    local s = position_map:readeck_to_global(start_selector, start_offset)
    local e = position_map:readeck_to_global(end_selector, end_offset)
    if not (s and e) or s >= e then
        return nil, "unsupported_selector"
    end
    return finish_payload(h, profile, start_selector, start_offset, end_selector, end_offset)
end

function Highlights.build_payload(h, profile, position_map)
    profile = profile or {}
    if type(h) ~= "table" or not h.drawer or type(h.pos0) ~= "string" or type(h.pos1) ~= "string" then
        return nil, "invalid_annotation"
    end
    if position_map then
        return build_mapped_payload(h, profile, position_map)
    end

    -- Fallback when the EPUB cannot be read (no PositionMap): a textual
    -- rewrite that is only right for the first text node of an element
    -- without collapsed whitespace or Readeck markup in the EPUB.
    local start_selector, start_offset = h.pos0:match("(.*)%.(%d+)")
    local end_selector, end_offset = h.pos1:match("(.*)%.(%d+)")
    if not (start_selector and start_offset and end_selector and end_offset) then
        return nil, "invalid_position"
    end

    -- KOReader offsets count from the start of one *text node*; Readeck's
    -- count from the start of the *element*. They only agree for the first
    -- text node. For text()[2] and later (text after an <em>, <a>, ...) the
    -- offset would silently point at other words on the server, so refuse to
    -- export rather than store a wrong highlight (found by the e2e suite).
    if Highlights.is_later_text_node(start_selector) or Highlights.is_later_text_node(end_selector) then
        return nil, "unsupported_selector"
    end

    local s_offset = tonumber(start_offset)
    local e_offset = tonumber(end_offset)
    start_selector = Highlights.clean_selector(start_selector)
    end_selector = Highlights.clean_selector(end_selector)

    if start_selector == "" or end_selector == "" then
        return nil, "unsupported_selector"
    end

    if Highlights.compare_points(start_selector, s_offset, end_selector, e_offset) > 0 then
        start_selector, end_selector = end_selector, start_selector
        s_offset, e_offset = e_offset, s_offset
    end

    local text_length = Highlights.text_length(h.text)
    local same_parent = Highlights.selector_parent(start_selector) == Highlights.selector_parent(end_selector)
    if not Highlights.is_safe_boundary_selector(start_selector) then
        if same_parent and Highlights.is_safe_boundary_selector(end_selector) then
            start_selector = end_selector
            s_offset = math.max(0, e_offset - text_length)
        else
            return nil, "unsupported_selector"
        end
    end
    if not Highlights.is_safe_boundary_selector(end_selector) then
        if same_parent and Highlights.is_safe_boundary_selector(start_selector) then
            end_selector = start_selector
            e_offset = s_offset + text_length
        else
            return nil, "unsupported_selector"
        end
    end

    return finish_payload(h, profile, start_selector, s_offset, end_selector, e_offset)
end

function Highlights.build_update_payload(h, profile, values)
    profile = profile or {}
    values = values or {}
    local color = values.color or Highlights.local_color(h, profile)
    if color == "none" and not profile.none_color then
        color = "yellow"
    end

    local payload = {
        color = color,
    }
    if profile.notes then
        payload.note = Highlights.normalize_note(values.note ~= nil and values.note or h.note)
    end
    return payload
end

return Highlights
