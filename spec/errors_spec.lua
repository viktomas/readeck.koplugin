package.path = "./readeck.koplugin/?.lua;" .. package.path

local Errors = require("readeck.net.errors")

describe("readeck.net.errors", function()
    it("exposes the seven error kind constants", function()
        assert.are.equal("network_error", Errors.KIND.NETWORK_ERROR)
        assert.are.equal("file_error", Errors.KIND.FILE_ERROR)
        assert.are.equal("json_error", Errors.KIND.JSON_ERROR)
        assert.are.equal("auth_pending", Errors.KIND.AUTH_PENDING)
        assert.are.equal("auth_error", Errors.KIND.AUTH_ERROR)
        assert.are.equal("http_error", Errors.KIND.HTTP_ERROR)
        assert.are.equal("config_error", Errors.KIND.CONFIG_ERROR)
    end)

    it("builds an error table with kind, code and status", function()
        local err = Errors.new(Errors.KIND.HTTP_ERROR, 404, "404 Not Found")
        assert.are.same({
            kind = "http_error",
            code = 404,
            status = "404 Not Found",
        }, err)
    end)

    it("allows omitting code and status", function()
        local err = Errors.new(Errors.KIND.NETWORK_ERROR)
        assert.are.equal("network_error", err.kind)
        assert.is_nil(err.code)
        assert.is_nil(err.status)
    end)

    it("carries an optional message", function()
        local err = Errors.new(Errors.KIND.HTTP_ERROR, 400, "400 Bad Request", "element not found")
        assert.are.equal("element not found", err.message)
    end)

    -- The three bodies below are verbatim from a real Readeck 0.23.4 server.
    describe("message_from_body", function()
        local decode = require("dkjson").decode

        it("reads the message of a 400 rejection", function()
            assert.are.equal(
                'element "section/p[999]" not found',
                Errors.message_from_body('{"status":400,"message":"element \\"section/p[999]\\" not found"}', decode)
            )
        end)

        it("reads field errors of a 422 with no top-level message", function()
            local body = '{"is_valid":false,"errors":null,"fields":{"title":{"value":"","errors":null},'
                .. '"url":{"value":"","errors":["field is required"]}}}'
            assert.are.equal("url: field is required", Errors.message_from_body(body, decode))
        end)

        it("reads a short plain-text body such as 401 Unauthorized", function()
            assert.are.equal("Unauthorized", Errors.message_from_body("Unauthorized", decode))
            assert.are.equal("Not Found", Errors.message_from_body("Not Found", decode))
        end)

        it("orders field errors deterministically", function()
            local body = '{"fields":{"url":{"errors":["field is required"]},"title":{"errors":["too long"]}}}'
            assert.are.equal("title: too long, url: field is required", Errors.message_from_body(body, decode))
        end)

        it("ignores a proxy HTML error page", function()
            assert.is_nil(Errors.message_from_body("<html><body>502 Bad Gateway</body></html>", decode))
        end)

        it("accepts a callable table decoder, as KOReader's json.decode is", function()
            local callable = setmetatable({}, {
                __call = function(_, body)
                    return decode(body)
                end,
            })
            assert.are.equal("Not Found", Errors.message_from_body('{"status":404,"message":"Not Found"}', callable))
        end)

        it("never shows raw JSON when no usable decoder is available", function()
            assert.is_nil(Errors.message_from_body('{"status":404,"message":"Not Found"}', nil))
        end)

        it("ignores an empty, absent or unparsable body", function()
            assert.is_nil(Errors.message_from_body("", decode))
            assert.is_nil(Errors.message_from_body(nil, decode))
            assert.is_nil(Errors.message_from_body("{not json", decode))
        end)

        it("truncates a message too long for a dialog", function()
            local body = '{"message":"' .. string.rep("x", 400) .. '"}'
            local message = Errors.message_from_body(body, decode)
            assert.are.equal(200, #message:gsub("\226\128\166", "x"))
        end)
    end)

    it("returns a fresh table on every call", function()
        local first = Errors.new(Errors.KIND.JSON_ERROR)
        local second = Errors.new(Errors.KIND.JSON_ERROR)
        assert.are_not.equal(first, second)
        assert.are.same(first, second)
    end)
end)
