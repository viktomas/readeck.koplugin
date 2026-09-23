package.path = "./readeck.koplugin/?.lua;" .. package.path

local Tags = require("readeck.core.tags")

describe("readeck.core.tags", function()
    it("splits on commas and trims each tag", function()
        assert.are.same({ "koreader", "from device" }, Tags.split("koreader, from device"))
    end)

    -- The bug this module replaced: gsub's second return value turned
    -- table.insert(tags, tag) into table.insert(tags, tag, count) and raised.
    it("returns plain strings, one entry per tag", function()
        local tags = Tags.split(" a ,b")
        assert.are.equal(2, #tags)
        assert.are.equal("a", tags[1])
        assert.are.equal("b", tags[2])
    end)

    it("drops empty entries", function()
        assert.are.same({ "a", "b" }, Tags.split("a,, ,b,"))
    end)

    it("handles nil and empty input", function()
        assert.are.same({}, Tags.split(nil))
        assert.are.same({}, Tags.split(""))
    end)
end)
