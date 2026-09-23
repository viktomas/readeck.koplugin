-- Translates between KOReader (crengine) xpointers into a Readeck EPUB and
-- Readeck annotation positions (element selector + character offset).
--
-- The two sides count differently, and all of it was measured against real
-- Readeck servers and a real crengine (see work.md, "Highlight positions"):
--
-- Readeck (pkg/annotate) resolves `section[1]/article[1]/p[2]` as an XPath
-- relative to the <body> of the stored article HTML, and the offset counts
-- Unicode code points over *all* text nodes below that element, raw: the
-- newline and indentation of a wrapped source line count.
--
-- crengine xpointers (/body/DocFragment[1]/body[1]/main[1]/section[1]/
-- article[1]/p[2]/text()[2].5) name one *text node*, and the offset counts
-- code points in that node after crengine's whitespace handling: runs of
-- space/tab/CR/LF collapse to one space at parse time, and whitespace-only
-- text nodes that sit among blocks are dropped from the DOM (so they do not
-- count in text()[n]).
--
-- The EPUB chapter is the stored article HTML inside <main class="content">
-- of a template, *plus* the annotations that existed when it was exported:
-- each annotated run is wrapped in an attribute-less <mark>, and an
-- annotation with a note gets a footnote link <a epub:type="noteref">N</a>
-- after it. Readeck's own DOM has neither, so marks are transparent here and
-- noteref links (and their text) do not exist on the Readeck side.
--
-- Everything is computed from the raw chapter XHTML, so it works when the
-- document is not open (full sync writes into sidecar files).
local Xhtml = require("readeck.annotations.xhtml")

local PositionMap = {}
PositionMap.__index = PositionMap

-- Elements crengine lays out inline by default. Everything else is a block.
local INLINE_ELEMENTS = {
    a = true,
    abbr = true,
    acronym = true,
    b = true,
    bdi = true,
    bdo = true,
    big = true,
    br = true,
    button = true,
    cite = true,
    code = true,
    data = true,
    del = true,
    dfn = true,
    em = true,
    font = true,
    i = true,
    img = true,
    input = true,
    ins = true,
    kbd = true,
    label = true,
    mark = true,
    math = true,
    q = true,
    rp = true,
    rt = true,
    ruby = true,
    s = true,
    samp = true,
    select = true,
    small = true,
    span = true,
    strike = true,
    strong = true,
    sub = true,
    sup = true,
    svg = true,
    textarea = true,
    time = true,
    tt = true,
    u = true,
    var = true,
    wbr = true,
}

local function is_space_byte(byte)
    return byte == 32 or byte == 9 or byte == 10 or byte == 13
end

-- Splits UTF-8 text into code points (the unit of both Readeck and crengine
-- offsets). Invalid bytes count as one character each.
local function chars(text)
    local list = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(list, char)
    end
    return list
end

function PositionMap.char_length(text)
    return #chars(tostring(text or ""))
end

local function is_whitespace_only(text)
    return text:find("^[ \t\r\n]*$") ~= nil
end

-- crengine's parse-time whitespace collapsing for one text node, as index
-- tables: raw_to_cre[i] = crengine chars produced by raw chars 1..i (i from 0),
-- cre_start[c] / cre_end[c] = raw range (0-based, end exclusive) of crengine char c.
local function collapse(raw_chars, pre)
    local raw_to_cre = { [0] = 0 }
    local cre_start, cre_end = {}, {}
    local count = 0
    local in_space = false
    for i, char in ipairs(raw_chars) do
        local space = not pre and #char == 1 and is_space_byte(char:byte())
        if space and in_space then
            cre_end[count] = i
        else
            count = count + 1
            cre_start[count] = i - 1
            cre_end[count] = i
        end
        in_space = space
        raw_to_cre[i] = count
    end
    return raw_to_cre, cre_start, cre_end, count
end

