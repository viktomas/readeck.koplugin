-- Tiny HTTP/1.0 server polled from UIManager's ZMQ hook.
--
-- Unlike ui/message/simpletcpserver it reads request bodies, never answers
-- inside waitEvent(), and keeps the client socket so the answer can be sent
-- later - after the UI has settled - from a scheduled task.
local socket = require("socket")
local logger = require("logger")

local Server = {}
Server.__index = Server

local function url_decode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function parse_query(q, into)
    into = into or {}
    if not q or q == "" then
        return into
    end
    for pair in q:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then
            into[url_decode(k)] = url_decode(v or "")
        end
    end
    return into
end

function Server.new(opts)
    local o = setmetatable({
        host = opts.host or "127.0.0.1",
        port = opts.port,
        on_request = opts.on_request,
    }, Server)
    return o
end

function Server:start()
    local server, err = socket.bind(self.host, self.port)
    if not server then
        return false, err
    end
    server:settimeout(0)
    self.server = server
    return true
end

function Server:stop()
    if self.server then
        self.server:close()
        self.server = nil
    end
end

local function read_request(client)
    client:settimeout(2)
    local line, err = client:receive("*l")
    if not line then
        return nil, err
    end
    local method, target = line:match("^(%u+)%s+(%S+)")
    if not method then
        return nil, "bad request line"
    end
    local headers = {}
    while true do
        local h = client:receive("*l")
        if not h or h == "" then
            break
        end
        local k, v = h:match("^([^:]+):%s*(.*)$")
        if k then
            headers[k:lower()] = v
        end
    end
    local body = ""
    local len = tonumber(headers["content-length"] or "0") or 0
    if len > 0 then
        body = client:receive(len) or ""
    end
    local path, query = target:match("^([^?]*)%??(.*)$")
    local params = parse_query(query)
    local ctype = headers["content-type"] or ""
    if body ~= "" then
        if ctype:find("application/x-www-form-urlencoded", 1, true) then
            parse_query(body, params)
        elseif ctype:find("json", 1, true) then
            local ok, decoded = pcall(require("agentdriver/json").decode, body)
            if ok and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    params[k] = v
                end
            end
        end
    end
    return {
        method = method,
        path = path,
        params = params,
        body = body,
        headers = headers,
    }
end

-- Called by UIManager:processZMQs() as an iterator: must return nil.
function Server:waitEvent()
    if not self.server then
        return nil
    end
    for _ = 1, 8 do
        local client = self.server:accept()
        if not client then
            break
        end
        local ok, req = pcall(read_request, client)
        if ok and req then
            local reply = function(status, content_type, body)
                self:send(client, status, content_type, body)
            end
            self.on_request(req, reply)
        else
            logger.warn("agentdriver: bad request", req)
            pcall(client.close, client)
        end
    end
    return nil
end

local STATUS = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found", [500] = "Internal Server Error" }

function Server:send(client, status, content_type, body)
    body = body or ""
    local head = table.concat({
        string.format("HTTP/1.0 %d %s", status, STATUS[status] or "Unknown"),
        "Content-Type: " .. (content_type or "application/json"),
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        "",
    }, "\r\n")
    client:settimeout(10)
    pcall(client.send, client, head .. body)
    pcall(client.close, client)
end

return Server
