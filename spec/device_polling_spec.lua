package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- Exercises Readeck:evaluateOAuthDeviceTokenPoll (readeck/auth/device_polling.lua),
-- the pure decision logic behind OAuth device-flow polling. The refactor
-- changed its signature from
-- (ctx, token_result, poll_err, poll_code, wait_interval) to
-- (ctx, token_result, poll_err, wait_interval) with no test guarding it.

local function build_instance(overrides)
    install_koreader_stubs()
    local Readeck = dofile("readeck.koplugin/main.lua")

    local stored_tokens = {}
    local instance = setmetatable({
        storeAccessToken = function(_, method, token, expires_in, auth_meta)
            table.insert(stored_tokens, {
                method = method,
                token = token,
                expires_in = expires_in,
                auth_meta = auth_meta,
            })
        end,
    }, { __index = Readeck })

    for key, value in pairs(overrides or {}) do
        instance[key] = value
    end

    return instance, stored_tokens
end

describe("Readeck:evaluateOAuthDeviceTokenPoll", function()
    local ctx = { client_id = "client-123" }

    it("stores the token and reports success when the body has an access_token", function()
        local instance, stored_tokens = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            access_token = "abc-token",
            refresh_token = "refresh-xyz",
            expires_in = 3600,
        }, nil, 5)

        assert.are.equal("success", outcome)
        assert.is_nil(value)
        assert.are.equal(1, #stored_tokens)
        assert.are.equal("oauth", stored_tokens[1].method)
        assert.are.equal("abc-token", stored_tokens[1].token)
        assert.are.equal(3600, stored_tokens[1].expires_in)
        assert.are.equal("refresh-xyz", stored_tokens[1].auth_meta.oauth_refresh_token)
        assert.are.equal("client-123", stored_tokens[1].auth_meta.oauth_client_id)
    end)

    it("retries with the same interval on authorization_pending", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            error = "authorization_pending",
        }, nil, 5)

        assert.are.equal("retry", outcome)
        assert.are.equal(5, value)
    end)

    it("retries with interval + 5 on slow_down", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            error = "slow_down",
        }, nil, 5)

        assert.are.equal("retry", outcome)
        assert.are.equal(10, value)
    end)

    it("fails on access_denied", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            error = "access_denied",
        }, nil, 5)

        assert.are.equal("fail", outcome)
        assert.is_string(value)
    end)

    it("fails on expired_token", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            error = "expired_token",
        }, nil, 5)

        assert.are.equal("fail", outcome)
        assert.is_string(value)
    end)

    it("retries with interval + 5 on a 5xx transport error", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, nil, { code = 503 }, 5)

        assert.are.equal("retry", outcome)
        assert.are.equal(10, value)
    end)

    it("fails when there is no token, no OAuth error, and no poll_err", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, nil, nil, 5)

        assert.are.equal("fail", outcome)
        assert.is_string(value)
    end)

    it("fails on any other transport error code that isn't a 5xx", function()
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, nil, { code = 404 }, 5)

        assert.are.equal("fail", outcome)
        assert.is_string(value)
    end)

    it("lets the parsed body's OAuth error win over an accompanying HTTP status code", function()
        -- callOAuthFormAPI returns the parsed body even on failure specifically so
        -- that this can happen: a 5xx response whose JSON body actually carries a
        -- definitive OAuth error (e.g. access_denied) must not be treated as a
        -- transient server error to retry.
        local instance = build_instance()

        local outcome, value = instance:evaluateOAuthDeviceTokenPoll(ctx, {
            error = "access_denied",
        }, { code = 502 }, 5)

        assert.are.equal("fail", outcome)
        assert.is_string(value)
    end)
end)
