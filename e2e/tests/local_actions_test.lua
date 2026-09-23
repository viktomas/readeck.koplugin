-- What the user does in KOReader (finish, read, rate, delete) and what a
-- sync then does on the server.
local H = ...

local ACTIONS = { "Readeck", "Settings", "Article actions" }
local function action(label)
    return { ACTIONS[1], ACTIONS[2], ACTIONS[3], label }
end

local function download_one(fm, page)
    local id = H.seed_page(page or "lighthouse.html")
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    return id, H.local_article_by_id(id).path
end

local function mark_finished(fm, path)
    local dialog = H.long_press_file(fm, path)
    H.press("Finished", dialog)
    H.eq((H.doc_setting(path, "summary") or {}).status, "complete", "book status set by the file dialog")
end

H.test("finished in KOReader: sync archives it on the server and removes the file", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)
    mark_finished(fm, path)

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Archived in Readeck: 1")
    H.match(summary, "Removed from KOReader: 1")
    H.falsy(H.local_article_by_id(id), "local file removed")
    local bookmark = H.api:get_bookmark(id)
    H.eq(bookmark.is_archived, true, "archived on the server")
    H.eq(bookmark.read_progress, 100, "marked as fully read")
end)

H.test("finished + archive-instead-of-delete off: bookmark deleted on the server", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)
    H.set_menu_checkbox(fm, action("Archive completion actions instead of deleting"), false)
    mark_finished(fm, path)

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Deleted from Readeck: 1")
    H.falsy(H.local_article_by_id(id), "local file removed")
    H.eq(H.api:get_bookmark(id), nil, "bookmark gone from the server")
end)

H.test("completion actions off during sync, then 'Process finished/read articles'", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)
    H.set_menu_checkbox(fm, action("Process completion actions when syncing"), false)
    mark_finished(fm, path)

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Completion actions skipped during sync%.")
    H.truthy(H.local_article_by_id(id), "file kept while completion actions are off")
    H.eq(H.api:get_bookmark(id).is_archived, false)

    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Process finished/read articles" })
    local result = H.wait_dialog("Articles processed%.", { since = mark })
    H.match(H.widget_text(result.widget), "Archived in Readeck: 1")
    H.eq(H.api:get_bookmark(id).is_archived, true, "archived by the manual action")
    H.falsy(H.local_article_by_id(id), "local file removed")
end)

H.test("read to 100% + 'Process 100% read articles': archived on sync", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)
    H.set_menu_checkbox(fm, action("Process 100% read articles in Readeck"), true)

    local reader = H.open_reader(path)
    H.send_event(reader, "GotoPercent", 100)
    H.pump(0.5)
    H.screenshot("last page")
    H.close_reader()
    H.eq(H.doc_setting(path, "percent_finished"), 1, "KOReader recorded 100%")

    fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Archived in Readeck: 1")
    local bookmark = H.api:get_bookmark(id)
    H.eq(bookmark.is_archived, true)
    H.eq(bookmark.read_progress, 100)
end)

H.test("reading progress syncs both ways when enabled", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local seeded = H.seed(1, { title_prefix = "Long Read" })
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local id = seeded[1].id
    local path = H.local_article_by_id(id).path
    H.set_menu_checkbox(fm, action("Sync reading progress to Readeck (beta)"), true)

    local reader = H.open_reader(path)
    local pages = reader.document:getPageCount()
    H.truthy(pages >= 3, "article spans several pages (got " .. pages .. ")")
    H.send_event(reader, "GotoPage", 2)
    H.pump(0.5)
    H.close_reader()
    local local_percent = H.doc_setting(path, "percent_finished")
    H.truthy(local_percent > 0 and local_percent < 1, "KOReader recorded partial progress")

    fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Reading progress synced: 1")
    H.eq(H.api:get_bookmark(id).read_progress, math.floor(local_percent * 100 + 0.5), "progress on the server")

    -- Progress made elsewhere (e.g. the Readeck web reader) comes back.
    H.api:update_bookmark(id, { read_progress = 90 })
    summary = H.sync_via_menu(fm)
    H.match(summary, "KOReader progress updated: 1")
    H.eq(H.doc_setting(path, "percent_finished"), 0.9, "local progress updated from the server")
end)

H.test("star rating: liked and labelled in Readeck when archived", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)

    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Ratings and review tags", { "^Like entries in Readeck" } })
    local dialog = H.wait_dialog("Star rating threshold", { since = mark, kind = "ButtonDialog" })
    H.press("★★★★", dialog)
    H.set_menu_checkbox(
        fm,
        { "Readeck", "Settings", "Ratings and review tags", "Label entries in Readeck with their star rating" },
        true
    )

    -- What the book status page stores for a 5-star rating.
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    settings:saveSetting("summary", { status = "complete", rating = 5 })
    settings:flush()

    H.match(H.sync_via_menu(fm), "Archived in Readeck: 1")
    local bookmark = H.api:get_bookmark(id)
    H.eq(bookmark.is_marked, true, "liked (rating 5 >= threshold 4)")
    H.eq(bookmark.is_archived, true)
    H.contains(table.concat(bookmark.labels or {}, ","), "5-star", "rating label")
end)

-- Deleting a file in KOReader is not a completion action: the plugin does not
-- see it, the bookmark stays on the server, and the next sync brings it back.
H.test("deleting the file in KOReader leaves the server alone and re-downloads", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id, path = download_one(fm)

    local dialog = H.long_press_file(fm, path)
    H.press("Delete", dialog)
    local confirm = H.wait_dialog("Delete file permanently%?", { kind = "ConfirmBox" })
    H.press("Delete", confirm)
    H.falsy(H.local_article_by_id(id), "file deleted locally")

    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Deleted from Readeck")
    local bookmark = H.api:get_bookmark(id)
    H.truthy(bookmark and not bookmark.is_archived, "bookmark untouched on the server")
    H.match(summary, "Downloaded: 1")
    H.truthy(H.local_article_by_id(id), "article downloaded again")
end)
