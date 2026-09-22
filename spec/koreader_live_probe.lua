-- Read-only probe that drives the plugin's REAL code paths against a REAL
-- Readeck server, inside the real KOReader emulator runtime.
--
-- Unlike spec/koreader_network_probe.lua (which drives spec/mock_readeck_server.py,
-- a hand-written fake), this talks to whatever server is configured via
-- READECK_URL/READECK_TOKEN (or, failing that, the emulator's own seeded
-- settings/readeck.lua). It is deliberately tolerant of whatever real data is on
-- that account: it reports what it finds instead of asserting a fixed fixture.
--
-- SAFETY (default / READECK_LIVE_WRITE unset): this probe must never write to
-- the server. It only ever issues GET requests via the plugin's own API/read
-- paths (refreshServerInfo, getArticleList, download, getApi():list_annotations).
-- It must never call create_bookmark, update_bookmark, delete_bookmark,
-- create_annotation, update_annotation, or any plugin function that reaches
-- those (addArticle, addTags, removeArticle, syncReadingProgress,
-- syncHighlightsForArticle/ForPath, export helpers, etc). Downloading article
-- EPUBs to a throwaway temp dir is the only side effect, and it is expected.
--
-- OPT-IN WRITE MODE (READECK_LIVE_WRITE=1): appended at the end of this file,
-- entirely gated behind that env var, off by default. It creates exactly one
-- bookmark from a harmless public URL, waits for it to become downloadable,
-- exports/updates one highlight on it via the plugin's real export and
-- linked-sync PATCH paths, and deletes that same bookmark again before
-- exiting - see the comment above that block for the runtime safety guard
-- that enforces "only the bookmark this run created, never anything else".
-- Do not point this at a real account without the account owner's explicit
-- sign-off for this run; prefer running it against spec/mock_readeck_server.py
-- first (see the emulator-live-probe-write mise task).
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

