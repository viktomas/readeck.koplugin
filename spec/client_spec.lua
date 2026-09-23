package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- Exercises Readeck:callAPI's 401/403 token-refresh-and-retry path
-- (readeck/net/client.lua). This logic is the riskiest part of the plugin:
-- getting the retry guard wrong turns a server that always answers 401 into
-- an infinite request loop.

local function build_instance(responses, overrides)
    install_koreader_stubs()

    local http_calls = {}
    local encoded_bodies = {}

    package.loaded["socket.http"] = nil
    package.preload["socket.http"] = function()
        return {
            request = function(request)
                table.insert(http_calls, request)
                local resp = table.remove(responses, 1)
                assert(resp, "no scripted HTTP response left for request #" .. #http_calls)
                if resp.body and request.sink then
                    request.sink(resp.body)
                    request.sink(nil)
                end
                -- The fake `socket.skip` used by the test stubs discards the
                -- leading `n` literal (not `n` values), so `http.request`
                -- must return exactly (code, headers, status) here for
                -- `socket.skip(1, http.request(request))` to line up with
                -- production's `code, resp_headers, status = ...`.
                return resp.code, resp.headers or {}, resp.status or tostring(resp.code)
            end,
        }
    end

    package.loaded["json"] = nil
    package.preload["json"] = function()
        return {
            encode = function(body)
                table.insert(encoded_bodies, body)
                return "{}"
            end,
            -- Decode for real: the error-message path depends on the shape of
            -- the body, so a stub that always returns {} would prove nothing.
            decode = require("dkjson").decode,
        }
    end

    local Readeck = dofile("readeck.koplugin/main.lua")
    local instance = setmetatable({
        server_url = "https://readeck.example",
        access_token = "old-token",
        token_expiry = 12345,
        block_timeout = 1,
        total_timeout = 1,
        file_block_timeout = 1,
        file_total_timeout = 1,
        sync_in_progress = false,
        getBearerToken = function()
            error("getBearerToken stub not configured for this test")
        end,
        isOAuthPollingActive = function()
            return false
        end,
        scheduleSyncAfterOAuth = function() end,
    }, { __index = Readeck })

    for key, value in pairs(overrides or {}) do
        instance[key] = value
    end

    return instance, http_calls, encoded_bodies
end

describe("Readeck:getApi", function()
    it("memoises the Api instance across calls", function()
        local instance = build_instance({ { code = 200 } })

        local api_1 = instance:getApi()
        local api_2 = instance:getApi()

        assert.are.equal(api_1, api_2)
    end)

    it("builds a transport that delegates to callAPI", function()
        local instance, http_calls = build_instance({ { code = 200 } })

        local api = instance:getApi()
        api:get_info()

        assert.are.equal(1, #http_calls)
        assert.are.equal("https://readeck.example/api/info", http_calls[1].url)
    end)
end)

describe("Readeck:callAPI 401/403 refresh-and-retry", function()
    it("clears the token, refreshes it, and retries the request exactly once", function()
        local get_bearer_calls = 0
        local access_token_when_refreshing

        local instance = build_instance({
            { code = 401 },
            { code = 200 },
        }, {
            getBearerToken = function(self)
                get_bearer_calls = get_bearer_calls + 1
                access_token_when_refreshing = self.access_token
                self.access_token = "new-token"
                self.token_expiry = 99999
                return true
            end,
        })

        local result, err = instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.is_nil(err)
        assert.is_true(result)
        assert.are.equal(1, get_bearer_calls)
        -- the failing request must be cleared before refreshing, otherwise a
        -- stale token could be reused for the refresh attempt itself.
        assert.are.equal("", access_token_when_refreshing)
    end)

    it("does not recurse forever when the retried request also gets a 401", function()
        local get_bearer_calls = 0

        local instance, http_calls = build_instance({
            { code = 401 },
            { code = 401 },
        }, {
            getBearerToken = function(self)
                get_bearer_calls = get_bearer_calls + 1
                self.access_token = "new-token"
                return true
            end,
        })

        local result, err = instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        -- exactly one retry: the retried request carries retry_auth = true,
        -- which must suppress a second refresh attempt.
        assert.are.equal(2, #http_calls)
        assert.are.equal(1, get_bearer_calls)
        assert.is_nil(result)
        -- A 401 that survives a fresh token is a credentials problem (e.g. a
        -- wrong API token, which "refreshes" to itself), so it must surface as
        -- AUTH_ERROR for the user to see "Authentication failed" - found by
        -- the e2e suite against a real server.
        assert.are.equal("auth_error", err.kind)
        assert.are.equal(401, err.code)
    end)

    it("reports a first-attempt 404 as a plain http_error, not an auth failure", function()
        local instance = build_instance({ { code = 404 } })

        local result, err = instance:callAPI({ method = "GET", path = "/api/bookmarks/x" })

        assert.is_nil(result)
        assert.are.equal("http_error", err.kind)
    end)

    it("retries with the same method and body as the original request", function()
        local instance, http_calls, encoded_bodies = build_instance({
            { code = 401 },
            { code = 200 },
        }, {
            getBearerToken = function(self)
                self.access_token = "new-token"
                return true
            end,
        })

        local body = { title = "hello", tags = { "a", "b" } }
        instance:callAPI({ method = "POST", path = "/api/bookmarks", body = body })

        assert.are.equal(2, #http_calls)
        assert.are.equal("POST", http_calls[1].method)
        assert.are.equal("POST", http_calls[2].method)
        assert.are.equal(2, #encoded_bodies)
        assert.are.equal(body, encoded_bodies[1])
        assert.are.equal(body, encoded_bodies[2])
    end)

    it("returns AUTH_PENDING when the refresh fails but OAuth polling is active", function()
        local instance = build_instance({
            { code = 401 },
        }, {
            getBearerToken = function()
                return false
            end,
            isOAuthPollingActive = function()
                return true
            end,
        })

        local result, err = instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.is_nil(result)
        assert.are.equal("auth_pending", err.kind)
    end)

    it("returns AUTH_ERROR when the refresh fails and OAuth polling is not active", function()
        local instance = build_instance({
            { code = 401 },
        }, {
            getBearerToken = function()
                return false
            end,
            isOAuthPollingActive = function()
                return false
            end,
        })

        local result, err = instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.is_nil(result)
        assert.are.equal("auth_error", err.kind)
    end)

    it("does not attempt a refresh for auth-exempt paths like /api/info", function()
        local get_bearer_calls = 0

        local instance, http_calls = build_instance({
            { code = 401 },
        }, {
            getBearerToken = function()
                get_bearer_calls = get_bearer_calls + 1
                return true
            end,
        })

        local result, err = instance:callAPI({ method = "GET", path = "/api/info" })

        assert.are.equal(1, #http_calls)
        assert.are.equal(0, get_bearer_calls)
        assert.is_nil(result)
        assert.are.equal("http_error", err.kind)
    end)

    it("does not attempt a refresh for OAuth endpoints", function()
        local get_bearer_calls = 0

        local instance, http_calls = build_instance({
            { code = 403 },
        }, {
            getBearerToken = function()
                get_bearer_calls = get_bearer_calls + 1
                return true
            end,
        })

        local result, err = instance:callAPI({ method = "POST", path = "/api/oauth/token" })

        assert.are.equal(1, #http_calls)
        assert.are.equal(0, get_bearer_calls)
        assert.is_nil(result)
        assert.are.equal("http_error", err.kind)
    end)

    it("registers a resync callback with getBearerToken when a sync is in progress", function()
        local received_options
        local resync_calls = 0

        local instance = build_instance({
            { code = 401 },
            { code = 200 },
        }, {
            sync_in_progress = true,
            getBearerToken = function(self, options)
                received_options = options
                self.access_token = "new-token"
                return true
            end,
            scheduleSyncAfterOAuth = function()
                resync_calls = resync_calls + 1
            end,
        })

        instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.is.truthy(received_options)
        assert.is_function(received_options.on_oauth_success)
        received_options.on_oauth_success()
        assert.are.equal(1, resync_calls)
    end)

    it("does not register a resync callback when no sync is in progress", function()
        local received_options

        local instance = build_instance({
            { code = 401 },
            { code = 200 },
        }, {
            sync_in_progress = false,
            getBearerToken = function(self, options)
                received_options = options
                self.access_token = "new-token"
                return true
            end,
        })

        instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.is.truthy(received_options)
        assert.is_nil(received_options.on_oauth_success)
    end)
end)

-- Without these, a rejected highlight is indistinguishable from a network drop:
-- the reason Readeck gives is read for a debug log line and then thrown away.
describe("Readeck:callAPI error messages", function()
    it("carries the message of a 400 rejection into the error table", function()
        local instance = build_instance({
            {
                code = 400,
                status = "400 Bad Request",
                body = '{"status":400,"message":"element \\"section/p[1]\\" not found"}',
            },
        })

        local result, err = instance:callAPI({ method = "POST", path = "/api/bookmarks/x/annotations" })

        assert.is_nil(result)
        assert.are.equal("http_error", err.kind)
        assert.are.equal(400, err.code)
        assert.are.equal('element "section/p[1]" not found', err.message)
    end)

    it("carries field errors of a 422 that has no top-level message", function()
        local instance = build_instance({
            {
                code = 422,
                body = '{"is_valid":false,"fields":{"url":{"value":"","errors":["field is required"]}}}',
            },
        })

        local _, err = instance:callAPI({ method = "POST", path = "/api/bookmarks" })

        assert.are.equal("url: field is required", err.message)
    end)

    it("leaves message nil when the server explains nothing", function()
        local instance = build_instance({ { code = 500, body = "" } })

        local _, err = instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.are.equal("http_error", err.kind)
        assert.is_nil(err.message)
    end)
end)

-- Discovered against a real 0.23.4 server: Readeck content-negotiates its
-- errors, so a GET without an Accept header gets a 5 KB HTML error page and
-- the JSON reason is never available to show the user.
describe("Readeck:callAPI content negotiation", function()
    it("asks for JSON on a plain GET with no request body", function()
        local instance, http_calls = build_instance({ { code = 200, body = "[]" } })

        instance:callAPI({ method = "GET", path = "/api/bookmarks" })

        assert.are.equal("application/json, */*", http_calls[1].headers["Accept"])
    end)

    it("still accepts non-JSON so EPUB downloads keep working", function()
        local instance, http_calls = build_instance({ { code = 200 } })

        instance:callAPI({ method = "GET", path = "/api/bookmarks/x/article.epub", filepath = "/tmp/probe.epub" })

        assert.is.truthy(http_calls[1].headers["Accept"]:find("*/*", 1, true))
        os.remove("/tmp/probe.epub")
    end)

    it("does not override an Accept header a caller set explicitly", function()
        local instance, http_calls = build_instance({ { code = 200, body = "{}" } })

        instance:callAPI({
            method = "GET",
            path = "/api/bookmarks",
            headers = { ["Accept"] = "text/plain", ["Authorization"] = "Bearer x" },
        })

        assert.are.equal("text/plain", http_calls[1].headers["Accept"])
    end)
end)
