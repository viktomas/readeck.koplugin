package.path = "./readeck.koplugin/?.lua;" .. package.path

local Api = require("readeck.net.api")

describe("readeck.net.api", function()
    it("builds bookmark list URLs", function()
        assert.are.equal(
            "/api/bookmarks?limit=30&offset=0&is_archived=0&type=article&labels=research%20notes&sort=-created",
            Api.bookmarks_query({
                limit = 30,
                offset = 0,
                is_archived = 0,
                type = "article",
                labels = "research notes",
                sort = "-created",
            })
        )
    end)

    it("normalizes a server URL typed on an e-reader keyboard", function()
        assert.are.equal("http://n:8112", Api.normalize_server_url(" http://n:8112/ "))
        assert.are.equal("https://r.example/readeck", Api.normalize_server_url("https://r.example/readeck/api/"))
        assert.are.equal("https://r.example", Api.normalize_server_url("https://r.example//"))
        assert.are.equal("https://r.example/apis", Api.normalize_server_url("https://r.example/apis"))
        assert.are.equal("", Api.normalize_server_url(nil))
    end)

    it("sends the filter tag as one exact Readeck search term", function()
        assert.are.equal('"research notes"', Api.label_filter(" research notes "))
        assert.are.equal('"-later"', Api.label_filter("-later"))
        assert.are.equal('"a\\"b"', Api.label_filter('a"b'))
        assert.is_nil(Api.label_filter(""))
        assert.is_nil(Api.label_filter("   "))
        assert.is_nil(Api.label_filter(nil))
        assert.are.equal(
            "/api/bookmarks?labels=%22research%20notes%22",
            Api.bookmarks_query({ labels = Api.label_filter("research notes") })
        )
    end)

    it("can be tested with a mock Readeck transport", function()
        local requests = {}
        local client = Api.new(function(request)
            table.insert(requests, request)
            if request.path == Api.paths.info then
                return { version = { canonical = "0.22.2" } }, nil
            end
            if request.path == Api.paths.annotations("abc") and request.method == "POST" then
                return { id = "annotation-id", note = request.body.note }
            end
            if request.path == Api.paths.annotation("abc", "annotation-id") and request.method == "PATCH" then
                return { annotations = { { id = "annotation-id", note = request.body.note } } }
            end
            if request.path == Api.paths.bookmark_article("abc") then
                return "EPUB"
            end
            return true
        end)

        local info = client:get_info()
        local annotation = client:create_annotation("abc", { note = "reader note" })
        local updated = client:update_annotation("abc", "annotation-id", { note = "updated note" })
        local epub = client:download_article("abc")

        assert.are.equal("0.22.2", info.version.canonical)
        assert.are.equal("reader note", annotation.note)
        assert.are.equal("updated note", updated.annotations[1].note)
        assert.are.equal("EPUB", epub)
        assert.are.same({
            -- get_info is deliberately unauthenticated: headers = {} tells the
            -- client to send no Authorization header at all.
            { method = "GET", path = "/api/info", headers = {} },
            -- every other request leaves headers nil, so the client adds the
            -- Bearer token itself.
            {
                method = "POST",
                path = "/api/bookmarks/abc/annotations",
                body = { note = "reader note" },
            },
            {
                method = "PATCH",
                path = "/api/bookmarks/abc/annotations/annotation-id",
                body = { note = "updated note" },
            },
            { method = "GET", path = "/api/bookmarks/abc/article.epub" },
        }, requests)
    end)

    it("does not send explicit headers on authenticated requests", function()
        local requests = {}
        local client = Api.new(function(request)
            table.insert(requests, request)
            return true
        end)

        client:list_bookmarks({ limit = 10 })
        client:create_bookmark({ url = "https://example.com" })
        client:update_bookmark("42", { is_archived = true })
        client:delete_bookmark("42")

        for _, request in ipairs(requests) do
            assert.is_nil(request.headers)
        end
    end)

    it("supports update_bookmark and delete_bookmark", function()
        local requests = {}
        local client = Api.new(function(request)
            table.insert(requests, request)
            return true
        end)

        client:update_bookmark("42", { is_archived = true })
        client:delete_bookmark("42")

        assert.are.same({
            { method = "PATCH", path = "/api/bookmarks/42", body = { is_archived = true } },
            { method = "DELETE", path = "/api/bookmarks/42" },
        }, requests)
    end)

    it("passes filepath through for streamed downloads", function()
        local requests = {}
        local client = Api.new(function(request)
            table.insert(requests, request)
            return true
        end)

        local ok = client:download_article("abc", "/tmp/article.epub")

        assert.is_true(ok)
        assert.are.same({
            { method = "GET", path = "/api/bookmarks/abc/article.epub", filepath = "/tmp/article.epub" },
        }, requests)
    end)

    it("propagates a transport error as the second return value", function()
        local boom = { kind = "network_error" }
        local client = Api.new(function()
            return nil, boom
        end)

        local value, err = client:list_bookmarks()

        assert.is_nil(value)
        assert.are.equal(boom, err)
    end)

    -- Bookmark creation answers 202 with the new id in a `Bookmark-Id` or
    -- `Location` header, not the (empty) body; without this the id was
    -- unreachable by create_bookmark's callers.
    describe("bookmark_id_from_headers", function()
        it("reads the Bookmark-Id header", function()
            assert.are.equal("42", Api.bookmark_id_from_headers({ ["bookmark-id"] = "42" }))
        end)

        it("falls back to the id at the end of a Location header", function()
            assert.are.equal("42", Api.bookmark_id_from_headers({ ["location"] = "/api/bookmarks/42" }))
            assert.are.equal("42", Api.bookmark_id_from_headers({ ["location"] = "/api/bookmarks/42/" }))
        end)

        it("returns nil when neither header is present or the value is unusable", function()
            assert.is_nil(Api.bookmark_id_from_headers({}))
            assert.is_nil(Api.bookmark_id_from_headers(nil))
            assert.is_nil(Api.bookmark_id_from_headers({ ["bookmark-id"] = "" }))
            assert.is_nil(Api.bookmark_id_from_headers({ ["location"] = "/api/bookmarks/" }))
        end)
    end)

    describe("create_bookmark", function()
        it("puts the id from the Bookmark-Id header onto the result", function()
            local client = Api.new(function()
                return true, nil, { ["bookmark-id"] = "42" }
            end)

            local result = client:create_bookmark({ url = "https://example.com" })

            assert.are.same({ id = "42" }, result)
        end)

        it("puts the id from a Location header onto the result", function()
            local client = Api.new(function()
                return true, nil, { ["location"] = "/api/bookmarks/42" }
            end)

            local result = client:create_bookmark({ url = "https://example.com" })

            assert.are.same({ id = "42" }, result)
        end)

        it("does not override an id already present in the body", function()
            local client = Api.new(function()
                return { id = "from-body" }, nil, { ["bookmark-id"] = "from-header" }
            end)

            local result = client:create_bookmark({ url = "https://example.com" })

            assert.are.equal("from-body", result.id)
        end)

        it("leaves the result untouched when there is no header and no body id", function()
            local client = Api.new(function()
                return true
            end)

            local result = client:create_bookmark({ url = "https://example.com" })

            assert.is_true(result)
        end)

        it("does not touch the result on error", function()
            local boom = { kind = "http_error", code = 400 }
            local client = Api.new(function()
                return nil, boom, { ["bookmark-id"] = "42" }
            end)

            local result, err = client:create_bookmark({ url = "https://example.com" })

            assert.is_nil(result)
            assert.are.equal(boom, err)
        end)
    end)
end)
