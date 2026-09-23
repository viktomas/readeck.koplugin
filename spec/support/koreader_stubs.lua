-- Shared KOReader module stubs for busted specs.
--
-- `install_koreader_stubs()` fills `package.preload` with minimal fake
-- KOReader modules so that `readeck.koplugin/main.lua` (and the individual
-- `readeck.*` submodules it wires together) can be `require`d/`dofile`d
-- outside of a real KOReader runtime.
--
-- Usage:
--   local install_koreader_stubs = require("spec.support.koreader_stubs")
--   install_koreader_stubs()

local function install_koreader_stubs()
    for name in pairs(package.loaded) do
        if name == "readeck" or name:match("^readeck%.") then
            package.loaded[name] = nil
        end
    end

    local function widget()
        return {
            new = function(_, options)
                return options or {}
            end,
        }
    end

    local function template(text, ...)
        local values = { ... }
        return (
            text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end)
        )
    end

    package.preload["ui/bidi"] = function()
        return {
            dirpath = function(path)
                return path
            end,
            url = function(url)
                return url
            end,
        }
    end
    package.preload["datastorage"] = function()
        return {
            getSettingsDir = function()
                return "/tmp"
            end,
        }
    end
    package.preload["device"] = function()
        return {
            canOpenLink = true,
            openLink = function()
                return true
            end,
            screen = {
                getWidth = function()
                    return 600
                end,
                getHeight = function()
                    return 800
                end,
            },
        }
    end
    package.preload["dispatcher"] = function()
        return {
            registerAction = function() end,
        }
    end
    package.preload["docsettings"] = function()
        return {
            hasSidecarFile = function()
                return false
            end,
        }
    end
    package.preload["ui/event"] = function()
        return {
            new = function(_, name, payload)
                return { name = name, payload = payload }
            end,
        }
    end
    package.preload["ffi/util"] = function()
        return {
            template = template,
            joinPath = function(left, right)
                return left .. "/" .. right
            end,
        }
    end
    package.preload["apps/filemanager/filemanager"] = function()
        return {
            showFiles = function() end,
            deleteFile = function() end,
        }
    end
    package.preload["apps/filemanager/filemanagerutil"] = function()
        return {
            abbreviate = function(path)
                return path
            end,
        }
    end
    package.preload["ui/widget/infomessage"] = function()
        return widget()
    end
    package.preload["ui/widget/inputdialog"] = function()
        return widget()
    end
    package.preload["ui/widget/buttondialog"] = function()
        return widget()
    end
    package.preload["ui/widget/confirmbox"] = function()
        return widget()
    end
    package.preload["ui/widget/qrmessage"] = function()
        return widget()
    end
    package.preload["ui/widget/radiobuttonwidget"] = function()
        return widget()
    end
    package.preload["frontend/luasettings"] = function()
        return {
            open = function()
                return {
                    data = { readeck = {} },
                    readSetting = function() end,
                    saveSetting = function() end,
                    flush = function() end,
                }
            end,
        }
    end
    package.preload["optmath"] = function()
        return {
            roundPercent = function(value)
                return value
            end,
            round = function(value)
                return math.floor(value + 0.5)
            end,
        }
    end
    package.preload["ui/widget/multiconfirmbox"] = function()
        return widget()
    end
    package.preload["ui/widget/multiinputdialog"] = function()
        return widget()
    end
    package.preload["ui/network/manager"] = function()
        return {
            isOnline = function()
                return true
            end,
            runWhenOnline = function(callback)
                callback()
            end,
        }
    end
    package.preload["readhistory"] = function()
        return {
            removeItemByPath = function() end,
        }
    end
    package.preload["ui/uimanager"] = function()
        return {
            show = function() end,
            close = function() end,
            forceRePaint = function() end,
            scheduleIn = function(_, delay_or_callback, maybe_callback)
                local callback = maybe_callback or delay_or_callback
                callback()
            end,
            unschedule = function() end,
        }
    end
    package.preload["ui/widget/container/widgetcontainer"] = function()
        return {
            extend = function(_, class)
                return class
            end,
        }
    end
    package.preload["json"] = function()
        return {
            encode = function()
                return "{}"
            end,
            decode = function()
                return {}
            end,
        }
    end
    package.preload["libs/libkoreader-lfs"] = function()
        return {
            attributes = function()
                return nil
            end,
            dir = function()
                return function()
                    return nil
                end
            end,
            touch = function()
                return true
            end,
        }
    end
    package.preload["logger"] = function()
        return {
            info = function() end,
            warn = function() end,
            err = function() end,
        }
    end
    package.preload["ltn12"] = function()
        return {
            sink = {
                file = function()
                    return function() end
                end,
                table = function()
                    return function() end
                end,
            },
            source = {
                string = function()
                    return function() end
                end,
            },
        }
    end
    package.preload["socket"] = function()
        return {
            skip = function(_, ...)
                return ...
            end,
            gettime = function()
                return 0
            end,
        }
    end
    package.preload["socket.http"] = function()
        return {
            request = function()
                return nil
            end,
        }
    end
    package.preload["socketutil"] = function()
        return {
            set_timeout = function() end,
            reset_timeout = function() end,
            file_sink = function(handle)
                -- Like ltn12.sink.file: closes the file at the end of the body.
                return function(chunk)
                    if chunk and handle then
                        handle:write(chunk)
                    elseif handle then
                        handle:close()
                        handle = nil
                    end
                    return 1
                end
            end,
            table_sink = function(target)
                return function(chunk)
                    if chunk then
                        table.insert(target, chunk)
                    end
                    return 1
                end
            end,
        }
    end
    package.preload["util"] = function()
        return {
            getSafeFilename = function(title)
                return title or "article"
            end,
            gsplit = function()
                return function()
                    return nil
                end
            end,
        }
    end
    package.preload["gettext"] = function()
        return setmetatable({ current_lang = "en" }, {
            __call = function(_, text)
                return text
            end,
        })
    end
end

return install_koreader_stubs
