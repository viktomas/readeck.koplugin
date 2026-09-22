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

    it("returns a fresh table on every call", function()
        local first = Errors.new(Errors.KIND.JSON_ERROR)
        local second = Errors.new(Errors.KIND.JSON_ERROR)
        assert.are_not.equal(first, second)
        assert.are.same(first, second)
    end)
end)