local function is_annotation_mark(element)
    if element.name ~= "mark" or next(element.attrs) ~= nil then
        return false
    end
    for _, child in ipairs(element.children) do
        if child.type ~= "text" then
            return false
        end
    end
    return true
end

local function is_noteref(element)
    if element.name ~= "a" then
        return false
    end
    for word in tostring(element.attrs["epub:type"] or ""):gmatch("%S+") do
        if word == "noteref" then
            return true
        end
    end
    return false
end

local function is_block(element)
    return not INLINE_ELEMENTS[element.name]
end

local function has_block_child(element)
    for _, child in ipairs(element.children) do
        if child.type == "element" and is_block(child) then
            return true
        end
    end
    return false
end

-- Does crengine keep this text node in its DOM?
local function crengine_keeps(node, index_in_parent, pre)
    if pre or not is_whitespace_only(node.text) then
        return true
    end
    local parent = node.parent
    if is_block(parent) then
        if index_in_parent == 1 then
            return false -- first whitespace of a block, dropped while parsing
        end
        if has_block_child(parent) then
            return false -- whitespace among blocks, removed when autoboxing
        end
    end
    return true
end

-- Builds the map from the chapter XHTML. `options.doc_fragment` is the
-- chapter's DocFragment index in the EPUB (its spine position, default 1).
function PositionMap.new(source, options)
    options = options or {}
    local document = Xhtml.parse(source)
    local body = Xhtml.find_first(document, function(e)
        return e.name == "body"
    end)
    if not body then
        return nil, "no_body"
    end
    local root = Xhtml.find_first(body, function(e)
        return e.name == "main" and Xhtml.has_class(e, "content")
    end) or Xhtml.find_first(body, function(e)
        return e.name == "main"
    end)
    if not root then
        return nil, "no_article"
    end
    local title_element = Xhtml.find_first(document, function(e)
        return e.name == "title"
    end)

    local self = setmetatable({
        body = body,
        root = root,
        doc_fragment = tonumber(options.doc_fragment) or 1,
        pieces = {}, -- text nodes below root, document order
        title = title_element and title_element.children[1] and title_element.children[1].text or nil,
    }, PositionMap)
    self:_index(body, false, false, false)
    return self
end

-- Walks the tree once, assigning crengine indexes (cre_index, cre_children,
-- text()[k]), Readeck indexes (rd_index) and the Readeck text position
-- (rd_start / rd_end: code points of Readeck-visible text before / through).
function PositionMap:_index(element, inside_root, pre, in_noteref)
    local total = self._total or 0
    element.rd_start = total
    local name_counts, rd_counts = {}, {}
    local text_count = 0
    element.cre_children = {}
    for index, child in ipairs(element.children) do
        if child.type == "element" then
            name_counts[child.name] = (name_counts[child.name] or 0) + 1
            child.cre_index = name_counts[child.name]
            child.is_mark = is_annotation_mark(child)
            child.is_noteref = in_noteref or is_noteref(child)
            if not (child.is_mark or child.is_noteref) then
                rd_counts[child.name] = (rd_counts[child.name] or 0) + 1
                child.rd_index = rd_counts[child.name]
            end
            table.insert(element.cre_children, child)
            self:_index(child, inside_root or child == self.root, pre or child.name == "pre", child.is_noteref)
        else
            local child_pre = pre
            child.kept = crengine_keeps(child, index, child_pre)
            child.chars = chars(child.text)
            child.length = #child.chars
            if child.kept then
                text_count = text_count + 1
                child.cre_k = text_count
                child.raw_to_cre, child.cre_start, child.cre_end, child.cre_length = collapse(child.chars, child_pre)
                table.insert(element.cre_children, child)
            end
            if inside_root then
                child.counted = not in_noteref
                child.rd_start = self._total or 0
                if child.counted then
                    self._total = (self._total or 0) + child.length
                end
                table.insert(self.pieces, child)
            end
        end
    end
    element.rd_end = self._total or total
end

