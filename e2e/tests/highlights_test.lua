-- Highlights: KOReader <-> Readeck annotations, made and synced through the
-- real reader (long-press + drag selection, highlight popup, reader menu).
local H = ...

-- Downloads a fixture article (default: the inline-markup page) and opens it.
local function open_article(overrides, page)
    H.configure_plugin(overrides)
    local id = H.seed_page(page or "inline.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    return id, path, H.open_reader(path)
end

local function sync_highlights(reader)
    local mark = H.mark()
    H.tap_menu(reader, { "Readeck", "Sync current article highlights" })
    local entry = H.wait_dialog("Finished syncing highlights", { since = mark })
    local text = H.widget_text(entry.widget)
    H.log("highlight sync:", (text:gsub("\n", " | ")))
    H.dismiss_all()
    return text
end

local function remote_by_id(id, annotation_id)
    for _, annotation in ipairs(H.api:annotations(id)) do
        if annotation.id == annotation_id then
            return annotation
        end
    end
    return nil
end

-- The note a server of this version keeps (notes exist from Readeck 0.22.0).
local function stored_note(note)
    return H.server_at_least("0.22.0") and note or ""
end

local function normalize(text)
    return (tostring(text or ""):gsub("%s+", " "))
end

-- Readeck computes an annotation's text from its selectors, so matching text
-- proves the exported selectors point at the highlighted words.
local function assert_exported(id, annotation, label)
    H.truthy(annotation.readeck_annotation_id, label .. ": local highlight not linked to a server annotation")
    local remote = H.truthy(remote_by_id(id, annotation.readeck_annotation_id), label .. ": not on the server")
    H.eq(normalize(remote.text), normalize(annotation.text), label .. ": server resolved other words")
    return remote
end

H.test("export: plain, note, colour, across paragraphs, overlapping", function()
    local id, _, reader = open_article()

    local plain = H.highlight(reader, "every character sits in a single text node")
    local noted = H.highlight(reader, "an emphasised phrase", { note = "why emphasise this?" })
    local spanning = H.highlight(reader, { "The last paragraph", "without trouble" })
    local across = H.highlight(reader, { "at the paragraph.", "This paragraph has" })
    local overlapping = H.highlight(reader, "single text node that starts")
    local colored = H.highlight(reader, "link to elsewhere", { color = "green" })
    for _, a in ipairs({ plain, noted, spanning, across, overlapping, colored }) do
        H.log("local:", a.pos0, "->", a.pos1, H.describe(a.text))
    end
    H.screenshot("highlights in the reader")

    local summary = sync_highlights(reader)
    H.match(summary, "Exported: 5")
    H.match(summary, "Skipped %(overlap%): 1", "Readeck refuses overlapping annotations; the plugin skips them")
    H.no_match(summary, "Failed")

    H.eq(#H.api:annotations(id), 5, "five annotations on the server")
    assert_exported(id, plain, "plain")
    H.eq(assert_exported(id, noted, "with note").note or "", stored_note("why emphasise this?"), "note exported")
    assert_exported(id, spanning, "whole paragraph")
    assert_exported(id, across, "across two paragraphs")
    H.eq(assert_exported(id, colored, "coloured").color, "green", "colour exported")
    H.falsy(overlapping.readeck_annotation_id, "overlapping highlight stays local")

    -- A second sync changes nothing.
    summary = sync_highlights(reader)
    H.no_match(summary, "Exported")
    H.eq(#H.api:annotations(id), 5)
end)

-- KOReader positions text after an inline element as p[2]/text()[2].N, N
-- counted from the start of that text node; Readeck counts from the start of
-- p[2]. The EPUB's position map translates (it used to land on the wrong
-- words, then was skipped as unsupported).
H.test("export: selection after inline markup lands on the same words", function()
    local id, _, reader = open_article()
    local after_inline = H.highlight(reader, "live in a second text node")
    H.log("local:", after_inline.pos0, "->", after_inline.pos1)
    local summary = sync_highlights(reader)
    H.no_match(summary, "Skipped %(unsupported%)", "selection was not exported")
    local remote = assert_exported(id, after_inline, "after <em>")
    H.eq(remote.start_selector, "section[1]/article[1]/p[2]")
    H.eq(remote.start_offset, 78, "19 + 20 characters before the second text node, + 39 in it")
end)

-- Readeck's text is raw, KOReader's is crengine's rendering: compare words.
local function words(text)
    return (tostring(text or ""):gsub("%s+", ""))
end

H.test("export: inline markup at start, middle and end, wrapped lines, entities, <br>", function()
    local id, _, reader = open_article(nil, "markup.html")
    local cases = {
        -- { from, to } selects from one phrase to another: crengine's search
        -- does not match across inline elements.
        { "starts inside <em> at the paragraph start", { "Opening emphasis", "starts" } },
        { "nested <strong><em>", { "nested emphasis", "inside bold" } },
        { "ends inside the closing <a>", { "it ends", "with a link" } },
        { "wrapped source lines, runs of spaces", "was wrapped over several lines in the source, with runs" },
        { "entities", 'chips, <tags> and "quotes"' },
        { "across <br>", { "of the verse", "line two" } },
        { "across a whitespace-only text node", { "spaced", "inline words" } },
        { "in a blockquote", { "inline code", "inside it" } },
        { "in a list item", { "item with", "and a tail" } },
    }
    local highlights = {}
    for _, case in ipairs(cases) do
        local annotation = H.highlight(reader, case[2])
        H.log("local:", case[1], annotation.pos0, "->", annotation.pos1)
        table.insert(highlights, annotation)
    end
    local summary = sync_highlights(reader)
    H.match(summary, "Exported: " .. #cases)
    H.no_match(summary, "Skipped")
    H.no_match(summary, "Failed")
    for i, case in ipairs(cases) do
        local annotation = highlights[i]
        H.truthy(annotation.readeck_annotation_id, case[1] .. ": not linked")
        local remote = H.truthy(remote_by_id(id, annotation.readeck_annotation_id), case[1] .. ": not on the server")
        H.log("remote:", case[1], remote.start_selector, remote.start_offset, remote.end_selector, remote.end_offset)
        H.eq(words(remote.text), words(annotation.text), case[1] .. ": server resolved other words")
    end
    summary = sync_highlights(reader)
    H.no_match(summary, "Exported")
    H.no_match(summary, "Imported")
end)

H.test("export: multibyte text is counted in characters, like Readeck", function()
    local id, _, reader = open_article(nil, "markup.html")
    local czech = H.highlight(reader, "žluťoučký kůň")
    local cjk = H.highlight(reader, "日本語のテキスト and 🎉 emoji 🚀")
    H.match(sync_highlights(reader), "Exported: 2")
    local remote = assert_exported(id, czech, "Czech diacritics")
    H.eq(remote.start_offset, 7, "'Příliš ' is 7 characters (9 bytes)")
    remote = assert_exported(id, cjk, "CJK and emoji")
    H.eq(remote.start_offset, 51)
    H.eq(remote.end_offset, 73, "51 + 22: an emoji is one character")
end)

-- Where each imported highlight points in KOReader must be the words Readeck
-- stored, or crengine draws it elsewhere (or not at all).
local function assert_imported(reader, remote, label)
    local imported
    for _, annotation in ipairs(reader.annotation.annotations) do
        if annotation.readeck_annotation_id == remote.id then
            imported = annotation
        end
    end
    H.truthy(imported, label .. ": not in KOReader's list")
    H.log("imported:", label, imported.pos0, "->", imported.pos1)
    local text = reader.document:getTextFromXPointers(imported.pos0, imported.pos1)
    H.eq(words(text), words(remote.text), label .. ": resolves to other words in the EPUB")
    H.eq(words(imported.text), words(remote.text), label .. ": stored text")
    return imported
end

-- KOReader's datetime is local time; Readeck's `created` is UTC.
local function assert_recent_local_time(datetime, label)
    local y, mo, d, h, mi, s = tostring(datetime):match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$")
    H.truthy(y, label .. ": datetime format " .. tostring(datetime))
    local stamp = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
    H.truthy(math.abs(os.time() - stamp) < 300, label .. ": datetime is not local time: " .. datetime)
end

-- Annotations as the Readeck web reader makes them: the selector is the
-- element holding the selected text node, the offset counts raw characters.
local MARKUP_ANNOTATIONS = {
    { "inside <em> at paragraph start", "p[1]/em[1]", 8, "p[1]", 22 },
    { "nested em to strong", "p[1]/strong[1]/em[1]", 0, "p[1]/strong[1]", 29 },
    { "to the end of the <a>", "p[1]", 102, "p[1]/a[1]", 11 },
    { "wrapped lines", "p[2]", 5, "p[2]", 55 },
    { "entities", "p[3]", 0, "p[3]", 20 },
    { "multibyte", "p[5]", 7, "p[5]", 80 },
    { "across a <br>", "p[4]", 12, "p[4]", 29 },
    { "across paragraphs", "ul[1]/li[2]", 7, "p[7]", 7 },
}

local function create_markup_annotations(id)
    local created = {}
    for i, a in ipairs(MARKUP_ANNOTATIONS) do
        local remote = H.api:create_annotation(id, {
            start_selector = "section[1]/article[1]/" .. a[2],
            start_offset = a[3],
            end_selector = "section[1]/article[1]/" .. a[4],
            end_offset = a[5],
            color = i % 2 == 0 and "green" or "yellow",
            note = i == 1 and "from the web" or nil,
        })
        H.log("remote:", a[1], H.describe(remote.text))
        created[i] = remote
    end
    return created
end

H.test("import: annotations at inline markup, wrapped lines, entities, multibyte are drawn", function()
    local id, _, reader = open_article(nil, "markup.html")
    local created = create_markup_annotations(id)
    local summary = sync_highlights(reader)
    H.match(summary, "Imported: " .. #created)
    H.no_match(summary, "Import failed")
    for i, remote in ipairs(created) do
        local imported = assert_imported(reader, remote, MARKUP_ANNOTATIONS[i][1])
        H.eq(imported.color, i % 2 == 0 and "green" or "yellow")
        H.eq(imported.chapter, "Nested Markup and Other Text")
        assert_recent_local_time(imported.datetime, MARKUP_ANNOTATIONS[i][1])
    end
    H.screenshot("imported highlights")
    -- Idempotent: nothing imported or exported again.
    summary = sync_highlights(reader)
    H.no_match(summary, "Imported")
    H.no_match(summary, "Exported")
    H.eq(#reader.annotation.annotations, #created)
    H.eq(#H.api:annotations(id), #created)
end)

H.test("import: a full sync writes drawable highlights into the sidecar", function()
    H.configure_plugin()
    local id = H.seed_page("markup.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    local created = create_markup_annotations(id)
    H.match(H.sync_via_menu(fm), "Highlights imported: " .. #created)
    H.eq(#(H.doc_setting(path, "annotations") or {}), #created, "written to the sidecar")
    local reader = H.open_reader(path)
    for i, remote in ipairs(created) do
        assert_imported(reader, remote, MARKUP_ANNOTATIONS[i][1])
    end
    H.screenshot("highlights imported while the book was closed")
    H.no_match(sync_highlights(reader), "Imported")
end)

H.test("import, edit the note in KOReader, sync: the same Readeck annotation is updated", function()
    local id, _, reader = open_article()
    local remote = H.api:create_annotation(id, {
        start_selector = "section[1]/article[1]/p[2]/em[1]",
        start_offset = 3,
        end_selector = "section[1]/article[1]/p[2]",
        end_offset = 60,
        color = "yellow",
        note = H.server_at_least("0.22.0") and "web note" or nil,
    })
    H.match(sync_highlights(reader), "Imported: 1")
    local imported = assert_imported(reader, remote, "from <em> into the next text node")

    imported.note = "edited on the device" -- what "Edit note" stores
    imported.color = "red"
    H.match(sync_highlights(reader), "Updated in Readeck: 1")
    local annotations = H.api:annotations(id)
    H.eq(#annotations, 1, "no duplicate annotation")
    H.eq(annotations[1].id, remote.id, "same annotation")
    H.eq(annotations[1].color, "red")
    H.eq(annotations[1].note or "", stored_note("edited on the device"))
    H.eq(imported.readeck_annotation_id, remote.id, "link kept")
    H.no_match(sync_highlights(reader), "Updated")
end)

H.test("round trip: highlights exported on one device import on a fresh one", function()
    local id, _, reader = open_article(nil, "markup.html")
    local phrases = {
        { "nested emphasis", "inside bold" },
        "was wrapped over several lines",
        "日本語のテキスト and 🎉 emoji",
        { "spaced", "inline words" },
    }
    local exported = {}
    for i, phrase in ipairs(phrases) do
        exported[i] = H.highlight(reader, phrase, i == 2 and { note = "a note" } or nil)
    end
    H.match(sync_highlights(reader), "Exported: " .. #phrases)
    H.close_reader()

    -- A second device: its own download folder (so its own sidecars), a new
    -- EPUB - which Readeck now exports with <mark>s and a noteref link.
    H.configure_plugin({ directory = H.download_dir .. "device-b/" })
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local path = H.local_article_by_id(id).path
    reader = H.open_reader(path)
    H.match(sync_highlights(reader), "Imported: " .. #phrases)
    for i, phrase in ipairs(phrases) do
        local label = type(phrase) == "table" and table.concat(phrase, " ... ") or phrase
        local remote = remote_by_id(id, exported[i].readeck_annotation_id)
        local imported = assert_imported(reader, remote, label)
        H.eq(words(imported.text), words(exported[i].text), label .. ": other text than on the first device")
    end
    H.screenshot("round trip on the second device")
    local summary = sync_highlights(reader)
    H.no_match(summary, "Exported")
    H.eq(#H.api:annotations(id), #phrases)
end)

H.test("import: an annotation made in Readeck is drawn in the reader", function()
    local id, path, reader = open_article()
    -- What the Readeck web reader stores for a selection in paragraph 4.
    H.api:create_annotation(id, {
        start_selector = "section[1]/article[1]/p[4]",
        start_offset = 4,
        end_selector = "section[1]/article[1]/p[4]",
        end_offset = 18,
        color = "blue",
        note = "from the web",
    })
    local remote = H.api:annotations(id)[1]
    H.eq(remote.text, "last paragraph")

    local summary = sync_highlights(reader)
    H.match(summary, "Imported: 1")
    local imported
    for _, annotation in ipairs(reader.annotation.annotations) do
        if annotation.readeck_annotation_id == remote.id then
            imported = annotation
        end
    end
    H.truthy(imported, "annotation added to KOReader's list")
    H.log("imported:", imported.pos0, "->", imported.pos1)
    H.eq(imported.note or "", stored_note("from the web"))
    H.eq(imported.color, "blue")
    H.screenshot("imported highlight")
    -- It has to point at the same words in the EPUB, or KOReader cannot draw it.
    local text = reader.document:getTextFromXPointers(imported.pos0, imported.pos1)
    H.eq(text, "last paragraph", "imported highlight resolves in the EPUB")
    H.close_reader()
    H.eq(#(H.doc_setting(path, "annotations") or {}), 1, "imported highlight saved in the sidecar")
end)

H.test("updates: note and colour changes flow both ways", function()
    local id, _, reader = open_article()
    local annotation = H.highlight(reader, "every character sits in a single text node", { note = "first" })
    H.match(sync_highlights(reader), "Exported: 1")
    local remote_id = annotation.readeck_annotation_id

    -- Edited in KOReader (what "Edit note" / "Change color" store).
    annotation.note = "second thoughts"
    annotation.color = "red"
    H.match(sync_highlights(reader), "Updated in Readeck: 1")
    local remote = remote_by_id(id, remote_id)
    H.eq(remote.note or "", stored_note("second thoughts"), "note updated on the server")
    H.eq(remote.color, "red", "colour updated on the server")

    -- Edited in Readeck.
    H.api:update_annotation(id, remote_id, { color = "blue", note = "edited on the web" })
    H.match(sync_highlights(reader), "Updated in KOReader: 1")
    if H.server_at_least("0.22.0") then
        H.eq(annotation.note, "edited on the web", "note updated in KOReader")
    end
    H.eq(annotation.color, "blue", "colour updated in KOReader")
    H.eq(#H.api:annotations(id), 1, "no duplicates")
end)

H.test("remote deletion: re-exported by default, kept local-only when respected", function()
    local id, _, reader = open_article()
    local annotation = H.highlight(reader, "every character sits in a single text node")
    H.match(sync_highlights(reader), "Exported: 1")
    H.api:delete_annotation(id, annotation.readeck_annotation_id)

    -- Default policy ("preserve_local"): KOReader's copy wins and is sent again.
    H.match(sync_highlights(reader), "Exported: 1")
    H.eq(#H.api:annotations(id), 1, "re-created on the server")
    H.api:delete_annotation(id, annotation.readeck_annotation_id)

    reader.readeck.highlight_sync_policy = "respect_remote_deletions"
    H.match(sync_highlights(reader), "Kept local only: 1")
    H.eq(#H.api:annotations(id), 0, "not re-created")
    H.eq(#reader.annotation.annotations, 1, "still highlighted in KOReader")
end)

H.test("closing the book exports its highlights when enabled", function()
    local id, _, reader = open_article({ auto_export_highlights = true })
    H.highlight(reader, "every character sits in a single text node")
    H.close_reader()
    H.wait_for(function()
        return #H.api:annotations(id) == 1
    end, { timeout = 10, message = "highlight not exported on close" })
end)

H.test("full sync exports highlights saved in the sidecar", function()
    local id, path, reader = open_article()
    H.highlight(reader, "every character sits in a single text node", { note = "for later" })
    H.close_reader()
    H.eq(#H.api:annotations(id), 0, "nothing exported on close by default")
    H.eq(#(H.doc_setting(path, "annotations") or {}), 1, "highlight saved in the sidecar")

    local fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Highlights exported: 1")
    local remote = H.api:annotations(id)
    H.eq(#remote, 1)
    H.eq(remote[1].note or "", stored_note("for later"))
end)
