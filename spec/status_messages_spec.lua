package.path = "./readeck.koplugin/?.lua;" .. package.path

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
            readeck:formatAPIErrorMessage("auth_error")
        )
    end)

    it("maps json_error to a localised message", function()
        local readeck = new_readeck()
        assert.are.equal("Server response is not valid.", readeck:formatAPIErrorMessage("json_error"))
    end)

    it("maps http_error to a localised message", function()
        local readeck = new_readeck()
        assert.are.equal("Communication with server failed.", readeck:formatAPIErrorMessage("http_error"))
    end)

    it("returns nil for dialects with no dialog", function()
        local readeck = new_readeck()
        assert.is_nil(readeck:formatAPIErrorMessage("network_error"))
        assert.is_nil(readeck:formatAPIErrorMessage("file_error"))
        assert.is_nil(readeck:formatAPIErrorMessage("auth_pending"))
    end)

    it("returns nil for unknown or missing dialects", function()
        local readeck = new_readeck()
        assert.is_nil(readeck:formatAPIErrorMessage(nil))
        assert.is_nil(readeck:formatAPIErrorMessage("something_else"))
    end)
end)
