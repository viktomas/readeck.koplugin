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

H.test("download cut off halfway: no truncated file left behind, next sync gets it", function()
    local id = H.seed_page("lighthouse.html")
    H.configure_plugin({ server_url = H.start_truncating_proxy() })
    local fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.no_match(summary, "Downloaded: 1", "a half-received EPUB is not a download")
    H.falsy(H.local_article_by_id(id), "no truncated EPUB kept under the article's name")
    for entry in require("libs/libkoreader-lfs").dir(H.download_dir) do
        H.falsy(entry:find("%.part$"), "partial download left behind: " .. entry)
    end

    H.configure_plugin()
    fm = H.open_filemanager()
    summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1", "the next sync over a good connection fetches it")
    local article = H.truthy(H.local_article_by_id(id), "article downloaded")
    H.eq(H.epub_title(article.path), "The Lighthouse Keeper")
end)

-- Readeck 0.22-0.23.4 bug: building the EPUB, the footnote link it inserts for
-- a note becomes `p[1]/a[1]` for a later annotation in the same paragraph,
-- that annotation no longer resolves ("index out of range"), and the EPUB is
-- sent with HTTP 200 but without its chapter. Kept, it would be a blank book
-- that no later sync replaces.
H.test("Readeck sends an EPUB without the article: not kept, retried once it is fixed", function()
    local id = H.seed_page("markup.html")
    H.api:create_annotation(id, {
        start_selector = "section[1]/article[1]/p[1]/em[1]",
        start_offset = 8,
        end_selector = "section[1]/article[1]/p[1]",
        end_offset = 22,
        color = "yellow",
        note = "a note",
    })
    local second = H.api:create_annotation(id, {
        start_selector = "section[1]/article[1]/p[1]",
        start_offset = 102,
        end_selector = "section[1]/article[1]/p[1]/a[1]",
        end_offset = 11,
        color = "yellow",
    })
    H.configure_plugin()
    local fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Readeck sent an EPUB without the article, will retry: 1")
    H.falsy(H.local_article_by_id(id), "the blank EPUB is not kept")

    -- The user removes the annotation that trips Readeck; the next sync gets the book.
    H.api:delete_annotation(id, second.id)
    summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    local article = H.truthy(H.local_article_by_id(id), "downloaded once Readeck can build it")
    H.eq(H.epub_title(article.path), "Nested Markup and Other Text")
end, { versions = { ["0.21.6"] = "no notes before Readeck 0.22, so no footnote links" } })
