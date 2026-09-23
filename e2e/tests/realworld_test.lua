-- Highlight positions on real web articles, checked against Readeck itself.
--
-- Opt-in, it needs the internet:  E2E_REALWORLD=1 mise run e2e -- realworld
-- Other pages:                    E2E_REALWORLD_URLS="https://a https://b"
-- More / other ranges:             E2E_REALWORLD_COUNT=60 E2E_REALWORLD_SEED=2
--
-- The fixtures in e2e/fixtures/site are written to exercise known rules; real
-- pages (Wikipedia references, figures, <pre>, CJK) find the rules nobody
-- wrote down. For each page: bookmark it on the local Readeck, download it,
-- pick ~25 ranges from the stored article HTML with e2e/fixtures/
-- annotation_oracle.py (which shares no code with position_map.lua), create
-- them through the API - Readeck resolves each and returns its text - and
-- then check that
--   1. every one imports, and crengine shows exactly Readeck's text there;
--   2. after deleting them on the server, KOReader re-exports every one and
--      Readeck resolves the re-exported selector/offset to the same text.
local H = ...

local DEFAULT_URLS = {
    "https://en.wikipedia.org/wiki/Lighthouse",
    "https://zh.wikipedia.org/wiki/%E7%87%88%E5%A1%94",
    "https://ja.wikipedia.org/wiki/%E7%81%AF%E5%8F%B0",
    "https://go.dev/blog/loopvar-preview",
    "https://danluu.com/cocktail-ideas/",
    "https://blog.codeberg.org/",
}

local enabled = os.getenv("E2E_REALWORLD") == "1" or (os.getenv("E2E_REALWORLD_URLS") or "") ~= ""
local urls = {}
for url in (os.getenv("E2E_REALWORLD_URLS") or ""):gmatch("%S+") do
    table.insert(urls, url)
end
if #urls == 0 then
    urls = DEFAULT_URLS
end

local function words(text)
    return (tostring(text or ""):gsub("%s+", ""))
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function oracle_ranges(html, count)
    local path = os.tmpname()
    local handle = assert(io.open(path, "wb"))
    handle:write(html)
    handle:close()
    local pipe = assert(
        io.popen(
            string.format(
                "%s %s %s --count %d --seed %d",
                H.config.python,
                shell_quote(H.config.repo .. "/e2e/fixtures/annotation_oracle.py"),
                shell_quote(path),
                count,
                tonumber(os.getenv("E2E_REALWORLD_SEED")) or 1
            )
        )
    )
    local output = pipe:read("*a")
    pipe:close()
    os.remove(path)
    return require("json").decode(output)
end

local function sync_highlights(reader)
    local mark = H.mark()
    H.tap_menu(reader, { "Readeck", "Sync current article highlights" })
    local entry = H.wait_dialog("Finished syncing highlights", { since = mark, timeout = 120 })
    local text = H.widget_text(entry.widget)
    H.log("highlight sync:", (text:gsub("\n", " | ")))
    H.dismiss_all()
    return text
end

