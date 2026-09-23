-- E2E test harness: test runner, assertions, UI driving and artifacts.
--
-- Tests drive the plugin the way a user does: through the real FileManager /
-- ReaderUI, the real touch menu (items found by their visible text), and the
-- real dialogs (buttons pressed by their label). Every dialog the plugin shows
-- is recorded and screenshotted into the artifacts dir.
--
-- Loaded by e2e/lib/main.lua after bootstrap; see e2e/README.md.

local JSON = require("json")
local ReadeckApi = require("readeck_api")
local socket = require("socket")

local H = {}

-- --------------------------------------------------------------------------
-- Environment
-- --------------------------------------------------------------------------

local function getenv(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

H.config = {
    repo = assert(getenv("E2E_REPO"), "E2E_REPO is required"),
    plugin_dir = assert(getenv("READECK_PLUGIN_DIR"), "READECK_PLUGIN_DIR is required"),
    ko_home = assert(getenv("KO_HOME"), "KO_HOME is required"),
    artifacts = assert(getenv("E2E_ARTIFACT_DIR"), "E2E_ARTIFACT_DIR is required"),
    results = getenv("E2E_RESULTS"),
    test_file = getenv("E2E_TEST_FILE", "?"),
    filter = getenv("E2E_TEST_FILTER"),
    version = getenv("READECK_LOCAL_VERSION", "0.23.4"),
    port = tonumber(getenv("READECK_LOCAL_PORT", "18900")),
    server_dir = assert(getenv("READECK_LOCAL_DIR"), "READECK_LOCAL_DIR is required"),
    python = getenv("PYTHON", "python3"),
    screenshots = getenv("E2E_SCREENSHOTS", "1") ~= "0",
}

-- Filled in by H.fresh_server(): READECK_URL, READECK_TOKEN, ... of the local server.
H.env = {}

local lfs, UIManager, Screen, time, util, DocSettings, Event

function H.init(koreader)
    lfs = require("libs/libkoreader-lfs")
    UIManager = require("ui/uimanager")
    Screen = koreader.Screen
    time = require("ui/time")
    util = require("util")
    DocSettings = require("docsettings")
    Event = require("ui/event")
    H.koreader = koreader
    H.install_ui_recorder()
    H.install_error_trap()
end

-- KOReader runs plugin event handlers in a sandbox that logs an error and
-- carries on, so a crashing handler is invisible to the user (and would be to
-- a test). Record those logs and fail the test that caused them.
H.handler_errors = {}
function H.install_error_trap()
    local logger = require("logger")
    local original_err = logger.err
    logger.err = function(...)
        local first = tostring((select(1, ...)))
        if first:find("An error occurred while executing", 1, true) then
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            table.insert(H.handler_errors, table.concat(parts, " "))
        end
        return original_err(...)
    end
end

-- --------------------------------------------------------------------------
-- Logging and artifacts
-- --------------------------------------------------------------------------

local current -- the running test's state

local function slugify(text)
    text = tostring(text or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return text:sub(1, 48)
end
H.slugify = slugify

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
H.shell_quote = shell_quote

function H.log(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local line =
        string.format("[%7.2fs] %s", current and (socket.gettime() - current.started) or 0, table.concat(parts, " "))
    print("[e2e] " .. line)
    if current and current.log_file then
        current.log_file:write(line, "\n")
        current.log_file:flush()
    end
end

function H.screenshot(label)
    if not current or not H.config.screenshots then
        return nil
    end
    current.shot_index = current.shot_index + 1
    if current.shot_index > 99 then
        return nil
    end
    local path = string.format("%s/%02d-%s.png", current.dir, current.shot_index, slugify(label))
    local ok, err = pcall(function()
        UIManager:forceRePaint()
        Screen:shot(path)
    end)
    if ok then
        H.log("screenshot:", path:sub(#H.config.artifacts + 2))
    else
        H.log("screenshot failed:", err)
    end
    return path
end

-- --------------------------------------------------------------------------
-- Assertions
-- --------------------------------------------------------------------------

local function describe(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    if type(value) == "table" then
        local ok, encoded = pcall(JSON.encode, value)
        if ok then
            return encoded
        end
    end
    return tostring(value)
end
H.describe = describe

function H.fail(message, level)
    error(message, (level or 1) + 1)
end

function H.truthy(value, message)
    if not value then
        error((message or "expected a truthy value") .. " (got " .. describe(value) .. ")", 2)
    end
    return value
end

function H.falsy(value, message)
    if value then
        error((message or "expected a falsy value") .. " (got " .. describe(value) .. ")", 2)
    end
end

function H.eq(actual, expected, message)
    if actual ~= expected then
        error(
            string.format(
                "%s\n  expected: %s\n    actual: %s",
                message or "values differ",
                describe(expected),
                describe(actual)
            ),
            2
        )
    end
end

function H.match(text, pattern, message)
    if type(text) ~= "string" or not text:find(pattern) then
        error(string.format("%s\n  pattern: %s\n     text: %s", message or "no match", pattern, describe(text)), 2)
    end
end

function H.no_match(text, pattern, message)
    if type(text) == "string" and text:find(pattern) then
        error(
            string.format("%s\n  unexpected pattern: %s\n  text: %s", message or "unexpected match", pattern, text),
            2
        )
    end
end

-- Plain-text containment (no Lua patterns).
function H.contains(text, needle, message)
    if type(text) ~= "string" or not text:find(needle, 1, true) then
        error(
            string.format(
                "%s\n  expected to contain: %s\n  text: %s",
                message or "missing text",
                needle,
                describe(text)
            ),
            2
        )
    end
end

-- --------------------------------------------------------------------------
-- Event loop pumping (deterministic; fast-forwards scheduled tasks)
-- --------------------------------------------------------------------------

-- Runs every task that is due, then fast-forwards virtual time to the next
-- scheduled task, repeatedly, until nothing is scheduled within `horizon`
-- seconds of virtual time. Real work (HTTP) happens inside tasks as usual.
function H.pump(horizon)
    local budget = time.s(horizon or 1)
    local advanced = 0
    for _ = 1, 20000 do
        UIManager:_checkTasks()
        UIManager:_repaint()
        local queue = UIManager._task_queue
        if #queue == 0 then
            return
        end
        local next_time = queue[#queue].time
        local now = time.now()
        if next_time > now then
            local delta = next_time - now
            if advanced + delta > budget then
                return
            end
            UIManager:shiftScheduledTasksBy(-delta)
            advanced = advanced + delta
        end
    end
    error("event loop did not settle (runaway scheduling?)")
end

-- Pumps until predicate() returns a truthy value, or fails after `timeout`
-- real seconds. `horizon` bounds each fast-forward step (virtual seconds).
function H.pump_until(predicate, opts)
    opts = opts or {}
    local deadline = socket.gettime() + (opts.timeout or 30)
    while true do
        H.pump(opts.horizon or 1)
        local result = predicate()
        if result then
            return result
        end
        if socket.gettime() > deadline then
            error((opts.message or "condition not met") .. " within " .. tostring(opts.timeout or 30) .. "s", 2)
        end
        socket.sleep(opts.interval or 0.02)
    end
end

-- Polls a real-time condition (e.g. server state) without touching the UI loop.
function H.wait_for(predicate, opts)
    opts = opts or {}
    local deadline = socket.gettime() + (opts.timeout or 30)
    while true do
        local result = predicate()
        if result then
            return result
        end
        if socket.gettime() > deadline then
            error((opts.message or "condition not met") .. " within " .. tostring(opts.timeout or 30) .. "s", 2)
        end
        socket.sleep(opts.interval or 0.1)
    end
end

-- --------------------------------------------------------------------------
-- UI recorder: every UIManager:show / close
-- --------------------------------------------------------------------------

H.dialogs = {} -- every widget shown during the current test, in order

local widget_classes -- lazily resolved: { {name, class}, ... } most specific first

local function resolve_widget_classes()
    if widget_classes then
        return widget_classes
    end
    widget_classes = {}
    local names = {
        { "MultiConfirmBox", "ui/widget/multiconfirmbox" },
        { "ConfirmBox", "ui/widget/confirmbox" },
        { "QRMessage", "ui/widget/qrmessage" },
        { "InfoMessage", "ui/widget/infomessage" },
        { "MultiInputDialog", "ui/widget/multiinputdialog" },
        { "InputDialog", "ui/widget/inputdialog" },
        { "ButtonDialog", "ui/widget/buttondialog" },
        { "RadioButtonWidget", "ui/widget/radiobuttonwidget" },
        { "VirtualKeyboard", "ui/widget/virtualkeyboard" },
        { "Notification", "ui/widget/notification" },
        { "ReaderUI", "apps/reader/readerui" },
        { "FileManager", "apps/filemanager/filemanager" },
    }
    for _, entry in ipairs(names) do
        local ok, class = pcall(require, entry[2])
        if ok and type(class) == "table" then
            table.insert(widget_classes, { entry[1], class })
        end
    end
    return widget_classes
end

local function is_instance_of(object, class)
    local mt = getmetatable(object)
    local depth = 0
    while mt and depth < 30 do
        if mt == class then
            return true
        end
        mt = getmetatable(mt)
        depth = depth + 1
    end
    return false
end

function H.widget_kind(widget)
    for _, entry in ipairs(resolve_widget_classes()) do
        if is_instance_of(widget, entry[2]) then
            return entry[1]
        end
    end
    if type(widget) == "table" and type(widget[1]) == "table" and widget[1].tab_item_table then
        return "TouchMenu"
    end
    return "Widget"
end

-- The text a user would read on the widget.
function H.widget_text(widget)
    if type(widget) ~= "table" then
        return ""
    end
    local parts = {}
    local function add(value)
        if type(value) == "string" and value ~= "" then
            table.insert(parts, value)
        end
    end
    add(widget.title)
    add(widget.title_text)
    add(widget.text)
    add(widget.description)
    if type(widget.input_fields) == "table" then
        for _, field in ipairs(widget.input_fields) do
            if type(field.getText) == "function" then
                add(field:getText())
            end
        end
    end
    return table.concat(parts, "\n")
end

local BORING_KINDS = { FileManager = true, ReaderUI = true, VirtualKeyboard = true, Widget = true }

function H.install_ui_recorder()
    local original_show = UIManager.show
    local original_close = UIManager.close
    H._original_show = original_show

    UIManager.show = function(self, widget, ...)
        local result = original_show(self, widget, ...)
        if current and type(widget) == "table" then
            local kind = H.widget_kind(widget)
            local entry = {
                widget = widget,
                kind = kind,
                text = H.widget_text(widget),
                seq = #H.dialogs + 1,
                open = true,
            }
            table.insert(H.dialogs, entry)
            if not BORING_KINDS[kind] then
                H.log(string.format("show #%d %s: %s", entry.seq, kind, (entry.text:gsub("\n", " | "))))
                if kind ~= "TouchMenu" then
                    H.screenshot(kind .. "-" .. entry.text:sub(1, 40))
                end
            end
        end
        return result
    end

    UIManager.close = function(self, widget, ...)
        if type(widget) == "table" then
            for i = #H.dialogs, 1, -1 do
                if H.dialogs[i].widget == widget then
                    H.dialogs[i].open = false
                    -- Progress messages update their text in place; keep the last one.
                    H.dialogs[i].text = H.widget_text(widget)
                    break
                end
            end
        end
        return original_close(self, widget, ...)
    end
end

-- A position in the dialog history, to only look at what happened after it.
function H.mark()
    return #H.dialogs
end

local function dialog_matches(entry, pattern, opts)
    if opts.kind and entry.kind ~= opts.kind then
        return false
    end
    if BORING_KINDS[entry.kind] or entry.kind == "TouchMenu" then
        return false
    end
    local text = H.widget_text(entry.widget)
    if text == "" then
        text = entry.text
    end
    if pattern == nil then
        return true
    end
    if opts.plain then
        return text:find(pattern, 1, true) ~= nil
    end
    return text:find(pattern) ~= nil
end

-- Most recent matching dialog shown after `opts.since` (a mark).
function H.find_dialog(pattern, opts)
    opts = opts or {}
    for i = #H.dialogs, (opts.since or 0) + 1, -1 do
        local entry = H.dialogs[i]
        if (not opts.open or entry.open) and dialog_matches(entry, pattern, opts) then
            return entry
        end
    end
    return nil
end

function H.dialogs_since(mark)
    local list = {}
    for i = (mark or 0) + 1, #H.dialogs do
        local entry = H.dialogs[i]
        if not BORING_KINDS[entry.kind] and entry.kind ~= "TouchMenu" then
            table.insert(list, entry)
        end
    end
    return list
end

function H.dialog_texts_since(mark)
    local texts = {}
    for _, entry in ipairs(H.dialogs_since(mark)) do
        table.insert(texts, H.widget_text(entry.widget))
    end
    return table.concat(texts, "\n---\n")
end

function H.wait_dialog(pattern, opts)
    opts = opts or {}
    return H.pump_until(function()
        return H.find_dialog(pattern, opts)
    end, {
        timeout = opts.timeout or 30,
        horizon = opts.horizon,
        message = "no dialog matching " .. describe(pattern) .. " appeared. Dialogs so far:\n" .. H.dialog_texts_since(
            opts.since
        ),
    })
end

-- Widgets currently on the window stack, topmost first.
function H.open_widgets()
    local list = {}
    for i = #UIManager._window_stack, 1, -1 do
        table.insert(list, UIManager._window_stack[i].widget)
    end
    return list
end

local Button
local function find_buttons(root, label)
    Button = Button or require("ui/widget/button")
    local found = {}
    local seen = {}
    local function walk(node, depth)
        if type(node) ~= "table" or seen[node] or depth > 40 then
            return
        end
        seen[node] = true
        if is_instance_of(node, Button) then
            if label == nil or node.text == label then
                table.insert(found, node)
            end
            return
        end
        for key, child in pairs(node) do
            if
                type(child) == "table"
                and key ~= "show_parent"
                and key ~= "parent"
                and key ~= "ui"
                and key ~= "dialog"
            then
                walk(child, depth + 1)
            end
        end
    end
    walk(root, 0)
    return found
end

function H.button_labels(widget)
    local labels = {}
    for _, button in ipairs(find_buttons(widget)) do
        table.insert(labels, tostring(button.text))
    end
    return labels
end

local function entry_widget(target)
    if type(target) == "table" and target.widget and target.kind then
        return target.widget
    end
    return target
end

-- Presses the button labelled `label` on `target` (a dialog entry or widget;
-- defaults to the topmost open widget that has such a button).
function H.press(label, target)
    local candidates = target and { entry_widget(target) } or H.open_widgets()
    for _, widget in ipairs(candidates) do
        local buttons = find_buttons(widget, label)
        if #buttons > 0 then
            local button = buttons[1]
            if not button.enabled then
                error("button " .. describe(label) .. " is disabled", 2)
            end
            H.log("press:", label)
            button.callback()
            H.pump(0.5)
            return true
        end
    end
    local available = {}
    for _, widget in ipairs(candidates) do
        for _, text in ipairs(H.button_labels(widget)) do
            table.insert(available, text)
        end
    end
    error("no button labelled " .. describe(label) .. "; available: " .. table.concat(available, ", "), 2)
end

-- Types into an InputDialog, or into field `index` of a MultiInputDialog.
function H.fill(target, text, index)
    local widget = entry_widget(target)
    H.log("type:", describe(text))
    if type(widget.input_fields) == "table" then
        widget.input_fields[index or 1]:setText(text)
    elseif type(widget.setInputText) == "function" then
        widget:setInputText(text)
    else
        error("widget has no text input", 2)
    end
end

function H.dismiss(target)
    local widget = entry_widget(target)
    if type(widget.onTapClose) == "function" then
        widget:onTapClose()
    else
        UIManager:close(widget)
    end
    H.pump(0.2)
end

-- Closes every dialog on top of FileManager/ReaderUI (like tapping them away).
function H.dismiss_all()
    for _, widget in ipairs(H.open_widgets()) do
        local kind = H.widget_kind(widget)
        if kind ~= "FileManager" and kind ~= "ReaderUI" then
            UIManager:close(widget)
        end
    end
    H.pump(0.2)
end

-- --------------------------------------------------------------------------
-- Touch menu: find items by visible text and tap them
-- --------------------------------------------------------------------------

local function item_text(item)
    if item.text_func then
        local ok, text = pcall(item.text_func)
        if ok then
            return text
        end
    end
    return item.text
end
H.menu_item_text = item_text

local function item_enabled(item)
    if item.enabled_func then
        return item.enabled_func()
    end
    return item.enabled ~= false
end

local function find_item(items, wanted)
    local texts = {}
    for _, item in ipairs(items or {}) do
        local text = item_text(item)
        table.insert(texts, tostring(text))
        if text == wanted or (type(wanted) == "table" and type(text) == "string" and text:find(wanted[1])) then
            return item
        end
    end
    return nil, texts
end

-- Opens the main menu of `ui` (FileManager or ReaderUI), navigates the path of
-- visible item texts and taps the last one, exactly like a finger would. A
-- path element may be {"lua pattern"} to match a dynamic label.
-- Builds the menu's tab table once per menu, as onShowMenu does: some
-- KOReader releases (2026.07.1) mutate their menu order tables while sorting,
-- so a second setUpdateItemTable() crashes in MenuSorter.
local function ensure_menu_table(menu)
    if menu.tab_item_table == nil then
        menu:setUpdateItemTable()
    end
    return menu.tab_item_table
end

function H.tap_menu(ui, path, opts)
    opts = opts or {}
    local menu = ui.menu
    ensure_menu_table(menu)
    local tab_index
    for index, tab in ipairs(menu.tab_item_table) do
        if find_item(tab, path[1]) then
            tab_index = index
            break
        end
    end
    H.truthy(tab_index, "no menu tab contains " .. describe(path[1]))
    menu:onShowMenu(tab_index)
    local touch_menu = menu.menu_container[1]
    touch_menu:switchMenuTab(tab_index)
    for depth, wanted in ipairs(path) do
        local item, texts = find_item(touch_menu.item_table, wanted)
        if not item then
            H.screenshot("menu-missing-" .. tostring(type(wanted) == "table" and wanted[1] or wanted))
            error("menu item " .. describe(wanted) .. " not found; items: " .. table.concat(texts, " | "), 2)
        end
        if not item_enabled(item) then
            H.screenshot("menu-disabled-" .. tostring(item_text(item)))
            error("menu item " .. describe(item_text(item)) .. " is disabled", 2)
        end
        if depth == #path then
            if opts.screenshot ~= false then
                H.screenshot("menu-" .. tostring(item_text(item)))
            end
            H.log(
                "tap menu:",
                table.concat(
                    (function()
                        local list = {}
                        for i = 1, depth do
                            list[i] = type(path[i]) == "table" and path[i][1] or path[i]
                        end
                        return list
                    end)(),
                    " > "
                )
            )
        end
        touch_menu:onMenuSelect(item)
    end
    H.pump(0.2)
    -- Leave the menu if the tapped item kept it open.
    if menu.menu_container and opts.keep_open ~= true then
        touch_menu:closeMenu()
        H.pump(0.2)
    end
end

-- Current checked state of a checkbox menu item (without tapping it).
function H.menu_checked(ui, path)
    local menu = ui.menu
    ensure_menu_table(menu)
    local items
    for _, tab in ipairs(menu.tab_item_table) do
        if find_item(tab, path[1]) then
            items = tab
            break
        end
    end
    local item
    for depth, wanted in ipairs(path) do
        item = find_item(items, wanted)
        H.truthy(item, "menu item not found: " .. describe(wanted))
        if depth < #path then
            items = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        end
    end
    if item.checked_func then
        return item.checked_func() and true or false
    end
    return item.checked and true or false
end

-- Taps a checkbox item until it has the wanted state.
function H.set_menu_checkbox(ui, path, wanted)
    if H.menu_checked(ui, path) ~= wanted then
        H.tap_menu(ui, path, { screenshot = false })
    end
    H.eq(H.menu_checked(ui, path), wanted, "checkbox " .. describe(path[#path]) .. " did not toggle")
end

-- --------------------------------------------------------------------------
-- Local Readeck server (fresh per test)
-- --------------------------------------------------------------------------

local function readeck_local(args)
    local cmd = string.format(
        "%s %s %s --dir %s 2>>%s",
        H.config.python,
        shell_quote(H.config.repo .. "/e2e/readeck_local.py"),
        args,
        shell_quote(H.config.server_dir),
        shell_quote(H.config.server_dir .. ".cmd.log")
    )
    local pipe = assert(io.popen(cmd))
    local output = pipe:read("*a")
    local ok = pipe:close()
    return ok, output
end

function H.fresh_server(version)
    local started = socket.gettime()
    local ok, output = readeck_local(
        string.format("start --version %s --port %d", shell_quote(version or H.config.version), H.config.port)
    )
    local env = {}
    for key, value in output:gmatch("export ([%w_]+)='([^']*)'") do
        env[key] = value
    end
    if not ok or not env.READECK_URL then
        error("could not start the local Readeck server; see " .. H.config.server_dir .. ".cmd.log")
    end
    ReadeckApi.assert_local_url(env.READECK_URL)
    H.env = env
    H.api = ReadeckApi.new(env.READECK_URL, env.READECK_TOKEN)
    H.log(
        string.format(
            "fresh Readeck %s at %s (%.1fs)",
            env.READECK_VERSION,
            env.READECK_URL,
            socket.gettime() - started
        )
    )
    return env
end

-- True when the running local server is at least `version` ("0.22.2").
function H.server_at_least(version)
    local function parts(v)
        local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.?(%d*)")
        return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
    end
    local have, want = parts(H.env.READECK_VERSION), parts(version)
    for i = 1, 3 do
        if have[i] ~= want[i] then
            return have[i] > want[i]
        end
    end
    return true
end

function H.stop_server()
    readeck_local("stop")
end

function H.approve_device(user_code, deny)
    local ok =
        readeck_local(string.format("approve-device --code %s%s", shell_quote(user_code), deny and " --deny" or ""))
    H.truthy(ok, "approving the device code failed")
end

function H.fixture_url(path)
    return H.env.READECK_FIXTURE_URL .. "/" .. path:gsub("^/", "")
end

-- Creates `count` bookmarks of generated articles and waits until they are loaded.
-- Returns a list of { id, title, url } in creation order.
function H.seed(count, opts)
    opts = opts or {}
    local created = {}
    for i = 1, count do
        local title = string.format("%s %02d", opts.title_prefix or "Generated Article", i)
        local url = H.fixture_url("gen/" .. slugify(title) .. ".html")
        local id = H.api:create_bookmark(url, opts.labels)
        table.insert(created, { id = id, title = title, url = url })
    end
    for _, bookmark in ipairs(created) do
        H.api:wait_loaded(bookmark.id)
    end
    H.log("seeded", count, "bookmark(s)")
    return created
end

-- Bookmarks a fixture page and waits until loaded. Returns only the id, so
-- `{ H.seed_page(a), H.seed_page(b) }` builds a plain list of ids.
function H.seed_page(page, opts)
    opts = opts or {}
    local id = H.api:create_bookmark(H.fixture_url(page), opts.labels)
    if opts.wait ~= false then
        H.api:wait_loaded(id)
    end
    return id
end

-- --------------------------------------------------------------------------
-- Plugin setup
-- --------------------------------------------------------------------------

-- Writes settings/readeck.lua the way the plugin itself persists it, before
-- the plugin is instantiated. Returns the download directory.
function H.configure_plugin(overrides)
    overrides = overrides or {}
    local directory = overrides.directory or (current.work_dir .. "/articles/")
    util.makePath(directory)
    local settings = {
        server_url = H.env.READECK_URL,
        auth_token = H.env.READECK_TOKEN,
        directory = directory,
        log_level = "debug",
        -- Keep the defaults a fresh install gets, except for timeouts that
        -- would make an unreachable-server test slow.
        block_timeout = 5,
        total_timeout = 15,
        file_block_timeout = 5,
        file_total_timeout = 15,
    }
    for key, value in pairs(overrides) do
        if value == H.NULL then
            settings[key] = nil
        else
            settings[key] = value
        end
    end
    -- The plugin must only ever be pointed at a loopback server.
    if settings.server_url then
        ReadeckApi.assert_local_url(settings.server_url)
    end
    local LuaSettings = require("luasettings")
    local path = H.koreader.DataStorage:getSettingsDir() .. "/readeck.lua"
    os.remove(path)
    local rd = LuaSettings:open(path)
    rd:saveSetting("readeck", settings)
    rd:flush()
    H.download_dir = directory
    return directory
end
H.NULL = {}

function H.plugin_settings()
    local path = H.koreader.DataStorage:getSettingsDir() .. "/readeck.lua"
    local ok, data = pcall(dofile, path)
    return ok and data and data.readeck or {}
end

function H.open_filemanager(dir)
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onClose()
    end
    FileManager:showFiles(dir or H.download_dir)
    H.pump(0.5)
    local fm = H.truthy(FileManager.instance, "FileManager did not open")
    H.truthy(fm.readeck, "the Readeck plugin was not instantiated by FileManager")
    return fm
end

-- Opens `path` the way tapping it in the file browser does.
function H.open_reader(path)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
    local reader = H.pump_until(function()
        return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
    end, { timeout = 30, message = "ReaderUI did not open " .. path })
    H.pump(0.5)
    H.truthy(reader.readeck, "the Readeck plugin was not instantiated by ReaderUI")
    return reader
end

function H.close_reader()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:onClose()
        H.pump(0.5)
    end
end

function H.close_ui()
    H.dismiss_all()
    H.close_reader()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onClose()
    end
    for _, widget in ipairs(H.open_widgets()) do
        UIManager:close(widget)
    end
    H.pump(0.5)
    UIManager._task_queue = {}
end

-- Selects `text` in the open document with a real long-press + drag, the way
-- a finger does, and returns the highlight popup ("Highlight", "Add note", ...).
-- `occurrence` picks the n-th match (default 1).
-- `text` may be { "first words", "last words" } to select from the start of
-- one phrase to the end of another (e.g. across paragraphs).
function H.select_text(reader, text, occurrence)
    local Geom = require("ui/geometry")
    local document = reader.document
    local function find(phrase)
        -- origin -1 / direction 0: search forward from the start, like "Search from start".
        local hits = document:findText(phrase, -1, 0, false, reader.view.state.page or 1, false, 50)
        if not hits then
            -- origin -1 only covers what precedes the current page's end; origin 1
            -- finds text further on (e.g. a paragraph on page 2).
            hits = document:findText(phrase, 1, 0, false, reader.view.state.page or 1, false, 50)
        end
        hits = hits or {}
        local hit = hits[occurrence or 1]
        H.truthy(hit, "text not found in the document: " .. describe(phrase))
        return hit
    end
    local start_hit = find(type(text) == "table" and text[1] or text)
    local end_hit = type(text) == "table" and find(text[2]) or start_hit
    reader.rolling:onGotoXPointer(start_hit.start, start_hit.start)
    H.pump(0.3)
    local boxes = document:getScreenBoxesFromPositions(start_hit.start, end_hit["end"], true)
    H.truthy(boxes and #boxes > 0, "selection is not on screen: " .. describe(text))
    local first, last = boxes[1], boxes[#boxes]
    local from = Geom:new({ x = first.x + 1, y = first.y + math.floor(first.h / 2) })
    local to = Geom:new({ x = last.x + last.w - 1, y = last.y + math.floor(last.h / 2) })
    local mark = H.mark()
    reader.highlight:onHold(nil, { pos = from, time = time.now() })
    reader.highlight:onHoldPan(nil, { pos = to, time = time.now() })
    reader.highlight:onHoldRelease(nil, { pos = to, time = time.now() })
    local popup = H.wait_dialog(nil, { since = mark, kind = "ButtonDialog", timeout = 5 })
    local selected = reader.highlight.selected_text and reader.highlight.selected_text.text or ""
    H.log("selected:", describe(selected))
    return popup, selected
end

-- Highlights `text` through the popup; with opts.note also types a note.
-- Returns the new annotation (KOReader's own table).
function H.highlight(reader, text, opts)
    opts = opts or {}
    local before = #reader.annotation.annotations
    local existing = {}
    for _, annotation in ipairs(reader.annotation.annotations) do
        existing[annotation] = true
    end
    local popup = H.select_text(reader, text, opts.occurrence)
    if opts.note then
        local mark = H.mark()
        H.press("Add note", popup)
        local editor = H.wait_dialog("Edit note", { since = mark, kind = "InputDialog" })
        H.fill(editor, opts.note)
        H.press("Save", editor)
    else
        H.press("Highlight", popup)
    end
    H.pump(0.3)
    H.eq(#reader.annotation.annotations, before + 1, "highlight added for " .. describe(text))
    -- The newest annotation is not necessarily last: KOReader keeps them sorted.
    for _, annotation in ipairs(reader.annotation.annotations) do
        if not existing[annotation] then
            if opts.color then
                annotation.color = opts.color -- what "Change color" in the highlight menu does
            end
            return annotation
        end
    end
    error("could not find the new highlight for " .. describe(text))
end

-- Long-presses a file in the file browser: returns the file dialog entry.
function H.long_press_file(fm, path)
    local mark = H.mark()
    fm.file_chooser:onFileHold({ path = path, is_file = true, text = path:match("[^/]+$") })
    return H.wait_dialog(nil, { since = mark, kind = "ButtonDialog", timeout = 5 })
end

-- Runs the plugin's full sync through the menu and waits for its summary.
-- Returns the summary text.
function H.sync_via_menu(ui, opts)
    opts = opts or {}
    local mark = H.mark()
    H.tap_menu(ui, { "Readeck", "Synchronize articles with server" })
    local entry = H.wait_dialog(opts.expect or "Processing finished%.", {
        since = mark,
        timeout = opts.timeout or 60,
    })
    H.pump_until(function()
        return not ui.readeck.sync_in_progress
    end, { timeout = 10, message = "sync never finished" })
    local text = H.widget_text(entry.widget)
    H.log("sync summary:", (text:gsub("\n", " | ")))
    H.dismiss_all()
    return text, mark
end

-- --------------------------------------------------------------------------
-- Local files
-- --------------------------------------------------------------------------

-- Downloaded articles in the download dir: { {path, name, id}, ... } sorted by name.
function H.local_articles(dir)
    dir = dir or H.download_dir
    local list = {}
    if lfs.attributes(dir, "mode") ~= "directory" then
        return list
    end
    for entry in lfs.dir(dir) do
        local path = dir:gsub("/$", "") .. "/" .. entry
        if lfs.attributes(path, "mode") == "file" then
            local id = entry:match("%[rd%-id_([^%]]+)%]")
            table.insert(list, { path = path, name = entry, id = id })
        end
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    return list
end

function H.local_article_by_id(id, dir)
    for _, article in ipairs(H.local_articles(dir)) do
        if article.id == id then
            return article
        end
    end
    return nil
end

-- Opens the EPUB with KOReader's libarchive binding and returns the dc:title,
-- failing if the file is not a valid EPUB container.
function H.epub_title(path)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    H.truthy(reader:open(path), "not a readable archive: " .. path)
    local mimetype, opf
    for entry in reader:iterate() do
        if entry.path == "mimetype" then
            mimetype = reader:extractToMemory(entry.path)
        elseif entry.path:match("%.opf$") then
            opf = reader:extractToMemory(entry.path)
        end
    end
    reader:close()
    H.eq(mimetype, "application/epub+zip", "EPUB mimetype entry of " .. path)
    H.truthy(opf, "no OPF package document in " .. path)
    local title = opf:match("<dc:title[^>]*>(.-)</dc:title>")
    return title and title:gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&quot;", '"')
end

-- Rewrites the article chapter of a downloaded EPUB with `edit(xhtml) ->
-- xhtml`, e.g. to make the local copy differ from the server's article.
function H.edit_epub_chapter(path, edit)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    H.truthy(reader:open(path), "cannot open " .. path)
    local entries = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            table.insert(entries, { path = entry.path, content = reader:extractToMemory(entry.path) })
        end
    end
    reader:close()
    local edited = false
    for _, entry in ipairs(entries) do
        -- OEBPS/Text/<id>.html from Readeck 0.22, OEBPS/<id>.html before.
        if entry.path:match("%.x?html?$") and entry.content:find("<main", 1, true) then
            entry.content = edit(entry.content)
            edited = true
        end
    end
    H.truthy(edited, "no chapter in " .. path)
    local tmp = path .. ".tmp"
    local writer = Archiver.Writer:new()
    H.truthy(writer:open(tmp, "epub"), "cannot write " .. tmp)
    for _, entry in ipairs(entries) do
        writer:setZipCompression(entry.path == "mimetype" and "store" or "deflate")
        writer:addFileFromMemory(entry.path, entry.content)
    end
    writer:close()
    H.truthy(os.rename(tmp, path), "cannot replace " .. path)
end

function H.set_book_status(path, status)
    local settings = DocSettings:open(path)
    local summary = settings:readSetting("summary") or {}
    summary.status = status
    settings:saveSetting("summary", summary)
    settings:flush()
end

function H.doc_setting(path, key)
    if not DocSettings:hasSidecarFile(path) then
        return nil
    end
    return DocSettings:open(path):readSetting(key)
end

-- Keywords KOReader shows in Book information (the plugin writes labels and
-- reading time into the book's custom metadata).
function H.custom_keywords(path)
    local file = DocSettings:findCustomMetadataFile(path)
    if not file then
        return nil
    end
    local props = DocSettings.openSettingsFile(file):readSetting("custom_props") or {}
    return props.keywords
end

function H.send_event(ui, name, ...)
    ui:handleEvent(Event:new(name, ...))
end

-- --------------------------------------------------------------------------
-- Runner
-- --------------------------------------------------------------------------

local tests = {}

-- H.test(name, fn [, opts])  opts.xfail = "reason" marks a known plugin bug:
-- the test must fail (reported XFAIL, not fatal); passing is reported XPASS
-- and fails the run so the marker gets removed. opts.skip = "reason".
-- opts.versions = { ["0.22.1"] = "skip reason" } skips on given server versions.
-- opts.fresh_server = false reuses the previous test's server.
-- opts.server_version = "0.22.1" runs this test against that Readeck release.
function H.test(name, fn, opts)
    table.insert(tests, { name = name, fn = fn, opts = opts or {} })
end

local function write_result(test, status, duration, message)
    if not H.config.results then
        return
    end
    local file = io.open(H.config.results, "a")
    if file then
        local one_line = tostring(message or ""):gsub("[\r\n\t]+", " "):sub(1, 400)
        file:write(
            table.concat({
                status,
                test.opts.server_version or H.config.version,
                H.config.test_file,
                test.name,
                string.format("%.1f", duration),
                one_line,
            }, "\t"),
            "\n"
        )
        file:close()
    end
end

-- Runs one test; returns true when it counts as a failure of the run.
local function run_one(index, test, file_slug)
    local failed = false
    do
        local skip_reason = test.opts.skip or (test.opts.versions and test.opts.versions[H.config.version])
        local dir = string.format("%s/%s/%02d-%s", H.config.artifacts, file_slug, index, slugify(test.name))
        util.makePath(dir)
        local work_dir = string.format("%s/work/%s-%02d", H.config.ko_home, file_slug, index)
        util.makePath(work_dir)
        current = {
            name = test.name,
            dir = dir,
            work_dir = work_dir,
            shot_index = 0,
            started = socket.gettime(),
            log_file = io.open(dir .. "/log.txt", "w"),
        }
        H.dialogs = {}
        H.handler_errors = {}
        local status, message
        if skip_reason then
            status, message = "SKIP", skip_reason
            H.log("SKIP", test.name, "-", skip_reason)
        else
            H.log("=== " .. test.name .. " (Readeck " .. H.config.version .. ")")
            local ok, err = xpcall(function()
                if test.opts.fresh_server ~= false or not H.api then
                    H.fresh_server(test.opts.server_version)
                end
                test.fn(H)
                if #H.handler_errors > 0 and not test.opts.allow_handler_errors then
                    error("a plugin event handler raised (swallowed by KOReader): " .. H.handler_errors[1], 0)
                end
            end, debug.traceback)
            if not ok then
                H.log("error:", err)
                H.screenshot("failure")
            end
            local cleanup_ok, cleanup_err = pcall(H.close_ui)
            if not cleanup_ok then
                H.log("cleanup error:", cleanup_err)
            end
            if test.opts.xfail then
                if ok then
                    status, message = "XPASS", "expected to fail (" .. test.opts.xfail .. ") but passed"
                    failed = true
                else
                    status, message = "XFAIL", test.opts.xfail
                end
            elseif ok then
                status = "PASS"
            else
                status, message = "FAIL", tostring(err):match("^[^\n]*")
                failed = true
            end
        end
        local duration = socket.gettime() - current.started
        H.log(string.format("%s %s (%.1fs)%s", status, test.name, duration, message and (" - " .. message) or ""))
        -- Dialog transcript, for reviewing wording without opening PNGs.
        local transcript = io.open(dir .. "/dialogs.txt", "w")
        if transcript then
            for _, entry in ipairs(H.dialogs_since(0)) do
                transcript:write(string.format("#%d %s\n%s\n\n", entry.seq, entry.kind, H.widget_text(entry.widget)))
            end
            transcript:close()
        end
        write_result(test, status, duration, message)
        if current.log_file then
            current.log_file:close()
        end
        current = nil
    end
    return failed
end

function H.run()
    local failures = 0
    local file_slug = slugify(H.config.test_file:gsub("^.*/", ""):gsub("%.lua$", ""))
    for index, test in ipairs(tests) do
        local selected = not H.config.filter or test.name:find(H.config.filter, 1, true)
        if selected and run_one(index, test, file_slug) then
            failures = failures + 1
        end
    end
    return failures
end

return H
