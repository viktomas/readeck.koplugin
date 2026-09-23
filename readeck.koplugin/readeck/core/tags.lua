-- Parses a user-typed, comma-separated tag list ("koreader, from device").
--
-- Both callers used to do `table.insert(tags, tag:gsub(...))`. `gsub` returns
-- two values (the string and the match count), so that became
-- `table.insert(tags, "koreader", 1)` and raised "bad argument #2 to 'insert'":
-- "Tags to add to new articles" broke adding every article, and "Send review
-- as tags" broke every sync. Found by the e2e suite (e2e/tests/labels_test.lua).

local Tags = {}

function Tags.split(text)
    local tags = {}
    if type(text) ~= "string" then
        return tags
    end
    for tag in text:gmatch("[^,]+") do
        local trimmed = tag:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(tags, trimmed)
        end
    end
    return tags
end

return Tags
