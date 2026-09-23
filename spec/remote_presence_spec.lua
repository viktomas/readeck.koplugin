package.path = "./readeck.koplugin/?.lua;" .. package.path

local Errors = require("readeck.net.errors")
local RemotePresence = require("readeck.sync.remote_presence")

-- Deleting a local article is irreversible, so "missing from Readeck" needs
-- positive evidence from the server. The e2e suite found the cleanup deleting
-- articles that were merely outside the fetched batch or still loading.
describe("readeck.sync.remote_presence", function()
    local remove = RemotePresence.should_remove_local

    it("removes when the server says the bookmark does not exist", function()
        assert.is_true(remove(nil, Errors.new(Errors.KIND.HTTP_ERROR, 404)))
        assert.is_true(remove(nil, Errors.new(Errors.KIND.HTTP_ERROR, 410)))
    end)

    it("removes archived bookmarks and bookmarks pending deletion", function()
        assert.is_true(remove({ id = "a", is_archived = true }))
        assert.is_true(remove({ id = "a", is_deleted = true }))
    end)

    it("keeps a bookmark that exists and is not archived, e.g. still loading", function()
        assert.is_false(remove({ id = "a", is_archived = false, is_deleted = false, state = 2, loaded = false }))
        assert.is_false(remove({ id = "a" }))
    end)

    it("keeps the file whenever the answer is unknown", function()
        assert.is_false(remove(nil, Errors.new(Errors.KIND.NETWORK_ERROR)))
        assert.is_false(remove(nil, Errors.new(Errors.KIND.AUTH_ERROR, 401)))
        assert.is_false(remove(nil, Errors.new(Errors.KIND.HTTP_ERROR, 500)))
        assert.is_false(remove(nil, Errors.new(Errors.KIND.JSON_ERROR, 200)))
        assert.is_false(remove(nil, nil))
        -- callAPI answers `true` for an empty 2xx body: not evidence of anything.
        assert.is_false(remove(true, nil))
    end)
end)