-- =====================================================================
-- OPT-IN WRITE MODE (READECK_LIVE_WRITE=1)
--
-- Off by default; everything above this point already ran and was strictly
-- read-only regardless of this flag. When enabled, this section creates one
-- bookmark, verifies the annotation round-trip on it, and deletes it again.
--
-- SAFETY GUARD (enforced in code, not just documented): every write call
-- from this point on goes through `guarded_api`, a thin wrapper around the
-- plugin's real Api object. Reads pass through untouched via `__index`.
-- Writes that take a bookmark id (update_bookmark, delete_bookmark,
-- create_annotation, update_annotation) hard-assert that id equals
-- `created_id`, the id of the one bookmark this run created; a mismatch
-- raises immediately instead of making the request. `create_bookmark` itself
-- asserts it is only ever called once per run. The whole write sequence runs
-- inside `pcall`; cleanup (deleting the created bookmark) always runs
-- afterwards, success or failure, and re-raises the original error if there
-- was one. If cleanup itself fails, the bookmark id is printed loudly so it
-- can be removed by hand.
-- =====================================================================
if os.getenv("READECK_LIVE_WRITE") == "1" then
    local socket = require("socket")

    print("=======================================================")
    print("WRITE MODE ENABLED (READECK_LIVE_WRITE=1) - server:", server_url)
    print("This run WILL create one bookmark, export/update one highlight on")
    print("it, and delete that same bookmark before exiting. It hard-refuses")
    print("(runtime assertion) to touch any other bookmark id.")
    print("=======================================================")

    local real_api = instance:getApi()
    local created_id = nil
    local create_bookmark_called = false

    local function assert_own_bookmark(id, action)
        assert(created_id ~= nil, "safety guard: refusing to " .. action .. " before a bookmark was created")
        assert(
            tostring(id) == tostring(created_id),
            "SAFETY GUARD TRIPPED: refusing to "
                .. action
                .. " bookmark id "
                .. tostring(id)
                .. " - this run only ever created id "
                .. tostring(created_id)
        )
    end

    local guarded_api = setmetatable({}, { __index = real_api })

    function guarded_api:create_bookmark(body)
        assert(not create_bookmark_called, "safety guard: create_bookmark already called once this run")
        create_bookmark_called = true
        return real_api:create_bookmark(body)
    end

    function guarded_api:update_bookmark(id, body)
        assert_own_bookmark(id, "update_bookmark")
        return real_api:update_bookmark(id, body)
    end

    function guarded_api:delete_bookmark(id)
        assert_own_bookmark(id, "delete_bookmark")
        return real_api:delete_bookmark(id)
    end

    function guarded_api:create_annotation(id, body)
        assert_own_bookmark(id, "create_annotation")
        return real_api:create_annotation(id, body)
    end

    function guarded_api:update_annotation(bookmark_id, annotation_id, body)
        assert_own_bookmark(bookmark_id, "update_annotation")
        return real_api:update_annotation(bookmark_id, annotation_id, body)
    end

    -- From here on, every plugin method that calls self:getApi() (addArticle,
    -- exportHighlightsForArticle, LinkedSync.sync, ...) gets the guarded
    -- wrapper instead of the real one.
    instance.getApi = function()
        return guarded_api
    end

    math.randomseed(os.time())
    local test_url = "https://example.com/?readeck-koplugin-write-probe="
        .. tostring(os.time())
        .. "-"
        .. tostring(math.random(100000, 999999))

    local ok, run_err = pcall(function()
        local before_ids = {}
        local before_list = instance:getApi():list_bookmarks({})
        if type(before_list) == "table" then
            for _, bookmark in ipairs(before_list) do
                before_ids[tostring(bookmark.id)] = true
            end
        end

        print("[write] creating bookmark from", test_url)
        local create_result, create_err = instance:addArticle(test_url)
        assert(create_result, "addArticle failed: " .. tostring(create_err and create_err.kind))
        if type(create_result) == "table" then
            local create_keys = {}
            for k in pairs(create_result) do
                table.insert(create_keys, k)
            end
            table.sort(create_keys)
            print("[write] create_bookmark response keys:", table.concat(create_keys, ", "))
            for _, k in ipairs(create_keys) do
                print("  " .. k .. " =", tostring(create_result[k]))
            end
        else
            print("[write] create_bookmark response:", tostring(create_result))
        end

        -- Real Readeck returns the new bookmark's id via the Bookmark-Id /
        -- Location response headers, not the JSON body - and the plugin's
        -- HTTP client (readeck/net/client.lua) does not surface response
        -- headers to callers at all. So, exactly like the plugin's own sync
        -- loop would have to, we discover the id by listing bookmarks and
        -- matching the URL we just submitted (and double-check it is not an
        -- id that already existed before we created anything).
        local discover_deadline = socket.gettime() + 10
        local discovered
        while not discovered and socket.gettime() < discover_deadline do
            local list, list_err = instance:getApi():list_bookmarks({})
            if type(list) == "table" then
                for _, bookmark in ipairs(list) do
                    if bookmark.url == test_url and not before_ids[tostring(bookmark.id)] then
                        discovered = bookmark
                        break
                    end
                end
            elseif list_err then
                print("[write] list_bookmarks failed while discovering new id:", list_err.kind, list_err.code or "")
            end
            if not discovered then
                socket.sleep(0.3)
            end
        end
        assert(discovered, "could not find the bookmark this run just created by matching its URL")
        assert(discovered.id, "discovered bookmark has no id")
        created_id = discovered.id
        print("[write] created bookmark id (BEFORE further steps):", created_id)

        -- Poll for the article to become downloadable. The plugin's own
        -- download() (readeck/sync/downloads.lua) does not poll or retry on
        -- its own - it just issues one GET for article.epub - so this loop
        -- is standing in for whatever polling the plugin itself would need
        -- to do, and timing how long a real conversion actually takes.
        local download_timeout = tonumber(os.getenv("READECK_LIVE_WRITE_DOWNLOAD_TIMEOUT")) or 60
        local download_deadline = socket.gettime() + download_timeout
        local download_start = socket.gettime()
        local write_download_result
        local last_seen
        repeat
            write_download_result = instance:download(discovered)
            if write_download_result ~= Defaults.DOWNLOAD_DONE then
                socket.sleep(1)
                local refreshed = instance:getApi():list_bookmarks({})
                if type(refreshed) == "table" then
                    for _, bookmark in ipairs(refreshed) do
                        if tostring(bookmark.id) == tostring(created_id) then
                            discovered = bookmark
                            last_seen = bookmark
                        end
                    end
                end
            end
        until write_download_result == Defaults.DOWNLOAD_DONE or socket.gettime() > download_deadline
        local elapsed = socket.gettime() - download_start
        if write_download_result == Defaults.DOWNLOAD_DONE then
            print(string.format("[write] article became downloadable after %.1fs", elapsed))
        else
            print(string.format("[write] article NEVER became downloadable within %.1fs timeout", download_timeout))
            if last_seen then
                print(
                    "  last known state/loaded/has_article:",
                    tostring(last_seen.state),
                    tostring(last_seen.loaded),
                    tostring(last_seen.has_article)
                )
            end
        end
        assert(write_download_result == Defaults.DOWNLOAD_DONE, "article never became downloadable within timeout")

        -- Export one highlight via the plugin's real export path.
        local local_highlight = {
            drawer = "lighten",
            text = "write-probe text",
            note = "write-probe note",
            color = "none",
            pos0 = "section/p[1].0",
            pos1 = "section/p[1].16",
        }
        local export_ok, export_counts = instance:exportHighlightsForArticle(
            created_id,
            { local_highlight },
            { quiet = true }
        )
        assert(export_ok, "exportHighlightsForArticle failed (counts.error=" .. tostring(export_counts.error) .. ")")
        assert(local_highlight.readeck_annotation_id, "export did not record a readeck_annotation_id")
        print("[write] exported highlight, remote annotation id:", local_highlight.readeck_annotation_id)

        local annotations_after_export, list_err = instance:getApi():list_annotations(created_id)
        assert(
            type(annotations_after_export) == "table",
            "list_annotations after export failed: " .. tostring(list_err and list_err.kind)
        )
        local remote_annotation
        for _, a in ipairs(annotations_after_export) do
            if tostring(a.id) == tostring(local_highlight.readeck_annotation_id) then
                remote_annotation = a
            end
        end
        assert(remote_annotation, "could not find the exported annotation when reading it back")

        print("[write] REAL annotation payload, field by field:")
        local ann_keys = {}
        for k in pairs(remote_annotation) do
            table.insert(ann_keys, k)
        end
        table.sort(ann_keys)
        for _, k in ipairs(ann_keys) do
            print("  " .. k .. " =", tostring(remote_annotation[k]))
        end

        -- Fields readeck/annotations/highlights.lua's remote_to_local_annotation
        -- (import path) reads off a remote annotation.
        local expected_fields =
            { "id", "start_selector", "start_offset", "end_selector", "end_offset", "text", "color", "note" }
        for _, field in ipairs(expected_fields) do
            print(
                "  expected-by-highlights.lua field '" .. field .. "' present:",
                tostring(remote_annotation[field] ~= nil)
            )
        end

        local profile = instance:getHighlightPayloadProfile()
        print(
            "[write] highlight payload profile used for export: notes="
                .. tostring(profile.notes)
                .. " none_color="
                .. tostring(profile.none_color)
        )
        if profile.notes then
            print("  note round-tripped exactly:", remote_annotation.note == "write-probe note")
        end
        if profile.none_color then
            print("  'none' color sent, round-tripped as:", tostring(remote_annotation.color))
        end

        -- Update it via the linked_sync PATCH path (readeck/annotations/linked_sync.lua).
        local_highlight.color = "green"
        local_highlight.note = "write-probe note (updated)"
        local update_ok, update_counts = instance:exportHighlightsForArticle(
            created_id,
            { local_highlight },
            { quiet = true }
        )
        assert(update_ok, "linked update via exportHighlightsForArticle failed")
        assert(
            (update_counts.updated_remote or 0) >= 1,
            "expected the linked update to PATCH the remote annotation, got updated_remote="
                .. tostring(update_counts.updated_remote)
        )
        print("[write] PATCHed annotation via linked_sync, updated_remote count:", update_counts.updated_remote)

        local annotations_after_update, list_err2 = instance:getApi():list_annotations(created_id)
        assert(
            type(annotations_after_update) == "table",
            "list_annotations after update failed: " .. tostring(list_err2 and list_err2.kind)
        )
        local updated_remote_annotation
        for _, a in ipairs(annotations_after_update) do
            if tostring(a.id) == tostring(local_highlight.readeck_annotation_id) then
                updated_remote_annotation = a
            end
        end
        assert(updated_remote_annotation, "could not find the updated annotation when reading it back")
        print(
            "[write] annotation after PATCH: color="
                .. tostring(updated_remote_annotation.color)
                .. " note="
                .. tostring(updated_remote_annotation.note)
        )
        assert(updated_remote_annotation.color == "green", "PATCH did not change color as expected")
        if profile.notes then
            assert(
                updated_remote_annotation.note == "write-probe note (updated)",
                "PATCH did not change note as expected"
            )
        end

        print("[write] all write-mode verification checks passed.")
    end)

    print("[write] cleanup: deleting bookmark id (AFTER all steps):", tostring(created_id))
    if created_id then
        local cleanup_ok, cleanup_result = pcall(function()
            return guarded_api:delete_bookmark(created_id)
        end)
        if cleanup_ok and cleanup_result then
            print("[write] cleanup OK - deleted bookmark", created_id)
        else
            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
            print("!! CLEANUP FAILED - bookmark " .. tostring(created_id) .. " was NOT deleted.")
            print("!! Delete it by hand on " .. tostring(server_url))
            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
        end
    else
        print("[write] no bookmark was ever created (failed before discovery) - nothing to delete")
    end

    if not ok then
        error(run_err, 0)
    end

    print("=======================================================")
    print("Write-mode verification finished successfully against", server_url)
    print("=======================================================")
end
