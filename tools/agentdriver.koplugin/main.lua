--[[--
Agent driver: a DEVELOPMENT-ONLY control API for the KOReader emulator.

Listens on http://127.0.0.1:$AGENTDRIVER_PORT and lets a script or an AI
agent take screenshots, dump the visible widgets with their text and screen
rectangles, tap/hold/pan/swipe, press keys, type, open documents and eval
Lua. Every answer is JSON and is sent only after the UI has settled.

The plugin does nothing unless AGENTDRIVER_PORT is set (tools/kodrive sets
it), binds to localhost only, and must never be shipped with a release.
--]]
local port = tonumber(os.getenv("AGENTDRIVER_PORT") or "")
if not port then
    return { disabled = true }
end

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

-- These must be required now: package.path only includes this plugin's
-- directory while its main.lua is being loaded.
local Json = require("agentdriver/json")
local Server = require("agentdriver/server")
local Inspect = require("agentdriver/inspect")
local Commands = require("agentdriver/commands")

Inspect.install()

local HELP = [[agentdriver - GET/POST http://127.0.0.1:PORT/<command>?param=value
commands: ping info wait_idle screenshot[path] tree[format=text,all,full,norepaint]
  find[text|icon,exact,pattern,win] tap[x,y] tap_text[text,index,exact,win] tap_id[id]
  hold[x,y|text,duration] hold_pan[x0,y0,x1,y1,steps] swipe[x0,y0,x1,y1] pan[x0,y0,x1,y1]
  key[name,mods] type[text,clear] open[path] home doc_find[text,goto] select_text[text,index,goto]
  log[lines,grep] eval[code] quit
common params: shot=<png path> (screenshot after settling), settle=0, timeout=<s>, dialog=0
]]

local function respond(reply, status, tbl)
    local ok, body = pcall(Json.encode, tbl)
    if not ok then
        status, body = 500, Json.encode({ ok = false, error = "encode failed: " .. tostring(body) })
    end
    reply(status, "application/json", body .. "\n")
end

local function dispatch(req, reply)
    local name = req.path:gsub("^/+", ""):gsub("/+$", "")
    local params = req.params
    if name == "" or name == "help" then
        return reply(200, "text/plain", HELP)
    end
    if
        name == "eval"
        and not params.code
        and req.body ~= ""
        and not (req.headers["content-type"] or ""):find("urlencoded", 1, true)
    then
        params.code = req.body
    end
    local handler = Commands.commands[name]
    if not handler then
        return respond(reply, 404, { ok = false, error = "unknown command: " .. name, help = HELP })
    end
    local answered = false
    local started = require("ui/time").now()
    local trace
    local function fail(err)
        if answered then
            return
        end
        answered = true
        logger.warn("agentdriver:", name, "failed:", err)
        respond(
            reply,
            400,
            { ok = false, cmd = name, error = tostring(err), trace = trace, top = Commands.top_summary() }
        )
    end
    local function finish(result, settle_info)
        if answered then
            return
        end
        answered = true
        local out = { ok = true, cmd = name, result = result, settle = settle_info, top = Commands.top_summary() }
        if params.shot and params.shot ~= "" then
            out.shot = Commands.screenshot(params.shot)
        end
        if params.dialog ~= "0" and not Commands.no_settle[name] and name ~= "tree" then
            local ok, walk = pcall(Commands.walk, {})
            if ok then
                out.dialog = Commands.dialog_texts(walk)
            end
        end
        out.elapsed_ms = require("ui/time").to_ms(require("ui/time").since(started))
        respond(reply, 200, out)
    end
    local function done(result, err)
        if err or result == nil then
            return fail(err or "command returned nothing")
        end
        if Commands.no_settle[name] or params.settle == "0" then
            local ok, e = pcall(finish, result, nil)
            if not ok then
                answered = false
                fail(e)
            end
            return
        end
        Commands.settle(params, function(info)
            local ok, e = pcall(finish, result, info)
            if not ok then
                answered = false
                fail(e)
            end
        end)
    end
    local ok, err = xpcall(function()
        handler(params, done)
    end, function(e)
        trace = debug.traceback("", 2)
        return tostring(e)
    end)
    if not ok then
        fail(err)
    end
end

local server
local function ensure_server()
    if server then
        return
    end
    server = Server.new({
        host = "127.0.0.1",
        port = port,
        on_request = function(req, reply)
            UIManager:nextTick(function()
                dispatch(req, reply)
            end)
        end,
    })
    local ok, err = server:start()
    if not ok then
        logger.err("agentdriver: cannot listen on port", port, err)
        server = nil
        return
    end
    UIManager:insertZMQ(server)
    logger.info("agentdriver: listening on http://127.0.0.1:" .. port)
    io.stderr:write("agentdriver: listening on http://127.0.0.1:" .. port .. "\n")
end

local AgentDriver = WidgetContainer:extend({
    name = "agentdriver",
    is_doc_only = false,
})

function AgentDriver:init()
    Commands.Driver.ui = self.ui
    ensure_server()
end

return AgentDriver
