package.path = "./readeck.koplugin/?.lua;" .. package.path

local Defaults = require("readeck.core.defaults")

describe("readeck.core.defaults", function()
    it("only persists keys that are part of the plugin state", function()
        -- Defaults.values cannot hold a nil default (the key would just be
        -- absent from the table), so those are listed explicitly here.
        local nil_defaults = {
            directory = true,
            server_url = true,
            server_info = true,
        }
        for _, key in ipairs(Defaults.persisted_keys) do
            assert.is_true(
                Defaults.values[key] ~= nil or nil_defaults[key] == true,
                "persisted key is not declared in Defaults: " .. key
            )
        end
    end)

    it("does not persist legacy setting aliases", function()
        local legacy = {
            is_delete_finished = true,
            is_delete_read = true,
            is_archiving_deleted = true,
            is_auto_delete = true,
            is_sync_remote_delete = true,
        }
        for _, key in ipairs(Defaults.persisted_keys) do
            assert.is_nil(legacy[key], "legacy alias should no longer be written: " .. key)
        end
    end)

    it("does not persist runtime-only state", function()
        local runtime = {
            async_http_client = true,
            async_http_client_checked = true,
            dateparser = true,
            download_progress_info = true,
            download_progress_state = true,
            download_scheduler = true,
            oauth_poll_state = true,
            oauth_prompt_dialog = true,
            sync_in_progress = true,
        }
        for _, key in ipairs(Defaults.persisted_keys) do
            assert.is_nil(runtime[key], "runtime state should not be persisted: " .. key)
        end
    end)

    it("keeps the persisted key list free of duplicates", function()
        local seen = {}
        for _, key in ipairs(Defaults.persisted_keys) do
            assert.is_nil(seen[key], "duplicate persisted key: " .. key)
            seen[key] = true
        end
    end)
end)
