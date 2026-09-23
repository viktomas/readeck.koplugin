-- Loads the PositionMap of a downloaded Readeck EPUB: finds the chapter that
-- holds the article (<main class="content">) through container.xml and the
-- OPF spine, and remembers its spine position, which is crengine's
-- DocFragment index. Works whether or not the book is open: the zip is read
-- with KOReader's ffi/archiver, or through the open crengine document.
local PositionMap = require("readeck.annotations.position_map")
local Xhtml = require("readeck.annotations.xhtml")

local EpubSource = {}

local cache = {} -- path -> { stamp, map, reason }
local cache_order = {}
local CACHE_SIZE = 4

local function url_decode(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function join(dir, href)
    href = url_decode(href:gsub("#.*$", ""))
    local parts = {}
    for part in (dir .. href):gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

local function elements(node, name, out)
    out = out or {}
    for _, child in ipairs(node.children or {}) do
        if child.type == "element" then
            -- OPF elements may carry a namespace prefix (opf:itemref).
            if child.name == name or child.name:match(":(.+)$") == name then
                table.insert(out, child)
            end
            elements(child, name, out)
        end
    end
    return out
end

-- Spine documents, in order: returns list of zip paths.
function EpubSource.spine(read)
    local container = read("META-INF/container.xml")
    if not container then
        return nil, "no_container"
    end
    local rootfile = elements(Xhtml.parse(container), "rootfile")[1]
    local opf_path = rootfile and rootfile.attrs["full-path"]
    local opf = opf_path and read(opf_path)
    if not opf then
        return nil, "no_opf"
    end
    local opf_dir = opf_path:match("^(.*/)") or ""
    local package = Xhtml.parse(opf)
    local hrefs = {}
    for _, item in ipairs(elements(package, "item")) do
        if item.attrs.id and item.attrs.href then
            hrefs[item.attrs.id] = join(opf_dir, item.attrs.href)
        end
    end
    local spine = {}
    for _, itemref in ipairs(elements(package, "itemref")) do
        local href = hrefs[itemref.attrs.idref or ""]
        if href then
            table.insert(spine, href)
        end
    end
    return spine
end

-- Builds the map from a `read(zip_path) -> content|nil` function.
function EpubSource.build(read)
    local spine, reason = EpubSource.spine(read)
    if not spine then
        return nil, reason
    end
    for index, href in ipairs(spine) do
        local source = read(href)
        if source and source:find("<main", 1, true) then
            local map = PositionMap.new(source, { doc_fragment = index })
            if map then
                return map
            end
        end
    end
    return nil, "no_article"
end

local function archive_reader(path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or not Archiver or not Archiver.Reader then
        return nil
    end
    local archive = Archiver.Reader:new()
    if not archive:open(path) then
        return nil
    end
    local files = {}
    for entry in archive:iterate() do
        local lower = entry.path:lower()
        if entry.mode == "file" and (lower:match("%.x?html?$") or lower:match("%.xml$") or lower:match("%.opf$")) then
            files[entry.path] = archive:extractToMemory(entry.path)
        end
    end
    archive:close()
    return function(name)
        return files[name]
    end
end

local function document_reader(document)
    if not (document and type(document.getDocumentFileContent) == "function") then
        return nil
    end
    return function(name)
        local ok, content = pcall(document.getDocumentFileContent, document, name)
        return ok and content or nil
    end
end

local function stamp(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then
        return ""
    end
    local attributes = lfs.attributes(path)
    if not attributes then
        return nil
    end
    return tostring(attributes.modification) .. ":" .. tostring(attributes.size)
end

local function remember(path, entry)
    if not cache[path] then
        table.insert(cache_order, path)
        if #cache_order > CACHE_SIZE then
            cache[table.remove(cache_order, 1)] = nil
        end
    end
    cache[path] = entry
end

-- The PositionMap for the EPUB at `path`, or nil and a reason. `document` is
-- the open crengine document for that path, if any (used when ffi/archiver
-- is not available).
function EpubSource.position_map(path, document)
    if type(path) ~= "string" or not path:lower():match("%.epub$") then
        return nil, "not_epub"
    end
    local current = stamp(path)
    if current == nil then
        return nil, "missing"
    end
    local cached = cache[path]
    if cached and cached.stamp == current then
        return cached.map, cached.reason
    end
    local read = archive_reader(path) or document_reader(document)
    if not read then
        return nil, "unreadable"
    end
    local ok, map, reason = pcall(EpubSource.build, read)
    if not ok then
        map, reason = nil, "parse_error"
    end
    remember(path, { stamp = current, map = map, reason = reason })
    return map, reason
end

-- Whether the EPUB at `path` has at least one readable chapter: true, false,
-- or nil when that cannot be checked (no archiver). Readeck answers 200 with
-- a chapter-less EPUB when rendering the article fails - e.g. a note's
-- footnote link shifting a later annotation's `a[n]` selector (0.22-0.23.4,
-- internal/bookmarks/converter/epub.go) - and KOReader then shows a blank
-- book that every later sync skips as already downloaded.
function EpubSource.has_chapter(path)
    local read = archive_reader(path)
    if not read then
        return nil
    end
    local spine = EpubSource.spine(read)
    for _, href in ipairs(spine or {}) do
        if read(href) then
            return true
        end
    end
    return false
end

function EpubSource.clear_cache()
    cache = {}
    cache_order = {}
end

return EpubSource
