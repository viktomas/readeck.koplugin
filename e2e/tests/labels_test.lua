-- Labels: filter tag, ignored tags, tags added to new articles, review tags.
local H = ...

local SELECTION = { "Readeck", "Settings", "Article selection" }
local function selection(label)
    return { SELECTION[1], SELECTION[2], SELECTION[3], label }
end

local function set_input(fm, path, dialog_title, value, button)
    local mark = H.mark()
    H.tap_menu(fm, path)
    local dialog = H.wait_dialog(dialog_title, { since = mark, kind = "InputDialog" })
    H.fill(dialog, value)
    H.press(button, dialog)
end

H.test("filter tag: only bookmarks with that label are downloaded", function()
    local tagged = {
        H.seed_page("lighthouse.html", { labels = { "koreader" } }),
        H.seed_page("bread.html", { labels = { "koreader", "food" } }),
    }
    local untagged = { H.seed_page("clocks.html"), H.seed_page("mountains.html", { labels = { "other" } }) }
    H.configure_plugin()
    local fm = H.open_filemanager()
    set_input(fm, selection({ "^Only download articles with tag" }), "Enter a single tag", "koreader", "OK")
    H.eq(H.plugin_settings().filter_tag, "koreader")

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 2")
    for _, id in ipairs(tagged) do
        H.truthy(H.local_article_by_id(id), "tagged bookmark downloaded")
    end
    for _, id in ipairs(untagged) do
        H.falsy(H.local_article_by_id(id), "untagged bookmark skipped")
    end
end)

H.test("ignored tags: bookmarks with any of them are not downloaded", function()
    local keep = H.seed_page("lighthouse.html", { labels = { "fiction" } })
    local skip1 = H.seed_page("bread.html", { labels = { "later" } })
    local skip2 = H.seed_page("clocks.html", { labels = { "fiction", "noread" } })
    H.configure_plugin()
    local fm = H.open_filemanager()
    set_input(fm, selection({ "^Tags to ignore" }), "Tags to ignore", "later,noread", "Set tags")
    H.eq(H.plugin_settings().ignore_tags, "later,noread")

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    H.truthy(H.local_article_by_id(keep), "bookmark without ignored tags downloaded")
    H.falsy(H.local_article_by_id(skip1), "bookmark tagged 'later' skipped")
    H.falsy(H.local_article_by_id(skip2), "bookmark tagged 'noread' skipped")
end)

H.test("tags to add to new articles are set on the server", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    set_input(
        fm,
        selection({ "^Tags to add to new articles" }),
        "Tags to add to new articles",
        "koreader, from device",
        "Set tags"
    )

    local mark = H.mark()
    H.send_event(fm, "AddReadeckArticle", H.fixture_url("mountains.html"))
    H.wait_dialog("Article added to Readeck", { since = mark })
    local list = H.api:list_bookmarks()
    H.eq(#list, 1)
    local labels = list[1].labels or {}
    table.sort(labels)
    H.eq(table.concat(labels, "|"), "from device|koreader", "labels trimmed and applied")
end)

H.test("review text is sent as labels", function()
    H.configure_plugin()
    local fm = H.open_filemanager()
    local id = H.seed_page("bread.html")
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    H.set_menu_checkbox(fm, { "Readeck", "Settings", "Ratings and review tags", "Send review as tags" }, true)

    local path = H.local_article_by_id(id).path
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    -- The review field of the book status page.
    settings:saveSetting("summary", { status = "reading", note = "baking, weekend project" })
    settings:flush()

    H.sync_via_menu(fm)
    local labels = H.api:get_bookmark(id).labels or {}
    table.sort(labels)
    H.eq(table.concat(labels, "|"), "baking|weekend project")
end)
