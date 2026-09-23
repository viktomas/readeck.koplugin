-- Pure decision: may the local copy of a bookmark be removed because the
-- bookmark is gone from Readeck?
--
-- "Remove local files missing from Readeck" used to treat every local article
-- that was absent from the sync's *fetched list* as deleted. That list is not
-- the account: it is capped by articles_per_sync, and Readeck leaves a
-- bookmark that is still loading out of `type=article` listings (its
-- document type is only known once extraction finishes). Both made the
-- cleanup delete articles that still exist on the server - found by the e2e
-- suite against a real Readeck (e2e/tests/remote_changes_test.lua).
--
-- So a local file absent from the list is only removed once the server
-- confirms, for that one bookmark, that it is gone: 404/410, archived, or
-- pending deletion. Anything else - it exists, or the answer is unknown
-- (network error, auth failure, 5xx) - keeps the file: deleting is the
-- irreversible direction, so it needs positive evidence.

local Errors = require("readeck.net.errors")

local RemotePresence = {}

-- `bookmark`, `err` are what Api:get_bookmark returned.
function RemotePresence.should_remove_local(bookmark, err)
    if type(bookmark) == "table" then
        return bookmark.is_archived == true or bookmark.is_deleted == true
    end
    if type(err) == "table" and err.kind == Errors.KIND.HTTP_ERROR and (err.code == 404 or err.code == 410) then
        return true
    end
    return false
end

return RemotePresence
