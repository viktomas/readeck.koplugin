local DataStorage = require("datastorage")
local Defaults = require("readeck.core.defaults")
local LuaSettings = require("frontend/luasettings")

local Settings = {}

function Settings.install(Readeck)
    -- The legacy `is_*` aliases of the completion-action settings are still
    -- read back by readeck.core.state (for settings files written by 0.0.x),
    -- but they are no longer written: one key per setting.
    function Readeck:collectSettings()
        local tempsettings = {}
        for _, key in ipairs(Defaults.persisted_keys) do
            tempsettings[key] = self[key]
        end
        return tempsettings
    end

    function Readeck:saveSettings()
        self.rd_settings:saveSetting("readeck", self:collectSettings())
        self.rd_settings:flush()
    end

    function Readeck:readSettings()
        local rd_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/readeck.lua")
        rd_settings:readSetting("readeck", {})
        return rd_settings
    end

    function Readeck:saveRDSettings(setting)
        if not self.rd_settings then
            self.rd_settings = self:readSettings()
        end
        self.rd_settings:saveSetting("readeck", setting)
        self.rd_settings:flush()
    end
end

return Settings
