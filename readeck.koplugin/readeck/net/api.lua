local Api = {}

local function encode_query_value(value)
    return tostring(value or ""):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function build_query(params, keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if value ~= nil and value ~= "" then
            table.insert(parts, key .. "=" .. encode_query_value(value))
        end
    end
    return table.concat(parts, "&")
end

Api.paths = {
    info = "/api/info",
    bookmarks = "/api/bookmarks",
    bookmark = function(id)
        return "/api/bookmarks/" .. tostring(id)
    end,
    bookmark_article = function(id)
        return "/api/bookmarks/" .. tostring(id) .. "/article.epub"
    end,
    annotations = function(id)
        return "/api/bookmarks/" .. tostring(id) .. "/annotations"
    end,
    annotation = function(bookmark_id, annotation_id)
        return "/api/bookmarks/" .. tostring(bookmark_id) .. "/annotations/" .. tostring(annotation_id)
    end,
}

function Api.bookmarks_query(params)
    params = params or {}
    local query = build_query(params, { "limit", "offset", "is_archived", "type", "labels", "sort" })
    if query == "" then
        return Api.paths.bookmarks
    end
    return Api.paths.bookmarks .. "?" .. query
end

function Api.new(transport)
    return setmetatable({ transport = transport }, { __index = Api })
end

function Api:request(method, path, body, headers, filepath)
    return self.transport({
        method = method,
        path = path,
        body = body,
        headers = headers,
        filepath = filepath,
    })
end

function Api:get_info()
    return self:request("GET", Api.paths.info, nil, {})
end

function Api:list_bookmarks(params)
    return self:request("GET", Api.bookmarks_query(params))
end

function Api:get_bookmark(id)
    return self:request("GET", Api.paths.bookmark(id))
end

-- Bookmark creation answers 202 with an empty body; the new id is only in a
-- `Bookmark-Id` or `Location` response header (measured against a real
-- server, work.md "Testing against reality"). Without this, the id created
-- by create_bookmark was unreachable by its callers.
local function bookmark_id_from_headers(headers)
    if type(headers) ~= "table" then
        return nil
    end
    local id = headers["bookmark-id"]
    if type(id) == "string" and id ~= "" then
        return id
    end
    local location = headers["location"]
    if type(location) == "string" then
        return location:match("/api/bookmarks/([^/]+)/?$")
    end
    return nil
end

-- Exposed for tests: pure header parsing, easy to break silently.
Api.bookmark_id_from_headers = bookmark_id_from_headers

function Api:create_bookmark(body)
    local result, err, headers = self:request("POST", Api.paths.bookmarks, body)
    if result and err == nil then
        local id = (type(result) == "table" and result.id) or bookmark_id_from_headers(headers)
        if id then
            if type(result) ~= "table" then
                result = {}
            end
            result.id = result.id or id
        end
    end
    return result, err
end

function Api:update_bookmark(id, body)
    return self:request("PATCH", Api.paths.bookmark(id), body)
end

function Api:delete_bookmark(id)
    return self:request("DELETE", Api.paths.bookmark(id))
end

-- Paths that never require (and must not trigger) an Authorization retry:
-- the info endpoint is used unauthenticated, and OAuth endpoints handle
-- their own auth flow.
function Api.is_auth_exempt_path(path)
    return path == Api.paths.info or path:sub(1, 11) == "/api/oauth/"
end

function Api:download_article(id, filepath)
    return self:request("GET", Api.paths.bookmark_article(id), nil, nil, filepath)
end

function Api:list_annotations(id)
    return self:request("GET", Api.paths.annotations(id))
end

function Api:create_annotation(id, body)
    return self:request("POST", Api.paths.annotations(id), body)
end

function Api:update_annotation(bookmark_id, annotation_id, body)
    return self:request("PATCH", Api.paths.annotation(bookmark_id, annotation_id), body)
end

return Api
