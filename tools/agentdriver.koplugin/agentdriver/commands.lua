-- Command implementations for the agent driver.
--
-- Every command is `function(params, done)`; it performs its action and calls
-- done(result_table) or done(nil, "error message"). The dispatcher then waits
-- for the UI to settle, optionally takes a screenshot, and answers in JSON.
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Key = require("device/key")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Inspect = require("agentdriver/inspect")
local Json = require("agentdriver/json")

local Screen = Device.screen

local C = {}
local Driver = { ui = nil, last_walk = nil, shot_seq = 0 }
C.Driver = Driver

local function num(v, name)
    local n = tonumber(v)
    if not n then
        error("missing/invalid numeric parameter '" .. name .. "'", 0)
    end
    return math.floor(n + 0.5)
end

local function truthy(v)
    return v ~= nil and v ~= false and v ~= "" and v ~= "0" and v ~= "false" and v ~= "no"
end
C.truthy = truthy

local function point(x, y)
    return Geom:new({ x = x, y = y, w = 0, h = 0 })
end

local function send_ges(ges)
    ges.time = time.now()
    logger.dbg("agentdriver: gesture", ges.ges, ges.pos and ges.pos.x, ges.pos and ges.pos.y)
    UIManager.event_hook:execute("InputEvent")
    UIManager:sendEvent(Event:new("Gesture", ges))
end

-- Run { {delay_s, fn}, ... } one after the other through the UIManager loop.
local function run_steps(steps, done)
    local i = 0
    local function step()
        i = i + 1
        local s = steps[i]
        if not s then
            return done()
        end
        UIManager:scheduleIn(s[1], function()
            local ok, err = pcall(s[2])
            if not ok then
                return done(err)
            end
            step()
        end)
    end
    step()
end

-- Touch zones rate-limit (hold_)pan gestures (GestureRange.rate): 30/s, or
-- 5/s when Screen.low_pan_rate is set (the emulator sets it). Events closer
-- together are silently dropped - including, fatally, the last one.
local function pan_interval()
    local rate = G_reader_settings:readSetting("hold_pan_rate") or (Screen.low_pan_rate and 5.0 or 30.0)
    return 1 / rate + 0.03
end

local function direction_of(dx, dy)
    local ax, ay = math.abs(dx), math.abs(dy)
    local ns = dy < 0 and "north" or "south"
    local ew = dx < 0 and "west" or "east"
    if ax > 2 * ay then
        return ew
    elseif ay > 2 * ax then
        return ns
    end
    return ns .. ew
end

-- ---------------------------------------------------------------- settle

local function busy_reason(horizon_s)
    if next(UIManager._dirty) then
        return "dirty widgets"
    end
    if UIManager._refresh_stack and UIManager._refresh_stack[1] then
        return "pending refresh"
    end
    local now = time.now()
    local horizon = time.s(horizon_s)
    for _, task in ipairs(UIManager._task_queue) do
        if task.time - now < horizon then
            local info = debug.getinfo(task.action, "S")
            return "task " .. (info and (info.short_src .. ":" .. info.linedefined) or "?")
        end
    end
    return nil
end

