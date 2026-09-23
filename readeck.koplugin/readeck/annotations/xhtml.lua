-- A minimal, tolerant (X)HTML tree builder for the chapter file of a Readeck
-- EPUB. Readeck writes that file itself (an XHTML template around article
-- HTML serialised by Go's html.Render), so it is well formed in practice; the
-- parser still copes with unclosed void elements and stray end tags instead of
-- failing. Text is kept raw (entities decoded, whitespace untouched), because
-- Readeck's annotation offsets count raw characters.
--
-- Nodes: { type = "element", name, attrs, children, parent }
--        { type = "text", text, parent }
local Xhtml = {}

local VOID_ELEMENTS = {
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

local NAMED_ENTITIES = {
    amp = 38,
    lt = 60,
    gt = 62,
    quot = 34,
    apos = 39,
    nbsp = 160,
    shy = 173,
    copy = 169,
    reg = 174,
    trade = 8482,
    hellip = 8230,
    mdash = 8212,
    ndash = 8211,
    lsquo = 8216,
    rsquo = 8217,
    ldquo = 8220,
    rdquo = 8221,
    laquo = 171,
    raquo = 187,
    bull = 8226,
    middot = 183,
    deg = 176,
    times = 215,
    euro = 8364,
    zwj = 8205,
    zwnj = 8204,
    thinsp = 8201,
    ensp = 8194,
    emsp = 8195,
}

function Xhtml.utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40
    )
end

function Xhtml.decode_entities(text)
    if not text:find("&", 1, true) then
        return text
    end
    return (
        text:gsub("&(#?[xX]?)(%w+);", function(prefix, name)
            local code
            if prefix == "#" then
                code = tonumber(name, 10)
            elseif prefix == "#x" or prefix == "#X" then
                code = tonumber(name, 16)
            elseif prefix == "" then
                code = NAMED_ENTITIES[name]
            end
            if not code or code <= 0 or code > 0x10FFFF then
                return nil -- keep the original text
            end
            return Xhtml.utf8_char(code)
        end)
    )
end

local function parse_attrs(source)
    local attrs = {}
    local pos = 1
    while true do
        local s, e, name = source:find("^%s*([^%s=/>\"']+)", pos)
        if not s then
            break
        end
        pos = e + 1
        local value = ""
        local vs, ve, quoted = source:find('^%s*=%s*"([^"]*)"', pos)
        if not vs then
            vs, ve, quoted = source:find("^%s*=%s*'([^']*)'", pos)
        end
        if not vs then
            vs, ve, quoted = source:find("^%s*=%s*([^%s>]+)", pos)
        end
        if vs then
            value = quoted
            pos = ve + 1
        end
        attrs[name:lower()] = Xhtml.decode_entities(value)
    end
    return attrs
end

local function new_element(name, attrs, parent)
    return { type = "element", name = name, attrs = attrs or {}, children = {}, parent = parent }
end

-- Returns the document node (an element named "#document").
function Xhtml.parse(source)
    source = tostring(source or "")
    local document = new_element("#document")
    local current = document
    local pos = 1
    local len = #source

    local function add_text(text)
        if text == "" then
            return
        end
        -- Literal CR LF / CR become LF before entities are decoded (HTML and XML both).
        text = Xhtml.decode_entities((text:gsub("\r\n?", "\n")))
        table.insert(current.children, { type = "text", text = text, parent = current })
    end

    while pos <= len do
        local lt = source:find("<", pos, true)
        if not lt then
            add_text(source:sub(pos))
            break
        end
        add_text(source:sub(pos, lt - 1))
        if source:sub(lt, lt + 3) == "<!--" then
            local close = source:find("-->", lt + 4, true)
            pos = close and close + 3 or len + 1
        elseif source:sub(lt, lt + 8) == "<![CDATA[" then
            local close = source:find("]]>", lt + 9, true)
            local text = source:sub(lt + 9, (close or len + 1) - 1)
            if text ~= "" then
                table.insert(current.children, { type = "text", text = text, parent = current })
            end
            pos = close and close + 3 or len + 1
        elseif source:find("^<[!?]", lt) then
            local close = source:find(">", lt + 1, true)
            pos = close and close + 1 or len + 1
        elseif source:find("^</", lt) then
            local close = source:find(">", lt + 2, true)
            local name = source:sub(lt + 2, (close or len + 1) - 1):match("^%s*([^%s>]+)")
            pos = close and close + 1 or len + 1
            if name then
                name = name:lower()
                -- Pop to the matching open element; ignore a stray end tag.
                local node = current
                while node and node ~= document and node.name ~= name do
                    node = node.parent
                end
                if node and node ~= document then
                    current = node.parent
                end
            end
        else
            -- A start tag. Attribute values may contain ">", so skip quoted runs.
            local i = lt + 1
            local quote
            while i <= len do
                local c = source:sub(i, i)
                if quote then
                    if c == quote then
                        quote = nil
                    end
                elseif c == '"' or c == "'" then
                    quote = c
                elseif c == ">" then
                    break
                end
                i = i + 1
            end
            local inner = source:sub(lt + 1, i - 1)
            pos = i + 1
            local name, rest = inner:match("^([^%s/>]+)(.*)$")
            if not name then
                add_text("<")
                pos = lt + 1
            else
                name = name:lower()
                local self_closing = rest:match("/%s*$") ~= nil
                if self_closing then
                    rest = rest:gsub("/%s*$", "")
                end
                local element = new_element(name, parse_attrs(rest), current)
                table.insert(current.children, element)
                if not (self_closing or VOID_ELEMENTS[name]) then
                    current = element
                    if name == "pre" or name == "textarea" or name == "listing" then
                        -- HTML drops one newline right after <pre>; Go and crengine both do.
                        if source:sub(pos, pos) == "\n" then
                            pos = pos + 1
                        elseif source:sub(pos, pos + 1) == "\r\n" then
                            pos = pos + 2
                        end
                    end
                end
            end
        end
    end
    return document
end

function Xhtml.find_first(node, predicate)
    for _, child in ipairs(node.children or {}) do
        if child.type == "element" then
            if predicate(child) then
                return child
            end
            local found = Xhtml.find_first(child, predicate)
            if found then
                return found
            end
        end
    end
    return nil
end

function Xhtml.has_class(element, class)
    for name in tostring(element.attrs and element.attrs.class or ""):gmatch("%S+") do
        if name == class then
            return true
        end
    end
    return false
end

return Xhtml
