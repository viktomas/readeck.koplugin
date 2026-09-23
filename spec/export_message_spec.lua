package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- Covers what the user is actually told when a highlight export fails.
-- Before this, every rejection collapsed to a bare "Failed: 1", which reads
-- the same whether the server refused the selector or the network dropped.

local function new_readeck()
    install_koreader_stubs()
    local Export = require("readeck.annotations.export")
    local Readeck = {}
    Export.install(Readeck, {
        L = function(text)
            return text
        end,
        T = function(text, ...)
            local args = { ... }
            return (
                text:gsub("%%(%d)", function(index)
                    return tostring(args[tonumber(index)])
                end)
            )
        end,
        Log = { info = function() end, debug = function() end, warn = function() end, error = function() end },
    })
    return Readeck
end

describe("Readeck:formatHighlightSyncMessage", function()
    it("shows the server's reason next to the failure count", function()
        local readeck = new_readeck()
        local message = readeck:formatHighlightSyncMessage({
            error = 1,
            error_message = 'element "section/p[1]" not found',
        })
        assert.is.truthy(message:find('Failed: 1 (element "section/p[1]" not found)', 1, true))
    end)

    it("falls back to the bare count when the server explained nothing", function()
        local readeck = new_readeck()
        local message = readeck:formatHighlightSyncMessage({ error = 2 })
        assert.is.truthy(message:find("Failed: 2", 1, true))
        assert.is_nil(message:find("(", 1, true))
    end)
end)

describe("highlight count merging", function()
    -- add_highlight_counts sums with `tonumber(value) or 0`, which would turn a
    -- text reason into 0 as soon as two articles' counts were merged.
    it("keeps the first reason instead of coercing it to a number", function()
        install_koreader_stubs()
        local Export = require("readeck.annotations.export")
        local merged = Export.add_highlight_counts(nil, { error = 1, error_message = "first reason" })
        merged = Export.add_highlight_counts(merged, { error = 1, error_message = "second reason" })

        assert.are.equal(2, merged.error)
        assert.are.equal("first reason", merged.error_message)
    end)
end)

describe("Export.highlight_failure_message", function()
    install_koreader_stubs()
    local Export = require("readeck.annotations.export")

    it("prefers the export error reason", function()
        assert.are.equal(
            "boom",
            Export.highlight_failure_message({ error = 1, error_message = "boom", import_error_message = "other" })
        )
    end)

    it("falls back to the import error reason", function()
        assert.are.equal("boom", Export.highlight_failure_message({ import_failed = 1, import_error_message = "boom" }))
    end)

    it("returns nil when there is no reason, or no counts at all", function()
        assert.is_nil(Export.highlight_failure_message({ error = 1 }))
        assert.is_nil(Export.highlight_failure_message(nil))
    end)
end)
