-- Read-only probe that drives the plugin's REAL code paths against a REAL
-- Readeck server, inside the real KOReader emulator runtime.
--
-- Unlike spec/koreader_network_probe.lua (which drives spec/mock_readeck_server.py,
-- a hand-written fake), this talks to whatever server is configured via
-- READECK_URL/READECK_TOKEN (or, failing that, the emulator's own seeded
-- settings/readeck.lua). It is deliberately tolerant of whatever real data is on
-- that account: it reports what it finds instead of asserting a fixed fixture.
--
-- SAFETY: this probe must never write to the server. It only ever issues GET
-- requests via the plugin's own API/read paths (refreshServerInfo, getArticleList,
-- download, getApi():list_annotations). It must never call create_bookmark,
-- update_bookmark, delete_bookmark, create_annotation, update_annotation, or any
-- plugin function that reaches those (addArticle, addTags, removeArticle,
-- syncReadingProgress, syncHighlightsForArticle/ForPath, export helpers, etc).
-- Downloading article EPUBs to a throwaway temp dir is the only side effect, and
-- it is expected.
--
-- The auth token is never printed. The HTTP client already masks the
-- Authorization header at debug level (see readeck/net/client.lua), and this
-- probe additionally forces the log level to "info" so that masked line is not
-- even emitted.

local plugin_dir = os.getenv("READECK_PLUGIN_DIR") or arg[1]
assert(plugin_dir and plugin_dir ~= "", "READECK_PLUGIN_DIR is required")

package.path = "./?.lua;./?/init.lua;" .. plugin_dir .. "/?.lua;" .. package.path

dofile("setupkoenv.lua")
dofile("spec/front/unit/commonrequire.lua")

local Defaults = require("readeck.core.defaults")
local Features = require("readeck.core.features")
local Log = require("readeck.core.log")
local Readeck = dofile(plugin_dir .. "/main.lua")
local lfs = require("libs/libkoreader-lfs")

-- Force "info" so the masked Authorization line (only emitted at debug level)
-- never even gets built, on top of the client's own masking.
Log:setLevel("info")

-- Credentials: prefer explicit env vars, fall back to the emulator's own seeded
-- settings file (written by `mise run emulator-seed`). Never print the token.
local server_url = os.getenv("READECK_URL")
local auth_token = os.getenv("READECK_TOKEN")
if not server_url or not auth_token or server_url == "" or auth_token == "" then
    local settings_path = os.getenv("READECK_SETTINGS_FILE") or "settings/readeck.lua"
    local ok, settings = pcall(dofile, settings_path)
    if ok and type(settings) == "table" and type(settings.readeck) == "table" then
        server_url = (server_url and server_url ~= "") and server_url or settings.readeck.server_url
        auth_token = (auth_token and auth_token ~= "") and auth_token or settings.readeck.auth_token
    end
end
assert(server_url and server_url ~= "", "READECK_URL is required (or a seeded settings/readeck.lua)")
assert(auth_token and auth_token ~= "", "READECK_TOKEN is required (or a seeded settings/readeck.lua)")

local download_dir = "/tmp/readeck-live-probe-" .. tostring(os.time())
lfs.mkdir(download_dir)

local instance = setmetatable({}, { __index = Readeck })
Defaults.apply(instance)
instance.server_url = server_url
instance.auth_token = auth_token
instance.directory = download_dir
instance.log_level = "info"
instance.block_timeout = 20
instance.total_timeout = 30
instance.file_block_timeout = 20
instance.file_total_timeout = 60
instance.ui = {}
instance.rd_settings = {
    saveSetting = function() end,
    flush = function() end,
}
instance.saveSettings = function() end

print("=======================================================")
print("Readeck LIVE probe - server:", server_url)
print("Download scratch dir:", download_dir)
print("This probe is READ-ONLY: it never calls create/update/delete bookmark")
print("or create/update annotation, directly or indirectly.")
print("=======================================================")

-- 1. Auth -----------------------------------------------------------------
assert(instance:getBearerToken() == true, "API token authentication failed")
print("[auth] OK - authenticated with API token")

-- 2. Server info / version -------------------------------------------------
local info = instance:refreshServerInfo(true)
assert(type(info) == "table", "refreshServerInfo returned nothing")
local version = Features.version(info)
print("[info] server version:", version)
print("[info] features:", info.features and table.concat(info.features, ",") or "(none)")

-- 3. Feature gating against the real version -------------------------------
local notes_supported = Features.supports_annotation_notes(info)
local none_color_supported = Features.supports_annotation_none_color(info)
print("[features] supports_annotation_notes:", tostring(notes_supported))
print("[features] supports_annotation_none_color:", tostring(none_color_supported))
print(
    "[features] highlight_payload_profile:",
    "notes=" .. tostring(notes_supported),
    "none_color=" .. tostring(none_color_supported)
)

