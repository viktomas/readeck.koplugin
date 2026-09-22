local VERSION = require("readeck.version")
local _ = require("gettext")
local L = require("readeck.i18n").with_gettext(_, function()
    return G_reader_settings
end)

return {
    name = "readeck",
    version = VERSION,
    fullname = L("Readeck"),
    description = L([[Synchronises articles with a Readeck server.]]),
}
