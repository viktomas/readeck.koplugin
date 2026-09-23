-- Authentication: API token, bad token, OAuth device-code flow.
local H = ...

H.test("API token: sync downloads the article", function()
    local id = H.seed_page("lighthouse.html")
    H.configure_plugin()
    local fm = H.open_filemanager()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    local article = H.truthy(H.local_article_by_id(id), "article file missing")
    H.eq(H.epub_title(article.path), "The Lighthouse Keeper")
    local settings = H.plugin_settings()
    H.eq(settings.cached_auth_method, "api_token", "auth method persisted")
end)

H.test("API token entered through the settings dialog", function()
    local id = H.seed_page("bread.html")
    H.configure_plugin({ auth_token = "", server_url = H.NULL })
    local fm = H.open_filemanager()

    -- Server URL: Settings > Configure Readeck server > (item) > dialog
    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Configure Readeck server", { "^Server" } })
    local dialog = H.wait_dialog("Readeck settings", { since = mark, kind = "MultiInputDialog" })
    H.fill(dialog, H.env.READECK_URL .. "/")
    H.press("Apply", dialog)

    mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Authentication", "API token" })
    dialog = H.wait_dialog("Authentication settings", { since = mark, kind = "MultiInputDialog" })
    H.fill(dialog, H.env.READECK_TOKEN)
    H.press("Apply", dialog)

    local settings = H.plugin_settings()
    H.eq(settings.server_url, H.env.READECK_URL, "trailing slash stripped from the server URL")
    H.eq(settings.auth_token, H.env.READECK_TOKEN)

    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    H.truthy(H.local_article_by_id(id), "article file missing")
end)

H.test("bad API token: legible error, nothing downloaded", function()
    H.seed_page("clocks.html")
    H.configure_plugin({ auth_token = "definitely-not-a-valid-token" })
    local fm = H.open_filemanager()
    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Synchronize articles with server" })
    H.pump_until(function()
        return not fm.readeck.sync_in_progress
    end, { timeout = 30, message = "sync did not finish" })
    local texts = H.dialog_texts_since(mark)
    H.log("dialogs:", (texts:gsub("\n", " | ")))
    H.match(texts, "Authentication failed", "the user is told that authentication failed")
    H.no_match(texts, "Processing finished", "no success summary after an auth failure")
    H.eq(#H.local_articles(), 0, "nothing downloaded")
end)

-- Reads "Code: XXXX-XXXX" from the prompt the plugin shows, like a user would.
local function user_code_from_prompt(entry)
    local text = H.widget_text(entry.widget)
    return H.truthy(text:match("Code: ([%w%-]+)"), "no user code in the OAuth prompt: " .. text)
end

H.test("OAuth device flow: approve in the browser, then sync", function()
    local id = H.seed_page("mountains.html")
    H.configure_plugin({ auth_token = "" })
    local fm = H.open_filemanager()

    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Authentication", "Authorize with OAuth" })
    local prompt = H.wait_dialog("OAuth login started", { since = mark, kind = "ConfirmBox" })
    H.contains(H.widget_text(prompt.widget), H.env.READECK_URL .. "/device", "prompt shows the verification URL")
    local code = user_code_from_prompt(prompt)

    H.approve_device(code)
    H.wait_dialog("OAuth authorization successful%.", { since = mark, timeout = 30, horizon = 6 })
    H.falsy(prompt.open, "the OAuth prompt closes once authorized")

    local settings = H.plugin_settings()
    H.eq(settings.cached_auth_method, "oauth")
    H.truthy(settings.access_token ~= "" and settings.access_token ~= nil, "OAuth access token persisted")
    H.truthy(settings.oauth_client_id ~= "", "OAuth client id persisted")

    H.dismiss_all()
    local summary = H.sync_via_menu(fm)
    H.match(summary, "Downloaded: 1")
    H.truthy(H.local_article_by_id(id), "article downloaded with the OAuth token")
end)

H.test("OAuth device flow: denied in the browser", function()
    H.configure_plugin({ auth_token = "" })
    local fm = H.open_filemanager()
    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Settings", "Authentication", "Authorize with OAuth" })
    local prompt = H.wait_dialog("OAuth login started", { since = mark, kind = "ConfirmBox" })
    H.approve_device(user_code_from_prompt(prompt), true)
    H.wait_dialog("OAuth authorization was denied%.", { since = mark, timeout = 30, horizon = 6 })
    H.eq(H.plugin_settings().access_token or "", "", "no token stored after a denial")
end)

H.test("OAuth: sync without any credentials starts the device flow", function()
    local id = H.seed_page("lighthouse.html")
    H.configure_plugin({ auth_token = "" })
    local fm = H.open_filemanager()
    local mark = H.mark()
    H.tap_menu(fm, { "Readeck", "Synchronize articles with server" })
    local prompt = H.wait_dialog("OAuth login started", { since = mark, kind = "ConfirmBox" })
    H.approve_device(user_code_from_prompt(prompt))
    -- After authorizing, the plugin resumes the sync on its own.
    H.wait_dialog("Processing finished%.", { since = mark, timeout = 60, horizon = 6 })
    H.truthy(H.local_article_by_id(id), "article downloaded after the OAuth flow")
end)
