-- Server-version gating of highlight payloads (readeck/core/features.lua):
-- annotation notes (and the note-only "none" colour) exist from Readeck 0.22.0.
local H = ...

local function export_note_and_none_colour()
    H.configure_plugin()
    local id = H.seed_page("lighthouse.html")
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")
    local reader = H.open_reader(H.local_article_by_id(id).path)
    -- A note-only highlight: KOReader's "none" colour (set directly, the way a
    -- highlight imported from Readeck with colour "none" is stored).
    local annotation = H.highlight(reader, "counting each of the one hundred", { note = "a note", color = "none" })
    local mark = H.mark()
    H.tap_menu(reader, { "Readeck", "Sync current article highlights" })
    local result = H.wait_dialog("Finished syncing highlights", { since = mark })
    H.match(H.widget_text(result.widget), "Exported: 1")
    local remote = H.api:annotations(id)
    H.eq(#remote, 1)
    H.eq(remote[1].id, annotation.readeck_annotation_id)
    H.eq(remote[1].text, "counting each of the one hundred", "selectors resolve on this server version")
    return remote[1]
end

H.test("Readeck 0.21.6 (no notes): note dropped and 'none' sent as yellow", function()
    H.eq(H.api:info().version.canonical, "0.21.6")
    local remote = export_note_and_none_colour()
    H.eq(remote.color, "yellow", "legacy servers get yellow instead of none")
    H.truthy(
        remote.note == nil or remote.note == "",
        "no note on a legacy server (got " .. H.describe(remote.note) .. ")"
    )
end, { server_version = "0.21.6" })

-- 0.22.0/0.22.1 store notes; the plugin used to gate them on 0.22.2.
H.test("Readeck 0.22.1: note and 'none' colour kept", function()
    H.eq(H.api:info().version.canonical, "0.22.1")
    local remote = export_note_and_none_colour()
    H.eq(remote.color, "none")
    H.eq(remote.note, "a note")
end, { server_version = "0.22.1" })

H.test("Readeck 0.23.4: note and 'none' colour kept", function()
    H.eq(H.api:info().version.canonical, "0.23.4")
    local remote = export_note_and_none_colour()
    H.eq(remote.color, "none")
    H.eq(remote.note, "a note")
end, { server_version = "0.23.4" })
