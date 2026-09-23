-- Article sync: bulk download, idempotence, batch size, readiness.
local H = ...

H.test("full sync of 25 bookmarks, then an idempotent re-sync", function()
    local seeded = H.seed(25, { labels = { "e2e", "bulk" } })
    H.configure_plugin()
    local fm = H.open_filemanager()

    local summary = H.sync_via_menu(fm, { timeout = 120 })
    H.match(summary, "Downloaded: 25\n")
    H.match(summary, "Skipped: 0")
    H.no_match(summary, "Failed")

    local files = H.local_articles()
    H.eq(#files, 25, "one file per bookmark")
    for _, bookmark in ipairs(seeded) do
        local article = H.truthy(H.local_article_by_id(bookmark.id), "no file for " .. bookmark.title)
        -- Filenames are "<title> [rd-id_<id>].epub".
        H.eq(article.name, bookmark.title .. " [rd-id_" .. bookmark.id .. "].epub", "filename")
        H.eq(H.epub_title(article.path), bookmark.title, "EPUB title of " .. article.name)
        -- Readeck labels and reading time land in the book's keywords.
        local keywords = H.custom_keywords(article.path) or ""
        H.match(keywords, "Reading time: %d+ min", "reading time keyword of " .. article.name)
        H.match(keywords, "%f[%w]e2e%f[%W]", "label keyword of " .. article.name)
        H.match(keywords, "%f[%w]bulk%f[%W]", "label keyword of " .. article.name)
    end
    H.screenshot("file browser after sync")

    summary = H.sync_via_menu(fm, { timeout = 120 })
    H.match(summary, "Downloaded: 0")
    H.match(summary, "Skipped: 25")
    H.eq(#H.local_articles(), 25, "re-sync created no duplicates")
end)

H.test("download limit set in the client settings caps a sync", function()
    local seeded = H.seed(5)
    H.configure_plugin()
    local fm = H.open_filemanager()

    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Configure Readeck client", "Download limits" })
    local dialog = H.wait_dialog("Readeck client settings", { since = mark, kind = "MultiInputDialog" })
    H.fill(dialog, "3", 1)
    H.press("Apply", dialog)
    H.eq(H.plugin_settings().articles_per_sync, 3)

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 3")
    H.eq(#H.local_articles(), 3)
    -- Default sort is "Added, most recent first"; the server decides ties
    -- (bookmarks created within the same second), so ask it for its order.
    local expected = H.api:list_bookmarks({ sort = "-created", limit = 3 })
    for _, bookmark in ipairs(expected) do
        H.truthy(H.local_article_by_id(bookmark.id), "first-listed bookmark " .. bookmark.title .. " downloaded")
    end
    H.eq(#seeded, 5)
end)

H.test("bookmark still loading on the server is not a failure, next sync gets it", function()
    local ready = H.seed_page("lighthouse.html")
    -- The fixture site answers this page after 4s, so Readeck keeps it in state=2.
    local slow = H.api:create_bookmark(H.fixture_url("clocks.html?delay=4"))
    local bookmark = H.api:get_bookmark(slow)
    H.eq(bookmark.state, 2, "server still loading the slow bookmark")

    H.configure_plugin()
    local fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Failed", "a loading bookmark must not count as a failed download")
    H.match(summary, "Downloaded: 1")
    H.truthy(H.local_article_by_id(ready), "ready bookmark downloaded")
    H.falsy(H.local_article_by_id(slow), "loading bookmark not downloaded yet")

    H.api:wait_loaded(slow, 20)
    summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    H.match(summary, "Skipped: 1")
    local article = H.truthy(H.local_article_by_id(slow), "bookmark downloaded once loaded")
    H.eq(H.epub_title(article.path), "How Mechanical Clocks Keep Time")
end)

H.test("article added through the plugin then synced right away", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local url = H.fixture_url("bread.html")
    local mark = H.mark()
    -- What "Add to Readeck" in the external-link dialog does.
    H.send_event(fm, "AddReadeckArticle", url)
    H.wait_dialog("Article added to Readeck", { since = mark })
    H.dismiss_all()

    local list = H.api:list_bookmarks()
    H.eq(#list, 1, "bookmark created on the server")
    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Failed")
    local id = list[1].id
    H.api:wait_loaded(id, 20)
    if not H.local_article_by_id(id) then
        summary = H.sync_via_menu(fm)
        H.match(summary, "Downloaded: 1")
    end
    H.truthy(H.local_article_by_id(id), "article downloaded")
end)

H.test("offline add goes to the queue and is created on the next sync", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local NetworkMgr = require("ui/network/manager")
    local online = NetworkMgr.isOnline
    NetworkMgr.isOnline = function()
        return false
    end
    local url = H.fixture_url("mountains.html")
    local mark = H.mark()
    local ok, err = pcall(H.send_event, fm, "AddReadeckArticle", url)
    NetworkMgr.isOnline = online
    assert(ok, err)
    H.wait_dialog("Article added to download queue", { since = mark })
    H.eq(#H.api:list_bookmarks(), 0, "nothing sent while offline")
    H.eq(#(H.plugin_settings().download_queue or {}), 1, "queue persisted")

    H.dismiss_all()
    mark = H.mark()
    H.sync_via_menu(fm)
    H.truthy(H.find_dialog("Adding articles from queue", { since = mark }), "queue processed during sync")
    local list = H.api:list_bookmarks()
    H.eq(#list, 1, "queued article created on the server")
    H.eq(list[1].url, url)
    H.eq(#(H.plugin_settings().download_queue or {}), 0, "queue emptied")
end)
