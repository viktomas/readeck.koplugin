-- Error surfacing: what the user reads when the server is unreachable or
-- rejects a request.
local H = ...

local function sync_and_collect(fm)
    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Synchronize articles with server" })
    H.pump_until(function()
        return not fm.readeck.sync_in_progress
    end, { timeout = 60, message = "sync did not finish" })
    local texts = H.dialog_texts_since(mark)
    H.log("dialogs:", (texts:gsub("\n", " | ")))
    return texts
end

H.test("server unreachable: the user is told it could not be reached", function()
    -- Nothing listens on this port.
    H.configure_plugin({ server_url = "http://127.0.0.1:18999" })
    local fm = H.open_filemanager()
    local texts = sync_and_collect(fm)
    H.match(texts, "Requesting article list failed%.")
    H.match(texts, "Could not reach the Readeck server")
    H.no_match(texts, "Processing finished")
    H.eq(#H.local_articles(), 0)
end)

H.test("server stopped after a good sync: legible error, local files untouched", function()
    H.configure_plugin({ remove_local_missing_remote = true })
    local id = H.seed_page("lighthouse.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")

    H.stop_server()
    local texts = sync_and_collect(fm)
    H.match(texts, "Could not reach the Readeck server")
    H.truthy(H.local_article_by_id(id), "nothing deleted while the server is down")
end)

H.test("server rejects a progress update: the server's reason is shown", function()
    H.configure_plugin({ sync_reading_progress = true })
    local id = H.seed_page("bread.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    settings:saveSetting("percent_finished", 0.3)
    settings:flush()
    -- Meanwhile the bookmark is deleted in the Readeck web UI.
    H.api:delete_bookmark(id)

    local texts = sync_and_collect(fm)
    H.match(texts, "Communication with server failed%.\nServer said: Not Found", "the server's reason is shown")
    H.truthy(H.local_article_by_id(id), "file kept")
end)

-- A finished article whose bookmark was deleted on the server: the highlight
-- export that guards the completion action 404s. That 404 means the
-- completion action's goal ("this bookmark is archived/deleted") is already
-- met, so the sync finishes it locally instead of failing it every time.
H.test("finished article deleted on the server: the completion action treats it as already done", function()
    H.configure_plugin()
    local id = H.seed_page("bread.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    H.press("Finished", H.long_press_file(fm, path))
    H.api:delete_bookmark(id)

    local texts = sync_and_collect(fm)
    H.no_match(texts, "Completion action failed")
    H.match(texts, "Deleted from Readeck: 1")
    H.falsy(H.local_article_by_id(id), "local copy removed once the bookmark is confirmed gone")
end)

-- A highlight the server cannot place: it is on text that only exists in
-- this copy of the EPUB (as when the article changed on the server after the
-- download), so the element is not in the stored article. The reason
-- reaches the per-article highlight summary...
local function add_unplaceable_highlight(path)
    H.edit_epub_chapter(path, function(xhtml)
        local edited, count = xhtml:gsub("</article>", "<aside>Only in this copy.</aside></article>", 1)
        H.eq(count, 1, "article element in the chapter")
        return edited
    end)
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    local xpointer = "/body/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/aside[1]/text()[1]."
    settings:saveSetting("annotations", {
        {
            drawer = "lighten",
            color = "yellow",
            text = "Only",
            datetime = "2026-01-01 00:00:00",
            page = xpointer .. "0",
            pos0 = xpointer .. "0",
            pos1 = xpointer .. "4",
        },
    })
    settings:flush()
end

H.test("highlight rejected by the server: reason shown in the highlight summary", function()
    H.configure_plugin()
    local id = H.seed_page("clocks.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    add_unplaceable_highlight(path)
    fm:onClose()

    local reader = H.open_reader(path)
    local mark = H.mark()
    H.tap_menu(reader, { "Readeck", "Sync current article highlights" })
    local result = H.wait_dialog("Finished syncing highlights", { since = mark })
    H.match(H.widget_text(result.widget), 'Failed: 1 %(element "section%[1%]/article%[1%]/aside%[1%]" not found%)')
end)

-- ...and the full-sync summary too (work.md, "Smaller things").
H.test("highlight rejected during a full sync: reason shown in the sync summary", function()
    H.configure_plugin()
    local id = H.seed_page("clocks.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    add_unplaceable_highlight(H.local_article_by_id(id).path)
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Highlight sync failed: 1")
    H.match(summary, "not found", "the reason reaches the summary")
end)
