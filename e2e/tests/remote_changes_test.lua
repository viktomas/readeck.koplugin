-- Changes made on the server (archive, delete) and how a sync reflects them locally.
local H = ...

local REMOVE_MISSING = { "Readeck", "Settings", "Article actions", "Remove local files missing from Readeck" }

local function sync_two(fm)
    local ids = { H.seed_page("lighthouse.html"), H.seed_page("bread.html") }
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 2")
    return ids
end

H.test("archived on the server + remove-missing on: local file removed", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local ids = sync_two(fm)
    H.set_menu_checkbox(fm, REMOVE_MISSING, true)

    H.api:update_bookmark(ids[1], { is_archived = true })
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Removed from KOReader: 1")
    H.falsy(H.local_article_by_id(ids[1]), "archived article removed locally")
    H.truthy(H.local_article_by_id(ids[2]), "other article kept")
    H.truthy(H.api:get_bookmark(ids[1]), "the plugin did not touch the archived bookmark")
end)

H.test("archived on the server + remove-missing off: local file kept", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local ids = sync_two(fm)
    H.eq(H.menu_checked(fm, REMOVE_MISSING), false, "off by default")

    H.api:update_bookmark(ids[1], { is_archived = true })
    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Removed from KOReader")
    H.truthy(H.local_article_by_id(ids[1]), "archived article kept locally")
    H.eq(#H.local_articles(), 2)
end)

H.test("deleted on the server + remove-missing on: local file and sidecar removed", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local ids = sync_two(fm)
    H.set_menu_checkbox(fm, REMOVE_MISSING, true)
    local path = H.local_article_by_id(ids[2]).path
    H.set_book_status(path, "reading") -- creates a sidecar

    H.api:delete_bookmark(ids[2])
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Removed from KOReader: 1")
    H.falsy(H.local_article_by_id(ids[2]), "deleted article removed locally")
    H.falsy(require("docsettings"):hasSidecarFile(path), "sidecar removed with the file")
    H.truthy(H.local_article_by_id(ids[1]), "other article kept")
end)

H.test("deleted on the server + remove-missing off: local file kept", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local ids = sync_two(fm)
    H.api:delete_bookmark(ids[2])
    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Removed from KOReader")
    H.truthy(H.local_article_by_id(ids[2]), "deleted article kept locally")
end)

-- work.md, "The subtle part": a bookmark the server is still (re)loading must
-- count as existing, or its local file is deleted as "missing from Readeck".
H.test("remove-missing never deletes the file of a bookmark that is still loading", function()
    H.configure_plugin({ remove_local_missing_remote = true })
    local fm = H.open_filemanager()
    local ready = H.seed_page("lighthouse.html")
    H.sync_via_menu(fm)
    local ready_file = H.local_article_by_id(ready)

    -- A bookmark that exists on the server but is still loading, and whose
    -- article the device already has (e.g. downloaded earlier, then
    -- re-fetched on the server).
    local slow = H.api:create_bookmark(H.fixture_url("clocks.html?delay=6"))
    H.eq(H.api:get_bookmark(slow).state, 2, "server is still loading it")
    local copy = H.download_dir .. "How Mechanical Clocks Keep Time [rd-id_" .. slow .. "].epub"
    require("ffi/util").copyFile(ready_file.path, copy)

    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Removed from KOReader", "nothing may be removed")
    H.truthy(H.local_article_by_id(slow), "local file of a still-loading bookmark kept")
    H.truthy(H.local_article_by_id(ready), "ready article kept")
end)

-- The cleanup compares local files with the *fetched batch*, which is capped
-- by "Number of articles" (articles_per_sync). Bookmarks outside that window
-- still exist on the server and must not be treated as missing.
H.test("remove-missing never deletes articles that only fell outside the sync batch", function()
    H.configure_plugin({ articles_per_sync = 3, remove_local_missing_remote = true })
    local fm = H.open_filemanager()
    local first = H.seed(3, { title_prefix = "Early Article" })
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 3")

    -- Newer bookmarks push the downloaded ones out of the 3-article window.
    require("socket").sleep(1.1) -- Readeck orders "-created" at one-second resolution
    H.seed(3, { title_prefix = "Late Article" })
    summary = H.sync_via_menu(fm)
    H.no_match(summary, "Removed from KOReader", "unread articles still on the server must stay")
    for _, bookmark in ipairs(first) do
        H.truthy(H.local_article_by_id(bookmark.id), bookmark.title .. " kept locally")
        H.truthy(H.api:get_bookmark(bookmark.id), bookmark.title .. " still exists on the server")
    end
end)
