-- Minimal, independent Readeck API client used by tests to set up and to
-- verify server state. Deliberately shares no code with the plugin's own HTTP
-- client, so a bug there cannot make a test pass.
--
-- Refuses to talk to anything but a loopback address: the suite must never
-- touch a real server, whatever READECK_URL the calling shell exported.

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")

local ReadeckApi = {}
ReadeckApi.__index = ReadeckApi

function ReadeckApi.assert_local_url(url)
    local host = tostring(url or ""):match("^https?://([^/:]+)")
    assert(
        host == "127.0.0.1" or host == "localhost" or host == "[::1]",
        "refusing to use non-local Readeck URL: " .. tostring(url)
    )
end

function ReadeckApi.new(base_url, token)
    ReadeckApi.assert_local_url(base_url)
    return setmetatable({ base_url = base_url, token = token }, ReadeckApi)
end

local function encode_query(params)
    if not params then
        return ""
    end
    local keys = {}
    for key in pairs(params) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = tostring(params[key]):gsub("([^%w%-%._~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        table.insert(parts, key .. "=" .. value)
    end
    return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

-- Returns status (number), decoded body (table/string/nil), headers, raw body.
function ReadeckApi:request(method, path, body, opts)
    opts = opts or {}
    local sink = {}
    local headers = {
        ["Accept"] = opts.accept or "application/json",
    }
    if self.token and not opts.no_auth then
        headers["Authorization"] = "Bearer " .. self.token
    end
    local source
    if body ~= nil then
        local encoded = type(body) == "string" and body or JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#encoded)
        source = ltn12.source.string(encoded)
    end
    local _, code, resp_headers = http.request({
        method = method,
        url = self.base_url .. path,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    local raw = table.concat(sink)
    local decoded = raw
    local first = raw:sub(1, 1)
    if first == "{" or first == "[" then
        local ok, value = pcall(JSON.decode, raw)
        if ok then
            decoded = value
        end
    end
    return tonumber(code) or code, decoded, resp_headers or {}, raw
end

function ReadeckApi:expect(expected_status, method, path, body)
    local status, decoded, headers, raw = self:request(method, path, body)
    if status ~= expected_status then
        local reason = raw:sub(1, 300)
        if type(decoded) == "table" and type(decoded.fields) == "table" then
            -- Readeck's 422 form shape: only report the fields that carry errors.
            local parts = {}
            for name, field in pairs(decoded.fields) do
                if type(field) == "table" and type(field.errors) == "table" then
                    table.insert(parts, name .. ": " .. table.concat(field.errors, ", "))
                end
            end
            reason = table.concat(parts, "; ")
        end
        error(string.format("%s %s: expected HTTP %s, got %s: %s", method, path, expected_status, status, reason), 2)
    end
    return decoded, headers
end

function ReadeckApi:info()
    return self:expect(200, "GET", "/api/info")
end

-- All bookmarks (archived included) unless params narrow it down.
function ReadeckApi:list_bookmarks(params)
    params = params or {}
    params.limit = params.limit or 100
    return self:expect(200, "GET", "/api/bookmarks" .. encode_query(params))
end

function ReadeckApi:get_bookmark(id)
    local status, decoded = self:request("GET", "/api/bookmarks/" .. id)
    if status == 404 then
        return nil
    end
    assert(status == 200, "GET bookmark " .. id .. " -> " .. tostring(status))
    return decoded
end

-- Creates a bookmark and returns its id (Readeck answers 202 with the id in a header).
function ReadeckApi:create_bookmark(url, labels, title)
    -- KOReader's JSON encodes an empty table as {}, which Readeck rejects for a list.
    local body = { url = url, title = title }
    if labels and #labels > 0 then
        body.labels = labels
    end
    local _, headers = self:expect(202, "POST", "/api/bookmarks", body)
    local id = headers["bookmark-id"] or headers["Bookmark-Id"]
    assert(id and id ~= "", "no Bookmark-Id header in create response")
    return id
end

function ReadeckApi:wait_loaded(id, timeout)
    local deadline = socket.gettime() + (timeout or 30)
    while socket.gettime() < deadline do
        local bookmark = self:get_bookmark(id)
        if bookmark and bookmark.loaded and bookmark.state == 0 then
            return bookmark
        end
        if bookmark and bookmark.state == 1 then
            error("bookmark " .. id .. " failed to load on the server")
        end
        socket.sleep(0.1)
    end
    error("bookmark " .. id .. " did not finish loading within " .. tostring(timeout or 30) .. "s")
end

function ReadeckApi:update_bookmark(id, body)
    return self:expect(200, "PATCH", "/api/bookmarks/" .. id, body)
end

function ReadeckApi:delete_bookmark(id)
    return self:expect(204, "DELETE", "/api/bookmarks/" .. id)
end

function ReadeckApi:annotations(id)
    return self:expect(200, "GET", "/api/bookmarks/" .. id .. "/annotations")
end

function ReadeckApi:create_annotation(id, payload)
    return self:expect(201, "POST", "/api/bookmarks/" .. id .. "/annotations", payload)
end

function ReadeckApi:update_annotation(id, annotation_id, payload)
    return self:expect(200, "PATCH", "/api/bookmarks/" .. id .. "/annotations/" .. annotation_id, payload)
end

function ReadeckApi:delete_annotation(id, annotation_id)
    return self:expect(204, "DELETE", "/api/bookmarks/" .. id .. "/annotations/" .. annotation_id)
end

function ReadeckApi:article_html(id)
    local status, _, _, raw = self:request("GET", "/api/bookmarks/" .. id .. "/article", nil, { accept = "text/html" })
    assert(status == 200, "GET article " .. id .. " -> " .. tostring(status))
    return raw
end

return ReadeckApi
