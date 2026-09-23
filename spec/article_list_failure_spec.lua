package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- The sync used to answer every article-list failure with the same bare
-- "Requesting article list failed.", so a wrong API token, a server that is
-- down and a server-side bug all looked identical. Found by the e2e suite
-- (e2e/tests/auth_test.lua, errors_test.lua) against a real Readeck.
describe("Readeck:formatArticleListFailure", function()
    local Errors, instance

    before_each(function()
        install_koreader_stubs()
        Errors = require("readeck.net.errors")
        local Readeck = dofile("readeck.koplugin/main.lua")
        instance = setmetatable({}, { __index = Readeck })
    end)

    it("names an authentication failure", function()
        local text = instance:formatArticleListFailure(Errors.new(Errors.KIND.AUTH_ERROR, 401))
        assert.are.equal(
            "Requesting article list failed.\nAuthentication failed. Please check your OAuth or API token settings.",
            text
        )
    end)

    it("says the server could not be reached on a network error", function()
        local text = instance:formatArticleListFailure(Errors.new(Errors.KIND.NETWORK_ERROR))
        assert.matches("^Requesting article list failed%.\nCould not reach the Readeck server%.", text)
    end)

    it("carries the server's reason for an HTTP error", function()
        local err = Errors.new(Errors.KIND.HTTP_ERROR, 500, "500", "database is locked")
        local text = instance:formatArticleListFailure(err)
        assert.matches("Server said: database is locked", text, 1, true)
    end)

    it("stays the bare message when nothing is known", function()
        assert.are.equal("Requesting article list failed.", instance:formatArticleListFailure(nil))
    end)
end)