-- 4. Article list -----------------------------------------------------------
local articles = instance:getArticleList()
if type(articles) ~= "table" then
    print("[articles] getArticleList returned nil/non-table - stopping here, nothing more to probe")
    os.exit(0)
end
print("[articles] got", #articles, "article(s)")

if #articles == 0 then
    print("[articles] SKIP - account has no unarchived articles matching the sync filters; nothing to check")
    print("Live probe finished (no articles to exercise download/annotations paths).")
    os.exit(0)
end

-- Fields the plugin actually reads off an article, per
-- readeck/sync/downloads.lua, readeck/storage/metadata.lua, readeck/sync/local_actions.lua
-- and readeck/core/dates.lua: id, title, created, read_progress, labels,
-- reading_time. (is_archived/type are only ever sent as *request* filters -
-- readeck/net/api.lua bookmarks_query - the plugin never reads them back off a
-- bookmark object, so we report on them but do not assert their presence.)
local sample = articles[1]
print("[articles] sample bookmark keys:")
local keys = {}
for k in pairs(sample) do
    table.insert(keys, k)
end
table.sort(keys)
print("  " .. table.concat(keys, ", "))

local required_fields = { "id", "title" }
for _, field in ipairs(required_fields) do
    assert(sample[field] ~= nil, "real bookmark is missing required field: " .. field)
end
print("[articles] id:", sample.id, "title:", sample.title)

local consumed_but_optional = { "created", "read_progress", "labels", "reading_time", "is_archived", "type" }
for _, field in ipairs(consumed_but_optional) do
    print("  field '" .. field .. "' present:", tostring(sample[field] ~= nil), "value:", tostring(sample[field]))
end
if sample.labels ~= nil and type(sample.labels) ~= "table" then
    print("  !! WARNING: labels is present but not a table (got " .. type(sample.labels) .. ")")
end

-- 5. Download one real article EPUB -----------------------------------------
local download_result = instance:download(sample)
assert(
    download_result == Defaults.DOWNLOAD_DONE or download_result == Defaults.DOWNLOAD_SKIPPED,
    "article download did not succeed"
)
local downloaded_path = instance:findLocalArticlePathByID(tostring(sample.id))
assert(downloaded_path, "downloaded article file could not be located by ID")
assert(lfs.attributes(downloaded_path, "mode") == "file", "downloaded article path is not a file")

local file = assert(io.open(downloaded_path, "rb"))
local magic = file:read(2)
file:close()
assert(magic == "PK", "downloaded file does not look like a ZIP/EPUB (magic bytes: " .. tostring(magic) .. ")")
print("[download] OK -", downloaded_path, "(", lfs.attributes(downloaded_path, "size"), "bytes, valid ZIP magic)")

-- 6. Annotations for one real bookmark (strictly read-only: GET only) --------
local checked = 0
local found_annotations = nil
local found_article_id = nil
local max_to_check = math.min(#articles, 5)
while checked < max_to_check and not found_annotations do
    checked = checked + 1
    local candidate = articles[checked]
    local annotations, err = instance:getApi():list_annotations(candidate.id)
    if type(annotations) == "table" and #annotations > 0 then
        found_annotations = annotations
        found_article_id = candidate.id
    elseif err then
        print("[annotations] GET failed for article", candidate.id, "-", err.kind, err.code or "")
    end
end

if not found_annotations then
    print(
        "[annotations] SKIP - checked "
            .. checked
            .. " article(s), none had annotations; cannot compare real payload shape"
    )
else
    print("[annotations] found", #found_annotations, "annotation(s) on article", found_article_id)
    local sample_annotation = found_annotations[1]
    local ann_keys = {}
    for k in pairs(sample_annotation) do
        table.insert(ann_keys, k)
    end
    table.sort(ann_keys)
    print("[annotations] sample annotation keys:", table.concat(ann_keys, ", "))

    -- Fields readeck/annotations/highlights.lua's Highlights.from_remote (import
    -- path) reads off a remote annotation.
    local expected_fields = { "id", "start_selector", "start_offset", "end_selector", "end_offset", "text", "color" }
    for _, field in ipairs(expected_fields) do
        print(
            "  field '" .. field .. "' present:",
            tostring(sample_annotation[field] ~= nil),
            "value:",
            tostring(sample_annotation[field])
        )
    end
    print(
        "  field 'note' present:",
        tostring(sample_annotation.note ~= nil),
        "value:",
        tostring(sample_annotation.note)
    )
    print(
        "  field 'created' present:",
        tostring(sample_annotation.created ~= nil),
        " field 'updated' present:",
        tostring(sample_annotation.updated ~= nil)
    )
end

print("=======================================================")
print("Live probe finished - no writes were performed against", server_url)
print("=======================================================")
