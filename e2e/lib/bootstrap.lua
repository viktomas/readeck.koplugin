-- Headless KOReader bootstrap for the e2e suite.
--
-- Must be run with the KOReader build (or release tarball) directory as the
-- current working directory, by its own `luajit`. It reproduces what
-- `spec/front/unit/commonrequire.lua` does in KOReader's own test suite, but
-- does not depend on that file: KOReader release tarballs ship no `spec/`.
--
--   * KO_HOME (set by e2e/run.sh) points at a throwaway data dir, so settings,
--     sidecars, history and the plugin's own settings/readeck.lua all live in
--     a per-test temp dir and never touch a real KOReader profile;
--   * a dummy framebuffer (still renders, so Screen:shot works) and dummy
--     input, so no SDL window is ever opened;
--   * only this repo's readeck.koplugin is registered with the PluginLoader,
--     so FileManager/ReaderUI instantiate it exactly like KOReader does.

local Bootstrap = {}

function Bootstrap.init(opts)
    opts = opts or {}
    local plugin_dir = assert(opts.plugin_dir, "plugin_dir is required")

    local ko_home = os.getenv("KO_HOME")
    assert(ko_home and ko_home ~= "", "KO_HOME must point at a throwaway directory")
    assert(ko_home ~= "." and ko_home ~= "/", "refusing to use KO_HOME=" .. ko_home)

    dofile("setupkoenv.lua")

    -- Quiet KOReader's own logging; the plugin logs through its own Log module.
    require("dbg"):turnOff()
    local logger = require("logger")
    logger:setLevel(logger.levels[opts.koreader_log_level or "warn"] or logger.levels.warn)

    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    assert(DataStorage:getDataDir() == ko_home, "DataStorage did not pick up KO_HOME")
    lfs.mkdir(DataStorage:getSettingsDir())
    lfs.mkdir(DataStorage:getHistoryDir())

    -- Global settings, as reader.lua would create them.
    G_defaults = require("luadefaults"):open(ko_home .. "/defaults.e2e.lua") -- luacheck: ignore 111
    G_reader_settings = require("luasettings"):open(ko_home .. "/settings.reader.lua") -- luacheck: ignore 111
    -- Never pop the "quickstart guide" or "what's new" on first launch.
    G_reader_settings:saveSetting("quickstart_shown_version", 999999999)
    G_reader_settings:saveSetting("home_dir", opts.home_dir or ko_home)
    -- Plugins are discovered only from the list we register below.
    G_reader_settings:saveSetting("extra_plugin_paths", {})

    -- Dummy framebuffer: renders into memory, never opens an SDL window.
    einkfb = require("ffi/framebuffer") -- luacheck: ignore 111
    einkfb.dummy = true -- luacheck: ignore 112

    local Device = require("device")
    local Screen = Device.screen
    Screen:init()
    require("document/canvascontext"):init(Device)
    Device.input.dummy = true

    -- Everything the user needs to reach from the UI is online in the
    -- emulator, but the SDL device may report a Wi-Fi toggle; pin it.
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr.isOnline = function()
        return true
    end
    NetworkMgr.isConnected = function()
        return true
    end

    -- Register only readeck.koplugin, via the real loader, so its _meta.lua is
    -- merged and event handlers get sandboxed exactly as on a device.
    local PluginLoader = require("pluginloader")
    PluginLoader.enabled_plugins = {}
    PluginLoader.disabled_plugins = {}
    PluginLoader.loaded_plugins = {}
    PluginLoader:_load({
        {
            main = plugin_dir .. "/main.lua",
            meta = plugin_dir .. "/_meta.lua",
            path = plugin_dir,
            name = "readeck",
            disabled = false,
        },
    })
    assert(#PluginLoader.enabled_plugins == 1, "readeck.koplugin failed to load; see the log above")
    package.path = string.format("%s;%s/?.lua", package.path, plugin_dir)

    return {
        Device = Device,
        Screen = Screen,
        DataStorage = DataStorage,
        PluginLoader = PluginLoader,
    }
end

return Bootstrap