local function stack_signature()
    local parts = {}
    for _, win in ipairs(UIManager._window_stack) do
        parts[#parts + 1] = tostring(win.widget)
    end
    return table.concat(parts, ",")
end

--- Wait until nothing is dirty and no task is due within `horizon` seconds,
-- for `stable` consecutive polls with an unchanged window stack.
function C.settle(opts, cb)
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or 15
    local horizon = tonumber(opts.horizon) or 0.4
    local stable_needed = tonumber(opts.stable) or 3
    local interval = 0.05
    local start = time.now()
    local stable, sig, last_busy = 0, nil, nil
    local function poll()
        local reason = busy_reason(horizon)
        local s = stack_signature()
        if reason or s ~= sig then
            stable = 0
            last_busy = reason or last_busy
        else
            stable = stable + 1
        end
        sig = s
        local waited = time.to_ms(time.since(start))
        if stable >= stable_needed then
            return cb({ idle = true, waited_ms = waited })
        end
        if waited >= timeout * 1000 then
            return cb({ idle = false, waited_ms = waited, busy = reason or last_busy })
        end
        UIManager:scheduleIn(interval, poll)
    end
    UIManager:scheduleIn(interval, poll)
end

-- ---------------------------------------------------------------- helpers

function C.current_ui()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI.instance then
        return ReaderUI.instance, "reader"
    end
    local ok2, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok2 and FileManager.instance then
        return FileManager.instance, "filemanager"
    end
    return Driver.ui, "unknown"
end

function C.walk(params)
    Inspect.scan_loaded()
    if not truthy(params and params.norepaint) then
        Inspect.take_new_wraps()
        Inspect.repaint_all()
        -- Classes seen for the first time during that paint have no rects yet.
        if Inspect.take_new_wraps() > 0 then
            Inspect.repaint_all()
        end
    end
    local w = Inspect.walk({ all = truthy(params and params.all) })
    Driver.last_walk = w
    return w
end

function C.top_summary()
    local stack = UIManager._window_stack
    local top = stack[#stack]
    if not top then
        return nil
    end
    local cls = Inspect.class_name(top.widget)
    return { cls = cls, name = top.widget.name or top.widget.id, windows = #stack }
end

-- Texts in the non-hidden windows above the bottom fullscreen one: a cheap
-- "what dialog is showing" summary attached to every answer.
function C.dialog_texts(walk)
    local texts = {}
    local first_dialog
    for i = #walk.windows, 1, -1 do
        local win = walk.windows[i]
        if win.fullscreen then
            break
        end
        first_dialog = i
    end
    if not first_dialog then
        return nil
    end
    -- Topmost window first, so the newest dialog leads the list.
    for wi = #walk.windows, first_dialog, -1 do
        for _, el in ipairs(walk.elements) do
            if el.win == wi and el.text and el.text ~= "" then
                local t = el.text
                if #t > 200 then
                    t = t:sub(1, 200) .. "…"
                end
                texts[#texts + 1] = t
            end
        end
    end
    return Json.array(texts)
end

function C.screenshot(path)
    if not path or path == "" then
        Driver.shot_seq = Driver.shot_seq + 1
        local dir = os.getenv("AGENTDRIVER_SHOT_DIR") or "/tmp"
        path = string.format("%s/shot-%03d.png", dir, Driver.shot_seq)
    end
    UIManager:forceRePaint()
    Screen:shot(path)
    return path
end

local function tap_at(x, y, done)
    send_ges({ ges = "touch", pos = point(x, y) })
    send_ges({ ges = "tap", pos = point(x, y) })
    done({ x = x, y = y })
end

local function find_one(params)
    local walk = C.walk(params)
    local query = params.text or params.icon
    if not query or query == "" then
        error("missing 'text'", 0)
    end
    local matches = Inspect.find(walk, query, {
        exact = truthy(params.exact),
        pattern = truthy(params.pattern),
        win = params.win,
        icon = params.icon ~= nil and params.text == nil,
    })
    local index = tonumber(params.index) or 1
    local el = matches[index]
    if not el then
        local visible = {}
        for _, e in ipairs(walk.elements) do
            if e.text and e.text ~= "" then
                visible[#visible + 1] = e.text:sub(1, 60)
            end
        end
        error(
            string.format(
                "no visible element matching %q (index %d, %d match(es)). Visible texts: %s",
                query,
                index,
                #matches,
                table.concat(visible, " | "):sub(1, 1500)
            ),
            0
        )
    end
    return el, matches
end

local function el_brief(el)
    return { id = el.id, win = el.win, cls = el.cls, text = el.text, icon = el.icon, rect = el.rect }
end

-- ---------------------------------------------------------------- commands

C.commands = {}
local cmd = C.commands
-- Answered straight away, without waiting for the UI to settle first.
C.no_settle = { ping = true, quit = true, log = true }

function cmd.ping(_, done)
    done({ pong = true })
end

function cmd.info(_, done)
    local ui, kind = C.current_ui()
    local r = {
        ui = kind,
        screen = { w = Screen:getWidth(), h = Screen:getHeight(), dpi = Screen:getDPI() },
        top = C.top_summary(),
        data_dir = require("datastorage"):getDataDir(),
        log = os.getenv("AGENTDRIVER_LOG"),
    }
    if kind == "reader" and ui.document then
        r.document = ui.document.file
        local ok, page = pcall(function()
            return ui:getCurrentPage()
        end)
        r.page = ok and page or nil
        r.pages = ui.document:getPageCount()
    elseif kind == "filemanager" and ui.file_chooser then
        r.path = ui.file_chooser.path
    end
    done(r)
end

function cmd.wait_idle(_, done)
    -- The dispatcher settles after every command; nothing else to do.
    done({})
end

function cmd.screenshot(params, done)
    done({ path = C.screenshot(params.path) })
end

function cmd.tree(params, done)
    local walk = C.walk(params)
    if params.format == "text" then
        local lines = {}
        local sw, sh = walk.screen.w, walk.screen.h
        lines[#lines + 1] = string.format("screen %dx%d", sw, sh)
        for _, win in ipairs(walk.windows) do
            lines[#lines + 1] = string.format(
                "window %d: %s%s%s%s",
                win.index,
                win.cls,
                win.name and (" (" .. tostring(win.name) .. ")") or "",
                win.fullscreen and " fullscreen" or "",
                win.hidden and " HIDDEN" or ""
            )
            for _, el in ipairs(walk.elements) do
                if el.win == win.index then
                    local flags = {}
                    if el.tap then
                        flags[#flags + 1] = "tap"
                    end
                    if el.enabled == false then
                        flags[#flags + 1] = "disabled"
                    end
                    if el.checked ~= nil then
                        flags[#flags + 1] = el.checked and "checked" or "unchecked"
                    end
                    if el.input then
                        flags[#flags + 1] = el.focused and "input,focused" or "input"
                    end
                    local text = el.text and el.text:gsub("\n", "⏎") or ""
                    if #text > 120 and not truthy(params.full) then
                        text = text:sub(1, 120) .. "…"
                    end
                    lines[#lines + 1] = string.format(
                        "%s#%d %s%s%s @%d,%d %dx%d%s",
                        string.rep("  ", el.depth + 1),
                        el.id,
                        el.cls,
                        text ~= "" and (" " .. string.format("%q", text):gsub("\\\n", "\\n")) or "",
                        el.icon and (" icon=" .. el.icon) or "",
                        el.rect[1],
                        el.rect[2],
                        el.rect[3],
                        el.rect[4],
                        #flags > 0 and (" [" .. table.concat(flags, ",") .. "]") or ""
                    )
                end
            end
        end
        return done({ text = table.concat(lines, "\n") })
    end
    done({
        screen = walk.screen,
        windows = Json.array(walk.windows),
        elements = Json.array(Inspect.public_elements(walk.elements, truthy(params.full))),
    })
end

function cmd.find(params, done)
    local walk = C.walk(params)
    local matches = Inspect.find(walk, params.text or params.icon or "", {
        exact = truthy(params.exact),
        pattern = truthy(params.pattern),
        win = params.win,
        icon = params.icon ~= nil and params.text == nil,
    })
    local out = {}
    for _, el in ipairs(matches) do
        local b = el_brief(el)
        b.center = { Inspect.center(el) }
        out[#out + 1] = b
    end
    done({ matches = Json.array(out) })
end

function cmd.tap(params, done)
    tap_at(num(params.x, "x"), num(params.y, "y"), done)
end

function cmd.tap_text(params, done)
    local el, matches = find_one(params)
    local x, y = Inspect.center(el)
    tap_at(x, y, function(r)
        r.element = el_brief(el)
        r.matches = #matches
        done(r)
    end)
end

function cmd.tap_id(params, done)
    local id = num(params.id, "id")
    local walk = Driver.last_walk
    local el = walk and walk.elements[id]
    if not el then
        error("no element #" .. id .. " in the last tree; run tree first", 0)
    end
    local x, y = Inspect.center(el)
    tap_at(x, y, function(r)
        r.element = el_brief(el)
        done(r)
    end)
end

local function do_hold(x, y, duration, done)
    run_steps({
        {
            0,
            function()
                send_ges({ ges = "touch", pos = point(x, y) })
                send_ges({ ges = "hold", pos = point(x, y) })
            end,
        },
        {
            duration,
            function()
                send_ges({ ges = "hold_release", pos = point(x, y) })
            end,
        },
    }, function(err)
        if err then
            return done(nil, err)
        end
        done({ x = x, y = y })
    end)
end

function cmd.hold(params, done)
    local x, y
    if params.text then
        local el = find_one(params)
        x, y = Inspect.center(el)
    else
        x, y = num(params.x, "x"), num(params.y, "y")
    end
    do_hold(x, y, tonumber(params.duration) or 0.3, done)
end

local function do_hold_pan(x0, y0, x1, y1, n, done)
    local steps = {
        {
            0,
            function()
                send_ges({ ges = "touch", pos = point(x0, y0) })
                send_ges({ ges = "hold", pos = point(x0, y0) })
            end,
        },
    }
    for i = 1, n do
        local x = math.floor(x0 + (x1 - x0) * i / n + 0.5)
        local y = math.floor(y0 + (y1 - y0) * i / n + 0.5)
        steps[#steps + 1] = {
            pan_interval(),
            function()
                local dx, dy = x - x0, y - y0
                send_ges({
                    ges = "hold_pan",
                    pos = point(x, y),
                    start_pos = point(x0, y0),
                    relative = { x = dx, y = dy },
                    direction = direction_of(dx, dy),
                    distance = math.sqrt(dx * dx + dy * dy),
                })
            end,
        }
    end
    steps[#steps + 1] = {
        0.15,
        function()
            send_ges({ ges = "hold_release", pos = point(x1, y1) })
        end,
    }
    run_steps(steps, function(err)
        if err then
            return done(nil, err)
        end
        done({ from = { x0, y0 }, to = { x1, y1 } })
    end)
end

function cmd.hold_pan(params, done)
    do_hold_pan(
        num(params.x0, "x0"),
        num(params.y0, "y0"),
        num(params.x1, "x1"),
        num(params.y1, "y1"),
        tonumber(params.steps) or 4,
        done
    )
end

function cmd.swipe(params, done)
    local x0, y0 = num(params.x0, "x0"), num(params.y0, "y0")
    local x1, y1 = num(params.x1, "x1"), num(params.y1, "y1")
    local dx, dy = x1 - x0, y1 - y0
    send_ges({ ges = "touch", pos = point(x0, y0) })
    send_ges({
        ges = "swipe",
        pos = point(x0, y0),
        end_pos = point(x1, y1),
        direction = params.direction or direction_of(dx, dy),
        distance = math.floor(math.sqrt(dx * dx + dy * dy)),
    })
    done({ direction = params.direction or direction_of(dx, dy) })
end

function cmd.pan(params, done)
    local x0, y0 = num(params.x0, "x0"), num(params.y0, "y0")
    local x1, y1 = num(params.x1, "x1"), num(params.y1, "y1")
    local n = tonumber(params.steps) or 4
    local steps = {
        {
            0,
            function()
                send_ges({ ges = "touch", pos = point(x0, y0) })
            end,
        },
    }
    for i = 1, n do
        local x = math.floor(x0 + (x1 - x0) * i / n + 0.5)
        local y = math.floor(y0 + (y1 - y0) * i / n + 0.5)
        steps[#steps + 1] = {
            pan_interval(),
            function()
                local dx, dy = x - x0, y - y0
                send_ges({
                    ges = "pan",
                    pos = point(x, y),
                    start_pos = point(x0, y0),
                    relative = { x = dx, y = dy },
                    direction = direction_of(dx, dy),
                    distance = math.sqrt(dx * dx + dy * dy),
                })
            end,
        }
    end
    steps[#steps + 1] = {
        0.05,
        function()
            send_ges({ ges = "pan_release", pos = point(x1, y1) })
        end,
    }
    run_steps(steps, function(err)
        if err then
            return done(nil, err)
        end
        done({})
    end)
end

function cmd.key(params, done)
    local name = params.name or params.key
    if not name then
        error("missing 'name' (e.g. Back, Menu, Home, Up, Down, Left, Right, Press, LPgFwd, RPgBack)", 0)
    end
    local mods = {}
    for m in (params.mods or ""):gmatch("[^,%s]+") do
        mods[m] = true
    end
    local key = Key:new(name, mods)
    UIManager.event_hook:execute("InputEvent")
    UIManager:sendEvent(Event:new("KeyPress", key))
    UIManager:sendEvent(Event:new("KeyRelease", key))
    done({ key = name })
end

local function focused_input()
    local walk = C.walk({})
    local best, any
    for i = #walk.elements, 1, -1 do
        local el = walk.elements[i]
        if el.input then
            if el.focused and (not best or el.win > best.win) then
                best = el
            end
            if not any or el.win > any.win then
                any = el
            end
        end
    end
    return best or any
end

function cmd.type(params, done)
    local el = focused_input()
    if not el then
        error("no input field visible", 0)
    end
    local w = el._w
    if truthy(params.clear) then
        w:setText("", true)
    end
    if params.text and params.text ~= "" then
        w:addChars(params.text)
    end
    done({ element = el_brief(el), value = w:getText() })
end

function cmd.open(params, done)
    local path = params.path
    if not path or require("libs/libkoreader-lfs").attributes(path, "mode") ~= "file" then
        error("not a file: " .. tostring(path), 0)
    end
    require("apps/reader/readerui"):showReader(path)
    done({ path = path })
end

function cmd.home(_, done)
    local ui, kind = C.current_ui()
    if kind == "reader" then
        ui:onHome()
    elseif kind == "filemanager" then
        ui:goHome()
    end
    done({ from = kind })
end

function cmd.log(params, done)
    local path = os.getenv("AGENTDRIVER_LOG")
    if not path then
        error("AGENTDRIVER_LOG not set", 0)
    end
    local n = tonumber(params.lines) or 50
    local f = io.open(path, "r")
    if not f then
        error("cannot open " .. path, 0)
    end
    local lines = {}
    for l in f:lines() do
        if not params.grep or l:find(params.grep, 1, not truthy(params.pattern)) then
            lines[#lines + 1] = l
            if #lines > n then
                table.remove(lines, 1)
            end
        end
    end
    f:close()
    done({ path = path, text = table.concat(lines, "\n") })
end

function cmd.eval(params, done)
    local code = params.code or params.body
    if not code or code == "" then
        error("missing 'code'", 0)
    end
    -- Prefer the expression form so `UIManager._window_stack[1]` just works.
    local fn, err = loadstring("return " .. code, "=eval")
    if not fn then
        fn, err = loadstring(code, "=eval")
    end
    if not fn then
        error(err, 0)
    end
    local ui = C.current_ui()
    local env = setmetatable({
        UIManager = UIManager,
        Device = Device,
        Screen = Screen,
        Event = Event,
        Geom = Geom,
        ui = ui,
        Inspect = Inspect,
        driver = C,
    }, { __index = _G })
    setfenv(fn, env)
    local res = { pcall(fn) }
    if not res[1] then
        error(res[2], 0)
    end
    table.remove(res, 1)
    done({ value = #res <= 1 and res[1] or Json.array(res) })
end

-- Text on the current reader page. text= finds occurrences and returns
-- their screen boxes (visible ones only); goto=1 jumps to the first hit
-- first if none is visible.
local function doc_hits(ui, text)
    local doc = ui.document
    if not doc or not doc.findAllText then
        error("no reflowable (CRE) document open", 0)
    end
    local hits = doc:findAllText(text, true, 0, 200, false) or {}
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local out = {}
    for _, hit in ipairs(hits) do
        local boxes = doc:getScreenBoxesFromPositions(hit.start, hit["end"], true) or {}
        local vis = {}
        for _, b in ipairs(boxes) do
            if b.y >= 0 and b.y + b.h <= sh and b.x >= 0 and b.x < sw and b.w > 0 then
                vis[#vis + 1] = { b.x, b.y, b.w, b.h }
            end
        end
        out[#out + 1] =
            { start = hit.start, ["end"] = hit["end"], visible = #vis > 0 and #vis == #boxes, boxes = Json.array(vis) }
    end
    return out
end

local function doc_find(params, cb, done)
    local ui, kind = C.current_ui()
    if kind ~= "reader" then
        error("no document open", 0)
    end
    local text = params.text
    if not text or text == "" then
        error("missing 'text'", 0)
    end
    local hits = doc_hits(ui, text)
    local any_visible = false
    for _, h in ipairs(hits) do
        any_visible = any_visible or h.visible
    end
    if not any_visible and hits[1] and truthy(params["goto"]) and ui.rolling then
        ui.rolling:onGotoXPointer(hits[1].start)
        return C.settle({}, function()
            local ok, err = pcall(function()
                cb(ui, doc_hits(ui, text))
            end)
            if not ok then
                done(nil, err)
            end
        end)
    end
    cb(ui, hits)
end

function cmd.doc_find(params, done)
    doc_find(params, function(_, hits)
        done({ hits = Json.array(hits) })
    end, done)
end

--- Select a visible passage with a real hold + hold_pan + release, the way a
-- finger would: from the left edge of its first box to the right edge of its
-- last one. Leaves the highlight popup open.
function cmd.select_text(params, done)
    doc_find(params, function(_, hits)
        local index = tonumber(params.index) or 1
        local n, chosen = 0, nil
        for _, h in ipairs(hits) do
            if h.visible then
                n = n + 1
                if n == index then
                    chosen = h
                    break
                end
            end
        end
        if not chosen then
            return done(
                nil,
                string.format(
                    "%q is not visible on this page (%d hit(s) in document; pass goto=1 to jump)",
                    params.text,
                    #hits
                )
            )
        end
        local first, last = chosen.boxes[1], chosen.boxes[#chosen.boxes]
        -- Aim about half a character inside each end: crengine snaps a point
        -- on the last glyph's right edge to the following word.
        local x0 = first[1] + math.min(math.floor(first[4] / 4), math.floor(first[3] / 4))
        local y0 = first[2] + math.floor(first[4] / 2)
        local x1 = last[1] + last[3] - math.min(math.floor(last[4] / 3), math.floor(last[3] / 4))
        local y1 = last[2] + math.floor(last[4] / 2)
        do_hold_pan(x0, y0, x1, y1, tonumber(params.steps) or 4, function(r, err)
            if not r then
                return done(nil, err)
            end
            r.hit = chosen
            done(r)
        end)
    end, done)
end

function cmd.quit(_, done)
    done({ quitting = true })
    UIManager:scheduleIn(0.3, function()
        UIManager:quit()
    end)
end

return C
