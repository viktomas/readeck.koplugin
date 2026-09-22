local VERSION = require("readeck.version")
local _ = require("gettext")
local L = require("readeck.i18n").with_gettext(_, function()
    return G_reader_settings
end)

-- No `name` field: KOReader derives the plugin name from the directory
-- (readeck.koplugin -> readeck) and PluginLoader explicitly ignores a `name`
-- here, logging a deprecation warning on every startup if one is present.
return {
    version = VERSION,
    fullname = L("Readeck"),
    description = L([[Synchronises articles with a Readeck server.]]),
}
