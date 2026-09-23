package.path = "./readeck.koplugin/?.lua;" .. package.path

local Highlights = require("readeck.annotations.highlights")
local PositionMap = require("readeck.annotations.position_map")

-- The chapter of a real Readeck EPUB of e2e/fixtures/site/inline.html.
local function inline_map()
    local file = assert(io.open("spec/fixtures/readeck_epub/inline.html", "rb"))
    local source = file:read("*a")
    file:close()
    return assert(PositionMap.new(source))
end

describe("readeck.annotations.highlights", function()
    it("builds Readeck annotation payloads with notes", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            color = "green",
            text = "highlighted text",
            note = "reader note",
            pos0 = "/body/DocFragment/body/main/section/p[2]/text().4",
            pos1 = "/body/DocFragment/body/main/section/p[2]/text().18",
        }, { notes = true, none_color = true })

        assert.are.same({
            text = "highlighted text",
            color = "green",
            note = "reader note",
            start_selector = "section/p[2]",
            start_offset = 4,
            end_selector = "section/p[2]",
            end_offset = 18,
        }, payload)
    end)

    it("orders reversed selections", function()
        local payload = Highlights.build_payload({
            drawer = "underscore",
            text = "highlighted text",
            pos0 = "section/p[3].10",
            pos1 = "section/p[2].1",
        })

        assert.are.equal("section/p[2]", payload.start_selector)
        assert.are.equal(1, payload.start_offset)
        assert.are.equal("section/p[3]", payload.end_selector)
        assert.are.equal(10, payload.end_offset)
    end)

    it("maps KOReader highlight colors to Readeck colors", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            color = "purple",
            text = "highlighted text",
            pos0 = "section/p[2].4",
            pos1 = "section/p[2].18",
        })

        assert.are.equal("blue", payload.color)
    end)

    it("omits notes and downgrades transparent color for legacy servers", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            color = "none",
            text = "highlighted text",
            note = "reader note",
            pos0 = "section/p[2].4",
            pos1 = "section/p[2].18",
        }, { notes = false, none_color = false })

        assert.are.equal("yellow", payload.color)
        assert.is_nil(payload.note)
    end)

    it("keeps transparent color for modern servers", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            color = "none",
            text = "highlighted text",
            pos0 = "section/p[2].4",
            pos1 = "section/p[2].18",
        }, { notes = true, none_color = true })

        assert.are.equal("none", payload.color)
    end)

    it("repairs highlights that start at a line break before text", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            text = "让我们",
            pos0 = "section/section/div[2]/div[8]/div[3]/br.0",
            pos1 = "section/section/div[2]/div[8]/div[3]/span.3",
        })

        assert.are.equal("section/section/div[2]/div[8]/div[3]/span", payload.start_selector)
        assert.are.equal(0, payload.start_offset)
        assert.are.equal("section/section/div[2]/div[8]/div[3]/span", payload.end_selector)
        assert.are.equal(3, payload.end_offset)
    end)

    it("converts KOReader first-text-node selectors to Readeck element selectors", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            text = "edits",
            pos0 = "section/section/p[9]/text()[1].10",
            pos1 = "section/section/p[9]/text()[1].15",
        })

        assert.are.equal("section/section/p[9]", payload.start_selector)
        assert.are.equal("section/section/p[9]", payload.end_selector)
        assert.are.equal(10, payload.start_offset)
        assert.are.equal(15, payload.end_offset)
    end)

    -- text()[2].10 is 10 characters into the text *after* an inline element;
    -- Readeck would read "p[9] offset 10" from the start of the paragraph and
    -- highlight other words. The e2e suite showed the server storing the
    -- wrong text, so such selections are not exported.
    it("refuses selections that start or end in a later text node", function()
        local payload, reason = Highlights.build_payload({
            drawer = "lighten",
            text = "edits",
            pos0 = "section/section/p[9]/text()[2].10",
            pos1 = "section/section/p[9]/text()[2].15",
        })
        assert.is_nil(payload)
        assert.are.equal("unsupported_selector", reason)

        payload = Highlights.build_payload({
            drawer = "lighten",
            text = "edits",
            pos0 = "section/p[1]/text()[1].3",
            pos1 = "section/p[2]/text()[3].4",
        })
        assert.is_nil(payload)
    end)

    -- Current crengine writes absolute xpointers with an explicit index on
    -- every step. The e2e suite found every export rejected with
    -- 'element "/body[1]/DocFragment[1]/..." not found' before this.
    it("strips the indexed KOReader document prefix", function()
        local payload = Highlights.build_payload({
            drawer = "lighten",
            text = "every character",
            pos0 = "/body[1]/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/p[1]/text()[1].44",
            pos1 = "/body[1]/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/p[1]/text()[1].59",
        })
        assert.are.equal("section[1]/article[1]/p[1]", payload.start_selector)
        assert.are.equal(44, payload.start_offset)
        assert.are.equal("section[1]/article[1]/p[1]", payload.end_selector)
        assert.are.equal(59, payload.end_offset)
        assert.are.equal(
            "section[1]/article[1]/p[2]/em[1]",
            Highlights.clean_selector(
                "/body[1]/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/p[2]/em[1]/text()[1]"
            )
        )
        assert.are.equal("section/p[2]", Highlights.clean_selector("/body/DocFragment/body/main/section/p[2]/text()"))
    end)

    it("skips void element boundaries that cannot be repaired", function()
        local payload, reason = Highlights.build_payload({
            drawer = "lighten",
            text = "highlighted text",
            pos0 = "section/p[1]/br.0",
            pos1 = "section/p[2]/span.5",
        })

        assert.is_nil(payload)
        assert.are.equal("unsupported_selector", reason)
    end)

    it("detects overlapping highlights", function()
        local local_highlight = Highlights.build_payload({
            drawer = "lighten",
            text = "local",
            pos0 = "section/p[2].4",
            pos1 = "section/p[2].18",
        })
        local remote_highlight = {
            start_selector = "section/p[2]",
            start_offset = 10,
            end_selector = "section/p[2]",
            end_offset = 20,
        }

        assert.is_true(Highlights.overlap(local_highlight, remote_highlight))
    end)

    it("converts Readeck annotations to xpointers of the downloaded EPUB", function()
        local annotation = Highlights.remote_to_local_annotation({
            id = "remote-id",
            text = "an emphasised phrase in the middle",
            note = "remote note",
            color = "blue",
            start_selector = "section[1]/article[1]/p[2]/em[1]",
            start_offset = 0,
            end_selector = "section[1]/article[1]/p[2]",
            end_offset = 53,
            created = "2026-05-06T17:47:45Z",
        }, nil, inline_map())

        local prefix = "/body/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/p[2]/"
        assert.are.same({
            page = prefix .. "em[1]/text()[1].0",
            pos0 = prefix .. "em[1]/text()[1].0",
            pos1 = prefix .. "text()[2].14",
            text = "an emphasised phrase in the middle",
            chapter = "Notes on Inline Markup",
            note = "remote note",
            datetime = os.date("%Y-%m-%d %H:%M:%S", 1778089665),
            drawer = "lighten",
            color = "blue",
            readeck_annotation_id = "remote-id",
        }, annotation)
    end)

    it("stores Readeck's UTC creation time as local time, like KOReader", function()
        assert.are.equal(os.date("%Y-%m-%d %H:%M:%S", 0), Highlights.local_datetime("1970-01-01T00:00:00Z"))
        assert.are.equal(
            os.date("%Y-%m-%d %H:%M:%S", 86400 + 3600),
            Highlights.local_datetime("1970-01-02T01:00:00.062351Z")
        )
        assert.is_nil(Highlights.local_datetime(nil))
    end)

    it("does not import annotations it cannot place in the EPUB", function()
        local remote = {
            id = "remote-id",
            start_selector = "section[1]/article[1]/p[4]",
            start_offset = 4,
            end_selector = "section[1]/article[1]/p[4]",
            end_offset = 18,
        }
        assert.are.same({ nil, "no_position_map" }, { Highlights.remote_to_local_annotation(remote) })
        remote.start_selector = "section[1]/article[1]/p[9]"
        assert.are.same(
            { nil, "unresolved_position" },
            { Highlights.remote_to_local_annotation(remote, nil, inline_map()) }
        )
    end)

    it("exports selections after inline markup at the right element offset", function()
        local prefix = "/body[1]/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/"
        local payload = Highlights.build_payload({
            drawer = "lighten",
            text = "live in a second text node",
            pos0 = prefix .. "p[2]/text()[2].39",
            pos1 = prefix .. "p[2]/text()[2].65",
        }, {}, inline_map())
        assert.are.equal("section[1]/article[1]/p[2]", payload.start_selector)
        assert.are.equal(78, payload.start_offset)
        assert.are.equal("section[1]/article[1]/p[2]", payload.end_selector)
        assert.are.equal(104, payload.end_offset)

        payload = Highlights.build_payload({
            drawer = "lighten",
            text = "emphasised phrase in the",
            pos0 = prefix .. "p[2]/em[1]/text()[1].3",
            pos1 = prefix .. "p[2]/text()[2].7",
        }, {}, inline_map())
        assert.are.same(
            { "section[1]/article[1]/p[2]/em[1]", 3, "section[1]/article[1]/p[2]", 46 },
            { payload.start_selector, payload.start_offset, payload.end_selector, payload.end_offset }
        )
    end)

    it("refuses exports whose positions are not in the article", function()
        local payload, reason = Highlights.build_payload({
            drawer = "lighten",
            text = "Notes",
            pos0 = "/body[1]/DocFragment[1]/body[1]/h1[1]/text()[1].0",
            pos1 = "/body[1]/DocFragment[1]/body[1]/h1[1]/text()[1].5",
        }, {}, inline_map())
        assert.is_nil(payload)
        assert.are.equal("unsupported_selector", reason)
    end)

    it("detects overlaps between selectors of different elements through the EPUB", function()
        local a = {
            start_selector = "section[1]/article[1]/p[2]/em[1]",
            start_offset = 3,
            end_selector = "section[1]/article[1]/p[2]/em[1]",
            end_offset = 10,
        }
        local b = {
            start_selector = "section[1]/article[1]/p[2]",
            start_offset = 25,
            end_selector = "section[1]/article[1]/p[2]",
            end_offset = 30,
        }
        assert.is_true(Highlights.overlap(a, b, inline_map()))
        b.start_offset, b.end_offset = 29, 45
        assert.is_false(Highlights.overlap(a, b, inline_map()))
    end)

    it("stores sync snapshots when importing Readeck annotations", function()
        local annotation = Highlights.remote_to_local_annotation({
            id = "remote-id",
            text = "remote text",
            note = "remote note",
            color = "green",
            start_selector = "section[1]/article[1]/p[2]",
            start_offset = 4,
            end_selector = "section[1]/article[1]/p[2]",
            end_offset = 15,
        }, { notes = true, none_color = true }, inline_map())

        assert.are.equal("remote note", annotation.readeck_synced_note)
        assert.are.equal("green", annotation.readeck_synced_color)
        assert.is.truthy(annotation.readeck_synced_at)
    end)

    it("plans remote-only linked note and color updates for local annotations", function()
        local plan = Highlights.plan_linked_sync({
            note = "old note",
            color = "yellow",
            readeck_synced_note = "old note",
            readeck_synced_color = "yellow",
        }, {
            note = "remote note",
            color = "blue",
        }, { notes = true, none_color = true }, "merge")

        assert.are.same({ note = "remote note", color = "blue" }, plan.local_update)
        assert.is_nil(plan.remote_update)
        assert.is_false(plan.conflict)
    end)

    it("plans local-only linked note and color updates for Readeck", function()
        local plan = Highlights.plan_linked_sync({
            note = "local note",
            color = "green",
            readeck_synced_note = "old note",
            readeck_synced_color = "yellow",
        }, {
            note = "old note",
            color = "yellow",
        }, { notes = true, none_color = true }, "merge")

        assert.is_nil(plan.local_update)
        assert.are.same({ note = "local note", color = "green" }, plan.remote_update)
        assert.is_false(plan.conflict)
    end)

    it("merges note conflicts and lets local color win by default", function()
        local plan = Highlights.plan_linked_sync({
            note = "local note",
            color = "green",
            readeck_synced_note = "old note",
            readeck_synced_color = "yellow",
        }, {
            note = "remote note",
            color = "blue",
        }, { notes = true, none_color = true }, "merge")

        assert.is.truthy(plan.remote_update.note:find("KOReader note", 1, true))
        assert.is.truthy(plan.remote_update.note:find("Readeck note", 1, true))
        assert.are.equal("green", plan.remote_update.color)
        assert.are.same({ note = plan.remote_update.note }, plan.local_update)
        assert.is_true(plan.conflict)
    end)

    it("can force Readeck or KOReader to win linked highlight updates", function()
        local remote_wins = Highlights.plan_linked_sync({
            note = "local note",
            color = "green",
        }, {
            note = "remote note",
            color = "blue",
        }, { notes = true, none_color = true }, "remote_wins")

        assert.are.same({ note = "remote note", color = "blue" }, remote_wins.local_update)
        assert.is_nil(remote_wins.remote_update)

        local local_wins = Highlights.plan_linked_sync({
            note = "local note",
            color = "green",
        }, {
            note = "remote note",
            color = "blue",
        }, { notes = true, none_color = true }, "local_wins")

        assert.is_nil(local_wins.local_update)
        assert.are.same({ note = "local note", color = "green" }, local_wins.remote_update)
    end)
end)
