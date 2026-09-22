local Errors = {}

Errors.KIND = {
    NETWORK_ERROR = "network_error",
    FILE_ERROR = "file_error",
    JSON_ERROR = "json_error",
    AUTH_PENDING = "auth_pending",
    AUTH_ERROR = "auth_error",
    HTTP_ERROR = "http_error",
    CONFIG_ERROR = "config_error",
}

-- Readeck answers failures in three different shapes, so a `message` that only
-- read `.message` would silently miss two of them:
--   400  {"status":400,"message":"element \"section/p[1]\" not found"}
--   422  {"fields":{"url":{"errors":["field is required"]}}}   -- no top-level message
--   401  plain text "Unauthorized"
local MAX_MESSAGE_LENGTH = 200

local function clean(text)
    if type(text) ~= "string" then
        return nil
    end
    text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if text == "" then
        return nil
    end
    if #text > MAX_MESSAGE_LENGTH then
        text = text:sub(1, MAX_MESSAGE_LENGTH - 1) .. "…"
    end
    return text
end

-- Field errors arrive in a hash, so sort the names to keep the message stable.
local function field_errors(fields)
    if type(fields) ~= "table" then
        return nil
    end
    local names = {}
    for name, field in pairs(fields) do
        if type(field) == "table" and type(field.errors) == "table" and #field.errors > 0 then
            table.insert(names, name)
        end
    end
    if #names == 0 then
        return nil
    end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        for _, message in ipairs(fields[name].errors) do
            if type(message) == "string" then
                table.insert(parts, name .. ": " .. message)
            end
        end
    end
    return clean(table.concat(parts, ", "))
end

-- Extract a human-readable reason from an already-decoded error payload.
function Errors.message_from_payload(payload)
    if type(payload) ~= "table" then
        return nil
    end
    return clean(payload.message) or clean(payload.error) or clean(payload.title) or field_errors(payload.fields)
end

-- KOReader's `json.decode` is a callable *table*, not a function, so a plain
-- type(...) == "function" check rejects the real decoder.
local function is_callable(value)
    if type(value) == "function" then
        return true
    end
    if type(value) == "table" then
        local mt = getmetatable(value)
        return type(mt) == "table" and mt.__call ~= nil
    end
    return false
end

-- `decode` is injected so this module stays pure and testable without the JSON library.
function Errors.message_from_body(body, decode)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local first = body:sub(1, 1)
    if first == "{" or first == "[" then
        -- Never fall through to the plain-text branch here: a body that is JSON
        -- but cannot be decoded must not be shown to the user as raw JSON.
        if not is_callable(decode) then
            return nil
        end
        local ok, payload = pcall(decode, body)
        if ok then
            return Errors.message_from_payload(payload)
        end
        return nil
    end
    -- A short, single-line, non-markup body is a usable reason ("Unauthorized").
    -- Anything longer or tag-shaped is a proxy error page, not a message for a user.
    if #body <= 80 and not body:find("[<\n\r]") then
        return clean(body)
    end
    return nil
end

function Errors.new(kind, code, status, message)
    return {
        kind = kind,
        code = code,
        status = status,
        message = message,
    }
end

return Errors
