package.path = "./readeck.koplugin/?.lua;" .. package.path

local PositionMap = require("readeck.annotations.position_map")
local Xhtml = require("readeck.annotations.xhtml")

-- Chapter files of EPUBs downloaded from a real Readeck 0.23.4, for the
-- pages in e2e/fixtures/site. The "marked" and "notes" ones were exported
-- after annotations were made in Readeck, so they carry Readeck's <mark>
-- wrappers and noteref links.
local function fixture(name)
    local file = assert(io.open("spec/fixtures/readeck_epub/" .. name .. ".html", "rb"))
    local source = file:read("*a")
    file:close()
    return assert(PositionMap.new(source))
end

local PREFIX = "/body/DocFragment[1]/body[1]/main[1]/section[1]/article[1]/"
local ARTICLE = "section[1]/article[1]/"

local function readeck_text(map, selector0, offset0, selector1, offset1)
    return map:readeck_text(
        assert(map:readeck_to_global(ARTICLE .. selector0, offset0)),
        assert(map:readeck_to_global(ARTICLE .. selector1, offset1))
    )
end

describe("readeck.annotations.xhtml", function()
    it("decodes entities and keeps raw whitespace", function()
        local doc = Xhtml.parse("<p>Fish &amp; chips\n  &#34;x&#34; &lt;y&gt;&nbsp;&#x1F389;</p>")
        local p = doc.children[1]
        assert.are.equal('Fish & chips\n  "x" <y>\194\160\240\159\142\137', p.children[1].text)
    end)

    it("copes with void elements, self-closing tags and stray end tags", function()
        local doc = Xhtml.parse("<div><p>a<br>b<img src='x>y'/>c</span></p><p>d</p></div>")
        local div = doc.children[1]
        assert.are.equal(2, #div.children)
        local p = div.children[1]
        assert.are.equal(5, #p.children)
        assert.are.equal("x>y", p.children[4].attrs.src)
        assert.are.equal("c", p.children[5].text)
    end)
end)

describe("readeck.annotations.epub_source", function()
    local EpubSource = require("readeck.annotations.epub_source")

    local function epub(files)
        return function(name)
            return files[name]
        end
    end

    local container = '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>'

    it("finds the article chapter through the spine and uses its position as DocFragment", function()
        local file = assert(io.open("spec/fixtures/readeck_epub/inline.html", "rb"))
        local chapter = file:read("*a")
        file:close()
        local map = EpubSource.build(epub({
            ["META-INF/container.xml"] = container,
            ["OEBPS/content.opf"] = [[<package><manifest>
                <item id="cover" href="Text/cover.html"/>
                <item id="page" href="Text/My%20Page.html"/>
                </manifest><spine><itemref idref="cover"/><itemref idref="page"/></spine></package>]],
            ["OEBPS/Text/cover.html"] = "<html><body><p>cover</p></body></html>",
            ["OEBPS/Text/My Page.html"] = chapter,
        }))
        assert.are.equal(2, map.doc_fragment)
        assert.are.equal(
            "/body/DocFragment[2]/body[1]/main[1]/section[1]/article[1]/p[1]/text()[1].4",
            map:to_xpointer(ARTICLE .. "p[1]", 4)
        )
    end)

    it("reports EPUBs it cannot use", function()
        assert.are.same({ nil, "no_container" }, { EpubSource.build(epub({})) })
        assert.are.same({ nil, "no_article" }, {
            EpubSource.build(epub({
                ["META-INF/container.xml"] = container,
                ["OEBPS/content.opf"] = '<package><manifest><item id="a" href="a.html"/></manifest>'
                    .. '<spine><itemref idref="a"/></spine></package>',
                ["OEBPS/a.html"] = "<html><body><p>not a Readeck article</p></body></html>",
            })),
        })
    end)
end)

describe("readeck.annotations.position_map", function()
    it("counts code points, not bytes", function()
        assert.are.equal(3, PositionMap.char_length("日本語"))
        assert.are.equal(2, PositionMap.char_length("🎉x"))
    end)

    it("finds Readeck's text for annotations the server resolved", function()
        -- `text` as returned by Readeck when these annotations were created.
        local map = fixture("markup-marked")
        assert.are.equal("paragraph\n   was wrapped ", readeck_text(map, "p[2]", 5, "p[2]", 30))
        assert.are.equal("nested emphas", readeck_text(map, "p[1]/strong[1]/em[1]", 0, "p[1]", 60))
        assert.are.equal(
            " 日本語のテキスト and 🎉 emoji 🚀 before",
            readeck_text(map, "p[5]", 50, "p[5]", 80)
        )

        map = fixture("markup-notes")
        assert.are.equal("phasis starts this paragraph, then a nes", readeck_text(map, "p[1]", 10, "p[1]/strong[1]", 5))
        assert.are.equal("item with emphasis and a", readeck_text(map, "ul[1]/li[1]", 6, "ul[1]/li[1]", 30))
    end)

    it("maps Readeck positions into Readeck's own <mark> wrappers", function()
        local map = fixture("markup-marked")
        assert.are.equal(PREFIX .. "p[2]/mark[1]/text()[1].0", map:to_xpointer(ARTICLE .. "p[2]", 5))
        -- 25 raw characters, "paragraph\n   was wrapped ", are 22 in crengine.
        assert.are.equal(PREFIX .. "p[2]/mark[1]/text()[1].22", map:to_xpointer(ARTICLE .. "p[2]", 30, true))
        assert.are.equal(PREFIX .. "p[5]/mark[1]/text()[1].0", map:to_xpointer(ARTICLE .. "p[5]", 50))
    end)

    it("does not count noteref links, which only exist in the EPUB", function()
        local map = fixture("markup-marked")
        -- "over several lines" follows <a epub:type="noteref">1</a>.
        assert.are.equal(PREFIX .. "p[2]/text()[2].0", map:to_xpointer(ARTICLE .. "p[2]", 30))
        assert.are.same({ ARTICLE .. "p[2]", 30 }, { map:to_readeck(PREFIX .. "p[2]/text()[2].0") })
        assert.are.same({ ARTICLE .. "p[2]", 34 }, { map:to_readeck(PREFIX .. "p[2]/text()[2].4", true) })
        -- A selection starting on the footnote number starts after it.
        assert.are.same({ ARTICLE .. "p[2]", 30 }, { map:to_readeck(PREFIX .. "p[2]/a[1]/text()[1].0") })
    end)

    it("translates collapsed crengine offsets to raw Readeck offsets", function()
        local map = fixture("markup-marked")
        -- What crengine's findText returned for "was wrapped" in this EPUB.
        local s, so = map:to_readeck(PREFIX .. "p[2]/mark[1]/text()[1].10")
        local e, eo = map:to_readeck(PREFIX .. "p[2]/mark[1]/text()[1].21", true)
        assert.are.same({ ARTICLE .. "p[2]", 18, ARTICLE .. "p[2]", 29 }, { s, so, e, eo })
        assert.are.equal("was wrapped", readeck_text(map, "p[2]", so, "p[2]", eo))
        -- "with   runs of" further on: three raw spaces are one crengine space.
        local plain = fixture("markup-notes")
        local start_selector, start_offset = plain:to_readeck(PREFIX .. "p[2]/text()[1].61")
        local end_selector, end_offset = plain:to_readeck(PREFIX .. "p[2]/text()[1].73", true)
        assert.are.equal("with   runs of", readeck_text(plain, "p[2]", start_offset, "p[2]", end_offset))
        assert.are.equal(ARTICLE .. "p[2]", start_selector)
        assert.are.equal(ARTICLE .. "p[2]", end_selector)
    end)

    it("uses the text node's own element, like Readeck's web reader", function()
        local map = fixture("inline")
        -- "live in a second text node" is after <em> in paragraph 2.
        assert.are.same({ ARTICLE .. "p[2]", 78 }, { map:to_readeck(PREFIX .. "p[2]/text()[2].39") })
        assert.are.same({ ARTICLE .. "p[2]/em[1]", 3 }, { map:to_readeck(PREFIX .. "p[2]/em[1]/text()[1].3") })
        assert.are.same({ ARTICLE .. "p[3]/a[1]", 4 }, { map:to_readeck(PREFIX .. "p[3]/a[1]/text()[1].4", true) })
        assert.are.equal(PREFIX .. "p[2]/text()[2].39", map:to_xpointer(ARTICLE .. "p[2]", 78))
        assert.are.equal(PREFIX .. "p[2]/em[1]/text()[1].3", map:to_xpointer(ARTICLE .. "p[2]/em[1]", 3))
    end)

    it("prefers the next node for a start and the previous one for an end", function()
        local map = fixture("inline")
        -- Offset 19 in paragraph 2 is exactly where <em> begins.
        assert.are.equal(PREFIX .. "p[2]/em[1]/text()[1].0", map:to_xpointer(ARTICLE .. "p[2]", 19))
        assert.are.equal(PREFIX .. "p[2]/text()[1].19", map:to_xpointer(ARTICLE .. "p[2]", 19, true))
    end)

    it("accepts the bare xpointer form of older crengine DOM versions", function()
        local map = fixture("inline")
        assert.are.same(
            { ARTICLE .. "p[2]", 78 },
            { map:to_readeck("/body/DocFragment/body/main/section/article/p[2]/text()[2].39") }
        )
        assert.are.same(
            { ARTICLE .. "p[1]", 4 },
            { map:to_readeck("/body/DocFragment/body/main/section/article/p/text().4") }
        )
    end)

    it("drops whitespace-only text nodes among blocks, as crengine does", function()
        local map = fixture("markup-notes")
        -- <blockquote>\n<p>...</p>\n</blockquote>: the p text is the only text()
        assert.are.equal(
            PREFIX .. "blockquote[1]/p[1]/text()[1].2",
            map:to_xpointer(ARTICLE .. "blockquote[1]/p[1]", 2)
        )
        -- <p>\n    Indented ...: the leading run is one crengine space.
        assert.are.equal(PREFIX .. "p[6]/text()[1].1", map:to_xpointer(ARTICLE .. "p[6]", 5))
        -- ...<em>spaced</em> <strong>: the single space between is its own node.
        assert.are.equal(PREFIX .. "p[6]/strong[1]/text()[1].0", map:to_xpointer(ARTICLE .. "p[6]/strong[1]", 0))
        assert.are.same({ ARTICLE .. "p[6]", 51 }, { map:to_readeck(PREFIX .. "p[6]/text()[2].0") })
    end)

    it("refuses positions outside the article or past an element's text", function()
        local map = fixture("inline")
        assert.is_nil(map:to_xpointer(ARTICLE .. "p[9]", 0))
        assert.is_nil(map:to_xpointer(ARTICLE .. "p[1]", 5000))
        assert.is_nil(map:to_readeck("/body/DocFragment[1]/body[1]/h1[1]/text()[1].2"))
        assert.is_nil(map:to_readeck("/body/DocFragment[2]/body[1]/main[1]/section[1]/article[1]/p[1]/text()[1].2"))
        assert.is_nil(map:to_readeck(PREFIX .. "p[1]/text()[1].999"))
    end)

    it("reads the Readeck 0.21 EPUB template (no marks, class list on <main>)", function()
        local map = fixture("markup-0.21.6")
        assert.are.equal("Nested Markup and Other Text", map.title)
        -- Readeck 0.21.6 answered text "paragraph\n   was wrapped" for p[2] 5..30.
        assert.are.equal("paragraph\n   was wrapped ", readeck_text(map, "p[2]", 5, "p[2]", 30))
        assert.are.equal(PREFIX .. "p[2]/text()[1].5", map:to_xpointer(ARTICLE .. "p[2]", 5))
        assert.are.equal(PREFIX .. "p[2]/text()[1].27", map:to_xpointer(ARTICLE .. "p[2]", 30, true))
    end)

    it("round-trips every crengine position in every fixture", function()
        for _, name in ipairs({ "inline", "markup-marked", "markup-notes", "markup-0.21.6" }) do
            local map = fixture(name)
            for _, piece in ipairs(map.pieces) do
                if piece.kept and piece.counted and piece.length > 0 then
                    local path = map:crengine_path(piece.parent) .. "/text()[" .. piece.cre_k .. "]."
                    for offset = 0, piece.cre_length do
                        for _, is_end in ipairs({ false, true }) do
                            local boundary = (is_end and offset == 0) or (not is_end and offset == piece.cre_length)
                            if not boundary then
                                local xp = path .. offset
                                local selector, readeck_offset = map:to_readeck(xp, is_end)
                                assert.is_truthy(selector, name .. " " .. xp)
                                assert.are.equal(
                                    xp,
                                    map:to_xpointer(selector, readeck_offset, is_end),
                                    name .. " " .. xp .. (is_end and " (end)" or "")
                                )
                            end
                        end
                    end
                end
            end
        end
    end)
end)