-- Readeck is the oracle: whatever it accepts and resolves is the truth.
local function create_oracle_annotations(id, with_notes)
    local created = {}
    local ranges = oracle_ranges(H.api:article_html(id), tonumber(os.getenv("E2E_REALWORLD_COUNT")) or 25)
    for index, range in ipairs(ranges) do
        local status, remote = H.api:request("POST", "/api/bookmarks/" .. id .. "/annotations", {
            start_selector = range.start_selector,
            start_offset = range.start_offset,
            end_selector = range.end_selector,
            end_offset = range.end_offset,
            color = "yellow",
            -- A note puts a footnote link into the EPUB after the mark.
            note = with_notes and index % 3 == 0 and ("note " .. index) or nil,
        })
        if status == 201 or status == 200 then
            table.insert(created, remote)
        else
            H.log("oracle range rejected by Readeck:", status, H.describe(range), H.describe(remote))
        end
    end
    -- A rejected range is an oracle bug; a short page just has fewer ranges.
    H.eq(#created, #ranges, "Readeck accepted every oracle range")
    H.truthy(#created >= 3, "page too short to test: " .. #created .. " ranges")
    return created
end

-- marked: annotate on the server first, so the EPUB is downloaded with
-- Readeck's <mark> wrappers and note links in it (Readeck 0.22+).
local function check_page(url, marked)
    local id = H.api:create_bookmark(url)
    local bookmark = H.api:wait_loaded(id, 90)
    H.truthy(bookmark.has_article, "Readeck extracted an article from " .. url)

    local created = marked and create_oracle_annotations(id, H.server_at_least("0.22.0")) or nil
    H.configure_plugin()
    local fm = H.open_filemanager()
    local sync_summary = H.sync_via_menu(fm, { timeout = 120 })
    if marked and sync_summary:find("EPUB without the article", 1, true) then
        -- Readeck bug (errors_test "EPUB without the article"): a note's
        -- footnote link broke another annotation. The plugin rightly kept
        -- nothing; drop the notes so the marks can still be checked.
        H.log("READECK BUG: empty EPUB with notes; retrying without notes")
        for _, remote in ipairs(created) do
            if (remote.note or "") ~= "" then
                H.api:update_annotation(id, remote.id, { note = "", color = remote.color or "yellow" })
            end
        end
        sync_summary = H.sync_via_menu(fm, { timeout = 120 })
    end
    H.match(sync_summary, "Downloaded: 1")
    local reader = H.open_reader(H.local_article_by_id(id).path)

    -- 1. Import: every annotation lands on Readeck's text.
    if marked then
        H.match(sync_summary, "Highlights imported: " .. #created, "every annotation imported by the full sync")
        H.no_match(sync_summary, "Import failed")
    else
        created = create_oracle_annotations(id, false)
        local summary = sync_highlights(reader)
        H.match(summary, "Imported: " .. #created, "every annotation imported")
        H.no_match(summary, "Import failed")
    end
    do
        local local_by_remote = {}
        for _, annotation in ipairs(reader.annotation.annotations) do
            if annotation.readeck_annotation_id then
                local_by_remote[annotation.readeck_annotation_id] = annotation
            end
        end
        local mismatches = {}
        for _, remote in ipairs(created) do
            local annotation = local_by_remote[remote.id]
            if not annotation then
                table.insert(mismatches, "not imported: " .. H.describe(remote.text))
            else
                local shown = reader.document:getTextFromXPointers(annotation.pos0, annotation.pos1)
                if
                    marked
                    and words(shown) ~= words(remote.text)
                    and words(shown):gsub("%d", "") == words(remote.text):gsub("%d", "")
                then
                    -- Readeck bug: each footnote number it inserts shifts the
                    -- later marks of that paragraph by one character, so one
                    -- can land inside another range in the EPUB. The position
                    -- is right; crengine just shows that number too.
                    H.log("READECK BUG: footnote number inside the range:", H.describe(shown))
                elseif words(shown) ~= words(remote.text) then
                    table.insert(
                        mismatches,
                        string.format(
                            "import %s %d..%s %d\n    Readeck:  %s\n    crengine: %s",
                            remote.start_selector,
                            remote.start_offset,
                            remote.end_selector,
                            remote.end_offset,
                            H.describe(remote.text),
                            H.describe(shown)
                        )
                    )
                end
            end
        end

        -- 2. Export: deleted on the server, re-exported from KOReader's positions.
        local original_text = {}
        for _, remote in ipairs(created) do
            local annotation = local_by_remote[remote.id]
            if annotation then
                original_text[annotation] = remote
            end
            H.api:delete_annotation(id, remote.id)
        end
        local summary = sync_highlights(reader)
        H.no_match(summary, "Failed", "every highlight re-exported")
        local remote_by_id = {}
        for _, remote in ipairs(H.api:annotations(id)) do
            remote_by_id[remote.id] = remote
        end
        for annotation, original in pairs(original_text) do
            local exported = remote_by_id[annotation.readeck_annotation_id]
            if not exported then
                table.insert(mismatches, "not re-exported: " .. H.describe(original.text))
            elseif words(exported.text) ~= words(original.text) then
                table.insert(
                    mismatches,
                    string.format(
                        "export %s %d..%s %d -> %s %d..%s %d\n    before: %s\n    after:  %s",
                        original.start_selector,
                        original.start_offset,
                        original.end_selector,
                        original.end_offset,
                        exported.start_selector,
                        exported.start_offset,
                        exported.end_selector,
                        exported.end_offset,
                        H.describe(original.text),
                        H.describe(exported.text)
                    )
                )
            end
        end

        for _, line in ipairs(mismatches) do
            H.log("MISMATCH", line)
        end
        H.eq(#mismatches, 0, #mismatches .. " of " .. #created .. " ranges wrong (see log.txt)")
    end
end

local skip = not enabled and "set E2E_REALWORLD=1 (needs the internet)" or nil
for _, url in ipairs(urls) do
    H.test("real page: " .. url, function()
        check_page(url, false)
    end, { skip = skip })
    H.test("real page, EPUB with Readeck's marks: " .. url, function()
        check_page(url, true)
    end, { skip = skip })
end