-- Nearest ancestor that exists in Readeck's DOM (marks are transparent,
-- noteref links do not exist there).
local function readeck_parent(node)
    local parent = node.parent
    while parent and (parent.is_mark or parent.is_noteref) do
        parent = parent.parent
    end
    return parent
end

function PositionMap:readeck_selector(element)
    local steps = {}
    local node = element
    while node and node ~= self.root do
        if not node.rd_index then
            return nil
        end
        table.insert(steps, 1, node.name .. "[" .. node.rd_index .. "]")
        node = node.parent
    end
    if node ~= self.root or #steps == 0 then
        return nil
    end
    return table.concat(steps, "/")
end

function PositionMap:resolve_selector(selector)
    selector = tostring(selector or ""):gsub("^%./", ""):gsub("^/", "")
    if selector == "" then
        return nil
    end
    local node = self.root
    for step in selector:gmatch("[^/]+") do
        local name, index = step:match("^([%w%-_:]+)%[(%d+)%]$")
        if not name then
            name, index = step:match("^([%w%-_:]+)$"), 1
        end
        if not name then
            return nil
        end
        name, index = name:lower(), tonumber(index)
        local found
        for _, child in ipairs(node.children) do
            if child.type == "element" and child.name == name and child.rd_index == index then
                found = child
                break
            end
        end
        if not found then
            return nil
        end
        node = found
    end
    return node
end

-- Readeck (selector, offset) -> position in the whole article's Readeck text.
function PositionMap:readeck_to_global(selector, offset)
    local element = self:resolve_selector(selector)
    offset = tonumber(offset)
    if not element or not offset or offset < 0 or offset > element.rd_end - element.rd_start then
        return nil
    end
    return element.rd_start + offset
end

-- The text piece a boundary at global position `g` belongs to, among the
-- pieces that exist on both sides. A start prefers the piece that begins at
-- g, an end the piece that finishes there (so a highlight never starts at the
-- end of one node or ends at the start of the next).
function PositionMap:_piece_at(g, is_end)
    if is_end then
        local best
        for _, piece in ipairs(self.pieces) do
            if piece.counted and piece.kept and piece.length > 0 then
                if piece.rd_start < g then
                    best = piece
                else
                    break
                end
            end
        end
        if best then
            return best, math.min(g - best.rd_start, best.length)
        end
    end
    for _, piece in ipairs(self.pieces) do
        if piece.counted and piece.kept and piece.length > 0 and piece.rd_start + piece.length > g then
            return piece, math.max(g - piece.rd_start, 0)
        end
    end
    return nil
end

function PositionMap:crengine_path(element)
    local steps = {}
    local node = element
    while node and node ~= self.body do
        if not node.cre_index then
            return nil
        end
        table.insert(steps, 1, node.name .. "[" .. node.cre_index .. "]")
        node = node.parent
    end
    if node ~= self.body then
        return nil
    end
    local path = "/body/DocFragment[" .. self.doc_fragment .. "]/body[1]"
    if #steps > 0 then
        path = path .. "/" .. table.concat(steps, "/")
    end
    return path
end

local function piece_xpointer(self, piece, raw_offset, is_end)
    local cre_offset = piece.raw_to_cre[raw_offset]
    if cre_offset == nil then
        return nil
    end
    if not is_end and raw_offset > 0 and cre_offset > 0 and piece.cre_end[cre_offset] > raw_offset then
        -- A start inside a collapsed whitespace run: start at that space.
        cre_offset = cre_offset - 1
    end
    local path = self:crengine_path(piece.parent)
    if not path then
        return nil
    end
    return path .. "/text()[" .. piece.cre_k .. "]." .. cre_offset
end

-- Readeck (selector, offset) -> crengine xpointer.
function PositionMap:to_xpointer(selector, offset, is_end)
    local g = self:readeck_to_global(selector, offset)
    if not g then
        return nil, "not_found"
    end
    local piece, raw_offset = self:_piece_at(g, is_end)
    if not piece then
        return nil, "not_found"
    end
    local xpointer = piece_xpointer(self, piece, raw_offset, is_end)
    if not xpointer then
        return nil, "not_found"
    end
    return xpointer
