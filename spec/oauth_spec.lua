-- luacheck: ignore 122 (this file deliberately stubs os.time to drive the clock)
package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- Exercises Readeck:getBearerToken (readeck/auth/oauth.lua):
--   * the collapsed oauth branch (refreshOAuthToken vs. authorize_with_oauth
--     fallthrough) must keep returning exactly the same booleans as before
--     the dead-branch cleanup.
--   * the token_stored_at clock-anomaly guard: token_expiry is an absolute
--     wall-clock timestamp persisted to disk, but e-readers routinely lose
--     their clock (flat battery). If the stored clock reading is no longer
--     consistent with `now`, the cached token must not be trusted.

local function install_directory_stub()
    package.loaded["libs/libkoreader-lfs"] = nil
    package.preload["libs/libkoreader-lfs"] = function()
        return {
            attributes = function(path, key)
                local attrs
                if path == "/tmp/readeck" or path == "/tmp/readeck/" then
                    attrs = { mode = "directory" }
                end
                if attrs and key then
                    return attrs[key]
                end
                return attrs
            end,
            dir = function()
                return function()
                    return nil
                end
            end,
        }
    end
end

local function build_instance(overrides)
    install_koreader_stubs()
    install_directory_stub()

    local Readeck = dofile("readeck.koplugin/main.lua")
    local instance = setmetatable({
        server_url = "https://readeck.example",
        directory = "/tmp/readeck",
        cached_server_url = "https://readeck.example",
        auth_token = "",
        oauth_refresh_token = "",
        oauth_client_id = "",
        cached_auth_method = "",
        cached_auth_token = "",
        access_token = "",
        token_expiry = 0,
        token_stored_at = 0,
        rd_settings = {
            saveSetting = function() end,
            flush = function() end,
        },
        authenticateWithApiToken = function()
            error("authenticateWithApiToken stub not configured for this test")
        end,
        refreshOAuthToken = function()
            error("refreshOAuthToken stub not configured for this test")
        end,
        authorizeWithOAuthDeviceFlowAsync = function()
            error("authorizeWithOAuthDeviceFlowAsync stub not configured for this test")
        end,
        isOAuthPollingActive = function()
            return false
        end,
    }, { __index = Readeck })

    for key, value in pairs(overrides or {}) do
        instance[key] = value
    end

    return instance
end

local function stub_time(sequence)
    -- sequence can be a single number (constant clock) or a list consumed
    -- in order, repeating the last value once exhausted.
    local values = type(sequence) == "table" and sequence or { sequence }
    local index = 0
    return function()
        index = math.min(index + 1, #values)
        return values[index]
    end
end

describe("Readeck:getBearerToken cached-token reuse", function()
    local real_time = os.time

    after_each(function()
        os.time = real_time
    end)

    it("reuses the cached token while the clock is sane and not near expiry", function()
        os.time = stub_time(2000)
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = 1000,
            token_expiry = 1000 + 3600, -- granted ttl 3600s
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
        })

        local ok = instance:getBearerToken()

        assert.is_true(ok)
    end)

    it("re-authenticates when the token is within 300s of expiry", function()
        os.time = stub_time(4350) -- 250s remaining, sane clock
        local called = false
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = 1000,
            token_expiry = 4600,
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
            authenticateWithApiToken = function()
                called = true
                return true
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(called)
        assert.is_true(ok)
    end)

    it("re-authenticates when the clock has jumped backwards past token_stored_at", function()
        os.time = stub_time(500) -- before token_stored_at: clock went backwards
        local called = false
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = 1000,
            token_expiry = 1000 + 3600,
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
            authenticateWithApiToken = function()
                called = true
                return true
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(called)
        assert.is_true(ok)
    end)

    it("treats a clock exactly at token_stored_at as sane, not as an anomaly", function()
        -- Boundary guarding `now < token_stored_at` against `now <=`: storing a
        -- token and immediately asking for it lands on this case, and it must
        -- reuse the cached token rather than re-authenticate every time.
        local stored_at = 100000
        os.time = stub_time(stored_at)
        local called = false
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = stored_at,
            token_expiry = stored_at + 3600,
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
            authenticateWithApiToken = function()
                called = true
                return true
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(ok)
        assert.is_false(called)
    end)

    it("does not treat a missing token_stored_at (legacy settings) as a clock anomaly", function()
        os.time = stub_time(2000)
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = nil, -- absent, e.g. settings written before this field existed
            token_expiry = 2000 + 3600,
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
            authenticateWithApiToken = function()
                error("should not re-authenticate when clock is consistent with a legacy token")
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(ok)
    end)

    it("does not treat token_stored_at == 0 (default) as a clock anomaly", function()
        os.time = stub_time(2000)
        local instance = build_instance({
            auth_token = "api-token",
            access_token = "cached-access-token",
            token_stored_at = 0,
            token_expiry = 2000 + 3600,
            cached_auth_method = "api_token",
            cached_auth_token = "api-token",
            authenticateWithApiToken = function()
                error("should not re-authenticate when token_stored_at is the unset default")
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(ok)
    end)
end)

describe("Readeck:getBearerToken oauth branch", function()
    local real_time = os.time

    after_each(function()
        os.time = real_time
    end)

    it("returns true when refreshOAuthToken succeeds, without starting device flow", function()
        os.time = stub_time(2000)
        local instance = build_instance({
            oauth_refresh_token = "refresh-token",
            oauth_client_id = "client-id",
            cached_auth_method = "oauth",
            refreshOAuthToken = function()
                return true
            end,
            authorizeWithOAuthDeviceFlowAsync = function()
                error("should not start the device flow when refresh succeeds")
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(ok)
    end)

    it("starts the device flow and returns false when refreshOAuthToken fails", function()
        os.time = stub_time(2000)
        local authorize_called = false
        local instance = build_instance({
            oauth_refresh_token = "refresh-token",
            oauth_client_id = "client-id",
            cached_auth_method = "oauth",
            refreshOAuthToken = function()
                return false
            end,
            authorizeWithOAuthDeviceFlowAsync = function()
                authorize_called = true
            end,
            isOAuthPollingActive = function()
                return true
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(authorize_called)
        assert.is_false(ok)
    end)

    it("starts the device flow and returns false when no oauth context is configured at all", function()
        -- getCurrentAuthMethod only ever returns "api_token" or "oauth"; with
        -- no api token and no refresh context configured, refreshOAuthToken
        -- fails and the fallthrough must still kick off the device flow.
        os.time = stub_time(2000)
        local authorize_called = false
        local instance = build_instance({
            refreshOAuthToken = function()
                return false
            end,
            authorizeWithOAuthDeviceFlowAsync = function()
                authorize_called = true
            end,
            isOAuthPollingActive = function()
                return false
            end,
        })

        local ok = instance:getBearerToken()

        assert.is_true(authorize_called)
        assert.is_false(ok)
    end)
end)

describe("Readeck:storeAccessToken", function()
    local real_time = os.time

    after_each(function()
        os.time = real_time
    end)

    it("records token_stored_at alongside token_expiry", function()
        os.time = stub_time(5000)
        local instance = build_instance({
            saveSettings = function() end,
        })

        instance:storeAccessToken("api_token", "token-value", 3600)

        assert.are.equal(5000, instance.token_stored_at)
        assert.are.equal(5000 + 3600, instance.token_expiry)
    end)
end)
