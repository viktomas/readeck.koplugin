local Api = require("readeck.net.api")
local Errors = require("readeck.net.errors")
local JSON = require("json")
local PartialFile = require("readeck.storage.partial_file")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Client = {}

function Client.install(Readeck, deps)
    local Log = deps.Log

    function Readeck:wrapSinkWithUIRefresh(sink)
        local last_refresh = socket.gettime()
        return function(chunk, err)
            local ok, sink_err = sink(chunk, err)
            if chunk then
                local now = socket.gettime()
                if now - last_refresh >= 1 then
                    last_refresh = now
                    UIManager:forceRePaint()
                end
            end
            return ok, sink_err
        end
    end

    function Readeck:getApi()
        if not self._api then
            self._api = Api.new(function(request)
                return self:callAPI(request)
            end)
        end
        return self._api
    end

    function Readeck:callAPI(opts)
        local method = opts.method
        local apiurl = opts.path
        local body = opts.body

        -- Copy so that request-specific defaults never leak back into a caller's table.
        local headers = nil
        if opts.headers ~= nil then
            headers = {}
            for key, value in pairs(opts.headers) do
                headers[key] = value
            end
        end
        local filepath = opts.filepath
        local retry_auth = opts.retry_auth

        local sink = {}
        local request = {}

        if apiurl:sub(1, 1) == "/" then
            request.url = self.server_url .. apiurl
            if headers == nil then
                headers = {
                    ["Authorization"] = "Bearer " .. self.access_token,
                    -- Readeck content-negotiates its errors. Without an Accept
                    -- header it answers a failed GET with a 5 KB HTML error page
                    -- instead of {"status":404,"message":"Not Found"}, so the
                    -- reason never reaches the user. */* keeps EPUB downloads working.
                    ["Accept"] = "application/json, */*",
                }
            end
        else
            request.url = apiurl
            if headers == nil then
                headers = {}
            end
        end

        request.method = method

        local body_source = nil
        if type(body) == "table" then
            local body_json = JSON.encode(body)
            headers["Content-type"] = headers["Content-type"] or "application/json"
            headers["Accept"] = headers["Accept"] or "application/json, */*"
            headers["Content-Length"] = headers["Content-Length"] or tostring(#body_json)
            body_source = body_json
        elseif type(body) == "string" then
            body_source = body
        end

        local part_path = filepath ~= nil and PartialFile.path_for(filepath) or nil
        if filepath ~= nil then
            local file, open_err = io.open(part_path, "wb")
            if not file then
                Log:error("Could not open response file:", part_path, open_err or "")
                return nil, Errors.new(Errors.KIND.FILE_ERROR)
            end
            socketutil:set_timeout(self.file_block_timeout, self.file_total_timeout)
            request.sink = self:wrapSinkWithUIRefresh(socketutil.file_sink(file))
        else
            socketutil:set_timeout(self.block_timeout, self.total_timeout)
            request.sink = socketutil.table_sink(sink)
        end
        request.headers = headers
        if body_source ~= nil then
            request.source = ltn12.source.string(body_source)
        end
        Log:debug("API request - URL:", request.url, "Method:", method)

        for k, v in pairs(headers or {}) do
            if k == "Authorization" then
                Log:debug("Header:", k, "= Bearer ***")
            else
                Log:debug("Header:", k, "=", v)
            end
        end

        local ok_request, code, resp_headers, status = http.request(request)
        socketutil:reset_timeout()
        if not ok_request then
            -- The connection failed or dropped mid-body; `code` is the reason.
            Log:error("Request failed:", code or "unknown error", "URL:", request.url)
            if part_path then
                PartialFile.discard(part_path)
            end
            return nil, Errors.new(Errors.KIND.NETWORK_ERROR)
        end

        if resp_headers then
            Log:debug("Response code:", code, "Status:", status or "nil")
            for k, v in pairs(resp_headers) do
                Log:debug("Response header:", k, "=", v)
            end
        else
            Log:error("No response headers received")
            return nil, Errors.new(Errors.KIND.NETWORK_ERROR)
        end

        local is_auth_endpoint = Api.is_auth_exempt_path(apiurl)
        if (code == 401 or code == 403) and not retry_auth and apiurl:sub(1, 1) == "/" and not is_auth_endpoint then
            Log:info("Authentication failed (", code, "), attempting to refresh token")

            self.access_token = ""
            self.token_expiry = 0

            local oauth_success_callback = nil
            if self.sync_in_progress then
                oauth_success_callback = function()
                    self:scheduleSyncAfterOAuth()
                end
            end

            if self:getBearerToken({
                on_oauth_success = oauth_success_callback,
            }) then
                Log:info("Token refreshed, retrying API call")
                return self:callAPI({
                    method = method,
                    path = apiurl,
                    headers = nil,
                    body = body,
                    filepath = filepath,
                    retry_auth = true,
                })
            elseif self:isOAuthPollingActive() then
                Log:info("OAuth authorization flow started after auth failure")
                return nil, Errors.new(Errors.KIND.AUTH_PENDING, code, status)
            else
                Log:error("Failed to refresh token")
                return nil, Errors.new(Errors.KIND.AUTH_ERROR, code, status)
            end
        end

        if code == 200 or code == 201 or code == 202 or code == 204 then
            if filepath ~= nil then
                local committed, commit_err = PartialFile.commit(part_path, filepath)
                if not committed then
                    Log:error("Could not move the download into place:", filepath, commit_err or "")
                    return nil, Errors.new(Errors.KIND.FILE_ERROR)
                end
                Log:info("File downloaded successfully to", filepath)
                return true, nil, resp_headers
            else
                local content = table.concat(sink)
                Log:debug("Response content length:", #content, "bytes")

                if #content > 0 and #content < 500 then
                    Log:debug("Response content:", content)
                end

                if code == 204 then
                    Log:debug("Successfully received 204 No Content response")
                    return true, nil, resp_headers
                elseif content ~= "" and (string.sub(content, 1, 1) == "{" or string.sub(content, 1, 1) == "[") then
                    local ok, result = pcall(JSON.decode, content)
                    if ok and result then
                        Log:debug("Successfully parsed JSON response")
                        return result, nil, resp_headers
                    else
                        Log:error("Failed to parse JSON:", result or "unknown error")
                    end
                elseif content == "" then
                    Log:debug("Empty response with successful status code")
                    return true, nil, resp_headers
                else
                    Log:error("Response is not valid JSON")
                end
                return nil, Errors.new(Errors.KIND.JSON_ERROR, code, status)
            end
        else
            local error_content = filepath == nil and table.concat(sink) or ""
            if error_content ~= "" and #error_content < 1000 then
                Log:debug("Error response content:", error_content)
            end
            local error_message = Errors.message_from_body(error_content, JSON.decode)
            if error_message then
                Log:error("Server rejected the request:", error_message)
            end
            if filepath ~= nil then
                PartialFile.discard(part_path)
                Log:warn("Discarded failed download:", filepath)
            else
                Log:error("Communication with server failed:", code)
            end
            Log:error("Request failed:", status or code, "URL:", request.url)
            -- A 401/403 that survived a fresh token (e.g. a wrong API token,
            -- which "refreshes" to itself) is an authentication failure, not a
            -- generic communication error: the user has to fix credentials.
            if (code == 401 or code == 403) and retry_auth then
                return nil, Errors.new(Errors.KIND.AUTH_ERROR, code, status, error_message)
            end
            return nil, Errors.new(Errors.KIND.HTTP_ERROR, code, status, error_message)
        end
    end
end

return Client
