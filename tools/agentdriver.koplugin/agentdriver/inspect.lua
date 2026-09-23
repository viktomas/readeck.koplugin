-- Widget introspection: records where every widget was last painted (by
-- wrapping paintTo on every widget class) and walks the window stack to
-- produce a flat list of visible elements with text and screen rectangles.
local Device = require("device")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")

local Inspect = {}

local wrapped = setmetatable({}, { __mode = "k" })
local rects = setmetatable({}, { __mode = "k" })
local class_names = setmetatable({}, { __mode = "k" })
local newly_wrapped = 0

local function screen_bb()
    return Device.screen and Device.screen.bb
end

local function record(self, bb, x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return
    end
    local w, h
    local ok, size = pcall(self.getSize, self)
    if ok and type(size) == "table" and size.w then
        w, h = size.w, size.h
    elseif type(self.dimen) == "table" then
        w, h = self.dimen.w, self.dimen.h
    end
    rects[self] = { x = x, y = y, w = w or 0, h = h or 0, off = bb ~= screen_bb() }
end

local function wrap_class(c)
    if type(c) ~= "table" or wrapped[c] then
        return
    end
    local f = rawget(c, "paintTo")
    if type(f) ~= "function" then
        return
    end
    wrapped[c] = true
    newly_wrapped = newly_wrapped + 1
    local wrapper = function(self, bb, x, y, ...)
        local r1, r2 = f(self, bb, x, y, ...)
        record(self, bb, x, y)
        return r1, r2
    end
    wrapped[wrapper] = true
    rawset(c, "paintTo", wrapper)
end

local function wrap_chain(c)
    local n = 0
    while type(c) == "table" and n < 40 do
        wrap_class(c)
        c = getmetatable(c)
        n = n + 1
    end
end

function Inspect.scan_loaded()
    for name, mod in pairs(package.loaded) do
        -- rawget only: some loaded "modules" proxy ffi namespaces and throw on unknown keys.
        if type(mod) == "table" and type(name) == "string" and rawget(mod, "paintTo") ~= nil then
            wrap_chain(mod)
        end
        if
            type(mod) == "table"
            and type(name) == "string"
            and (rawget(mod, "paintTo") or rawget(mod, "init") or rawget(mod, "extend"))
        then
            if not class_names[mod] then
                class_names[mod] = name:match("([^/]+)$")
            end
        end
    end
end

function Inspect.install()
    if Inspect.installed then
        return
    end
    Inspect.installed = true
    Inspect.scan_loaded()
    -- Catch classes that are local to a module (MenuItem, TouchMenuItem, ...)
    -- the first time one of their instances is created.
    local orig_new = Widget.new
    Widget.new = function(cls, o)
        wrap_chain(cls)
        local inst = orig_new(cls, o)
        if type(inst) == "table" and rawget(inst, "paintTo") then
            wrap_class(inst)
        end
        return inst
    end
end

function Inspect.take_new_wraps()
    local n = newly_wrapped
    newly_wrapped = 0
    return n
end

-- Class name of a local class: read the source line where one of its methods
-- is defined, e.g. "function MenuItem:init()" -> "MenuItem".
local source_cache = {}
local function name_from_source(c)
    for _, key in ipairs({ "init", "paintTo", "onTapSelect", "update", "getSize" }) do
        local f = rawget(c, key)
        if type(f) == "function" and not wrapped[f] then
            local info = debug.getinfo(f, "S")
            if info and info.source and info.source:sub(1, 1) == "@" and info.linedefined > 0 then
                local file = info.source:sub(2)
                local lines = source_cache[file]
                if lines == nil then
                    lines = false
                    local fh = io.open(file, "r")
                    if fh then
                        lines = {}
                        for l in fh:lines() do
                            lines[#lines + 1] = l
                        end
                        fh:close()
                    end
                    source_cache[file] = lines
                end
                if lines then
                    local l = lines[info.linedefined] or ""
                    local n = l:match("function%s+([%w_]+)[:%.]")
                    if n then
                        return n
                    end
                end
            end
        end
    end
end

function Inspect.class_name(w)
    local c = getmetatable(w)
    local n = 0
    while type(c) == "table" and n < 40 do
        local name = class_names[c]
        if name == nil then
            name = name_from_source(c) or false
            class_names[c] = name
        end
        if name then
            return name
        end
        c = getmetatable(c)
        n = n + 1
    end
    return "?"
end

-- Drop bidi control characters (KOReader wraps paths and titles in isolates).
local function clean(s)
    return (s:gsub("\226\129[\166-\169]", ""):gsub("\226\128[\142\143\170-\174]", ""))
end
Inspect.clean = clean

local function text_of(w)
    local cls_text
    if type(w.getText) == "function" and type(w.charlist) == "table" then
        local ok, t = pcall(w.getText, w)
        if ok and type(t) == "string" then
            if w.text_type == "password" and not w.text_visible then
                t = string.rep("*", #t)
            end
            return t, "input"
        end
    end
    if type(w.text) == "string" then
        cls_text = w.text
    elseif type(w.title) == "string" and rawget(w, "title") then
        cls_text = w.title
    end
    return cls_text and clean(cls_text)
end

local function is_tappable(w)
    if type(w.ges_events) == "table" then
        for name in pairs(w.ges_events) do
            if name:find("Tap") or name:find("Hold") then
                return true
            end
        end
    end
    return false
end

local function window_name(win)
    local w = win.widget
    return Inspect.class_name(w), w.name or w.id or (type(w.title) == "string" and w.title) or nil
end

-- Force a repaint of every window so every visible widget has a fresh rect.
function Inspect.repaint_all()
    for _, win in ipairs(UIManager._window_stack) do
        UIManager:setDirty(win.widget, "ui")
    end
    UIManager:forceRePaint()
end

local function trunc(s, n)
    if #s > n then
        return s:sub(1, n) .. "…"
    end
    return s
end

--- Walk the window stack. Returns { windows = {...}, elements = {...} }.
-- Each element: id, win, cls, text, icon, rect {x,y,w,h}, depth, parent,
-- tap (has tap/hold handlers), enabled, checked, focused, input.
-- opts.all: also include windows hidden under a fullscreen one.
function Inspect.walk(opts)
    opts = opts or {}
    local stack = UIManager._window_stack
    local top_full = 1
    for i = #stack, 1, -1 do
        if stack[i].widget.covers_fullscreen then
            top_full = i
            break
        end
    end
    local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
    local windows, elements = {}, {}
    local visited = {}
    for wi, win in ipairs(stack) do
        local cls, name = window_name(win)
        local hidden = wi < top_full
        local wr = rects[win.widget]
        windows[#windows + 1] = {
            index = wi,
            cls = cls,
            name = name,
            hidden = hidden,
            fullscreen = win.widget.covers_fullscreen or nil,
            toast = win.widget.toast or nil,
            rect = wr and { wr.x, wr.y, wr.w, wr.h } or nil,
        }
        if not hidden or opts.all then
            local function visit(w, depth, parent_el)
                if type(w) ~= "table" or visited[w] or depth > 60 then
                    return
                end
                visited[w] = true
                local r = rects[w]
                local el
                if
                    r
                    and not r.off
                    and r.w > 0
                    and r.h > 0
                    and r.x < sw
                    and r.y < sh
                    and r.x + r.w > 0
                    and r.y + r.h > 0
                then
                    local text, kind = text_of(w)
                    local icon = type(w.icon) == "string" and w.icon or nil
                    local tap = is_tappable(w)
                    local checked
                    if type(w.checked) == "boolean" then
                        checked = w.checked
                    end
                    if text or icon or tap or kind == "input" then
                        -- Collapse a label into its button/menu item: same text, inside it.
                        local dup = false
                        if text and not icon then
                            local p = parent_el
                            while p do
                                if p.text == text then
                                    dup = true
                                    break
                                end
                                p = p.parent and elements[p.parent]
                            end
                        end
                        if not dup then
                            el = {
                                id = #elements + 1,
                                win = wi,
                                cls = Inspect.class_name(w),
                                text = text,
                                icon = icon,
                                rect = { r.x, r.y, r.w, r.h },
                                depth = parent_el and (parent_el.depth + 1) or 0,
                                parent = parent_el and parent_el.id or nil,
                                tap = tap or nil,
                                enabled = (w.enabled == false) and false or nil,
                                checked = checked,
                                input = (kind == "input") or nil,
                                focused = (kind == "input" and w.focused) or nil,
                                _w = w,
                            }
                            elements[#elements + 1] = el
                        end
                    end
                end
                for _, child in ipairs(w) do
                    visit(child, depth + 1, el or parent_el)
                end
            end
            visit(win.widget, 0, nil)
        end
    end
    return { windows = windows, elements = elements, screen = { w = sw, h = sh } }
end

function Inspect.public_elements(elements, full_text)
    local out = {}
    for _, el in ipairs(elements) do
        local copy = {}
        for k, v in pairs(el) do
            if k ~= "_w" then
                copy[k] = v
            end
        end
        if copy.text and not full_text then
            copy.text = trunc(copy.text, 300)
        end
        out[#out + 1] = copy
    end
    return out
end

local function norm(s)
    s = s:gsub("\194\173", "") -- soft hyphen
    s = s:gsub("%s+", " ")
    return s:lower()
end

--- Find elements whose text matches. Topmost window first, then reading
-- order. Ancestors of other matches are dropped so a label and its button
-- count once. opts: exact, win, pattern (Lua pattern), icon.
function Inspect.find(walk, query, opts)
    opts = opts or {}
    local q = norm(query)
    local matches = {}
    for _, el in ipairs(walk.elements) do
        local hay = opts.icon and el.icon or el.text
        if hay and (not opts.win or el.win == tonumber(opts.win)) then
            local h = norm(hay)
            local hit
            if opts.pattern then
                hit = h:find(query) ~= nil
            elseif opts.exact then
                hit = h == q or h:gsub("^%s+", ""):gsub("%s+$", "") == q
            else
                hit = h:find(q, 1, true) ~= nil
            end
            if hit then
                matches[#matches + 1] = el
            end
        end
    end
    local is_match = {}
    for _, el in ipairs(matches) do
        is_match[el.id] = el
    end
    local byid = {}
    for _, el in ipairs(walk.elements) do
        byid[el.id] = el
    end
    local drop = {}
    for _, el in ipairs(matches) do
        local p = el.parent
        while p do
            if is_match[p] then
                drop[p] = true
            end
            p = byid[p] and byid[p].parent
        end
    end
    local out = {}
    for _, el in ipairs(matches) do
        if not drop[el.id] then
            out[#out + 1] = el
        end
    end
    table.sort(out, function(a, b)
        if a.win ~= b.win then
            return a.win > b.win
        end
        return a.id < b.id
    end)
    return out
end

function Inspect.center(el)
    local r = el.rect
    return math.floor(r[1] + r[3] / 2), math.floor(r[2] + r[4] / 2)
end

return Inspect