end

-- Parses a crengine xpointer into steps; accepts the explicit-index form
-- (/body[1]/DocFragment[1]/...) and the older bare form (/body/DocFragment/...).
local function parse_xpointer(xpointer)
    local path, offset = tostring(xpointer or ""):match("^(.-)%.(%d+)$")
    if not path then
        path, offset = tostring(xpointer or ""), 0
    end
    local steps = {}
    for step in path:gmatch("[^/]+") do
        local name, index = step:match("^(.-)%[(%d+)%]$")
        if not name then
            name, index = step, 1
        end
        table.insert(steps, { name = name:lower(), index = tonumber(index) })
    end
    return steps, tonumber(offset)
end

-- crengine xpointer -> (global Readeck position, the piece it lies in).
function PositionMap:xpointer_to_global(xpointer, is_end)
    local steps, offset = parse_xpointer(xpointer)
    if #steps < 3 or steps[1].name ~= "body" or steps[2].name ~= "docfragment" or steps[3].name ~= "body" then
        return nil
    end
    if steps[2].index ~= self.doc_fragment then
        return nil
    end
    local node = self.body
    for i = 4, #steps do
        local step = steps[i]
        local found
        if step.name == "text()" then
            for _, child in ipairs(node.children or {}) do
                if child.type == "text" and child.kept and child.cre_k == step.index then
                    found = child
                    break
                end
            end
        else
            for _, child in ipairs(node.children or {}) do
                if child.type == "element" and child.name == step.name and child.cre_index == step.index then
                    found = child
                    break
                end
            end
        end
        if not found or (found.type == "text" and i ~= #steps) then
            return nil
        end
        node = found
    end

    if node.type == "text" then
        if node.rd_start == nil then
            return nil -- outside the article
        end
        if not node.counted then
            return node.rd_start, node
        end
        if offset > node.cre_length then
            return nil
        end
        local raw
        if offset == 0 then
            raw = 0
        elseif is_end then
            raw = node.cre_end[offset]
        elseif offset >= node.cre_length then
            raw = node.length
        else
            raw = node.cre_start[offset + 1]
        end
        return node.rd_start + raw, node
    end

    -- An element xpointer: the offset is a child index in crengine's DOM.
    if node.rd_start == nil or not (node == self.root or self:_inside_root(node)) then
        return nil
    end
    local child = node.cre_children[offset + 1]
    if child then
        return child.rd_start, child
    end
    return node.rd_end, node
end

function PositionMap:_inside_root(node)
    local parent = node.parent
    while parent do
        if parent == self.root then
            return true
        end
        parent = parent.parent
    end
    return false
end

-- crengine xpointer -> Readeck selector, offset.
function PositionMap:to_readeck(xpointer, is_end)
    local g = self:xpointer_to_global(xpointer, is_end)
    if not g then
        return nil, nil, "not_found"
    end
    local piece = self:_piece_at(g, is_end)
    if not piece then
        return nil, nil, "not_found"
    end
    if is_end then
        g = math.min(math.max(g, piece.rd_start), piece.rd_start + piece.length)
    else
        g = math.max(math.min(g, piece.rd_start + piece.length), piece.rd_start)
    end
    local element = readeck_parent(piece)
    local selector = element and self:readeck_selector(element)
    if not selector then
        return nil, nil, "not_found"
    end
    return selector, g - element.rd_start
end

-- Readeck-visible text between two global positions (for checks and tests).
function PositionMap:readeck_text(g0, g1)
    local out = {}
    for _, piece in ipairs(self.pieces) do
        if piece.counted then
            local s = math.max(g0 - piece.rd_start, 0)
            local e = math.min(g1 - piece.rd_start, piece.length)
            for i = s + 1, e do
                table.insert(out, piece.chars[i])
            end
        end
    end
    return table.concat(out)
end

return PositionMap
