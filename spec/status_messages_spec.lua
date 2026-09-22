package.path = "./readeck.koplugin/?.lua;" .. package.path

local Errors = require("readeck.net.errors")
local StatusMessages = require("readeck.ui.status_messages")

describe("readeck.ui.status_messages", function()
    local function new_readeck()
        local Readeck = {}
        StatusMessages.install(Readeck, {
            L = function(text)
                return text
            end,
            T = function(text)
                return text
            end,
        })
        return Readeck
    end

    it("maps auth_error to a localised message", function()
        local readeck = new_readeck()
        assert.are.equal(
            "Authentication failed. Please check your OAuth or API token settings.",
            readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.AUTH_ERROR))
        )
    end)

    it("maps json_error to a localised message", function()
        local readeck = new_readeck()
        assert.are.equal(
            "Server response is not valid.",
            readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.JSON_ERROR))
        )
    end)

    it("maps http_error to a localised message", function()
        local readeck = new_readeck()
        assert.are.equal(
            "Communication with server failed.",
            readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.HTTP_ERROR))
        )
    end)

    it("returns nil for dialects with no dialog", function()
        local readeck = new_readeck()
        assert.is_nil(readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.NETWORK_ERROR)))
        assert.is_nil(readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.FILE_ERROR)))
        assert.is_nil(readeck:formatAPIErrorMessage(Errors.new(Errors.KIND.AUTH_PENDING)))
    end)

    it("returns nil for unknown or missing dialects", function()
        local readeck = new_readeck()
        assert.is_nil(readeck:formatAPIErrorMessage(nil))
        assert.is_nil(readeck:formatAPIErrorMessage({ kind = "something_else" }))
    end)
end)
