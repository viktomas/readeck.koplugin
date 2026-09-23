-- Downloads are written next to their final name and renamed into place only
-- once complete. A connection that drops halfway (or a reader that powers
-- off) used to leave a truncated EPUB under the article's own name, which
-- every later sync skipped as "already downloaded".
--
-- The partial name is a dotfile (hidden in KOReader's file browser) and
-- deliberately does not contain " [rd-id_": everything that scans the
-- download directory for articles goes through getArticleID, and must never
-- mistake a half-written file for one.

local Defaults = require("readeck.core.defaults")

local PartialFile = {}

local function escape_pattern(text)
    return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local ID_PATTERN = escape_pattern(Defaults.ARTICLE_ID_SUFFIX) .. "(.-)" .. escape_pattern(Defaults.ARTICLE_ID_POSTFIX)

function PartialFile.path_for(filepath)
    local directory, name = tostring(filepath):match("^(.*/)([^/]*)$")
    if not directory then
        directory, name = "", tostring(filepath)
    end
    local key = name:match(ID_PATTERN)
    if not key or key == "" then
        -- Not an article filename: keep it short and free of the id marker.
        key = name:gsub("[^%w%-_]", ""):sub(1, 64)
    end
    return directory .. ".readeck-" .. key .. ".part"
end

-- Moves a completed download into place. Returns true, or nil and a reason.
function PartialFile.commit(part_path, filepath)
    local ok, err = os.rename(part_path, filepath)
    if not ok then
        os.remove(part_path)
        return nil, err
    end
    return true
end

function PartialFile.discard(part_path)
    os.remove(part_path)
end

return PartialFile
