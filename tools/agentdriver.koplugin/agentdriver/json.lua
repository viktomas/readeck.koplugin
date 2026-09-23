-- Minimal, forgiving JSON encoder: never throws, turns anything it cannot
-- represent into a string, limits depth, and detects cycles. Tables marked
-- with Json.array() are always encoded as arrays (so {} becomes []).
local Json = {}

local ARRAY_MT = { __jsontype = "array" }

function Json.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

local escapes = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encode_string(s)
    return '"'
        .. s:gsub('[%c"\\]', function(c)
            return escapes[c] or string.format("\\u%04x", c:byte())
        end)
        .. '"'
end

local function is_array(t)
    if getmetatable(t) == ARRAY_MT then
        return true
    end
    local n = #t
    if n == 0 then
        return false
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == n
end

local function encode(v, depth, seen, out)
    local tv = type(v)
    if v == nil then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = tostring(v)
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif math.floor(v) == v and math.abs(v) < 1e15 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.14g", v)
        end
    elseif tv == "string" then
        out[#out + 1] = encode_string(v)
    elseif tv == "table" then
        if seen[v] then
            out[#out + 1] = encode_string("<cycle>")
            return
        end
        if depth <= 0 then
            out[#out + 1] = encode_string("<" .. tostring(v) .. ">")
            return
        end
        seen[v] = true
        if is_array(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then
                    out[#out + 1] = ","
                end
                encode(v[i], depth - 1, seen, out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local keys = {}
            for k in pairs(v) do
                keys[#keys + 1] = k
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            local first = true
            for _, k in ipairs(keys) do
                local val = v[k]
                if type(val) ~= "function" then
                    if not first then
                        out[#out + 1] = ","
                    end
                    first = false
                    out[#out + 1] = encode_string(tostring(k))
                    out[#out + 1] = ":"
                    encode(val, depth - 1, seen, out)
                end
            end
            out[#out + 1] = "}"
        end
        seen[v] = nil
    else
        out[#out + 1] = encode_string(tostring(v))
    end
end

function Json.encode(v, max_depth)
    local out = {}
    encode(v, max_depth or 12, {}, out)
    return table.concat(out)
end

function Json.decode(s)
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson then
        return rapidjson.decode(s)
    end
    return require("json").decode(s)
end

return Json
