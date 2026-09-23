local DocSettings = require("docsettings")
local Errors = require("readeck.net.errors")
local FFIUtil = require("ffi/util")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local Progress = require("readeck.sync.progress")
local RemotePresence = require("readeck.sync.remote_presence")
local Tags = require("readeck.core.tags")
local Status = require("readeck.sync.status")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local LocalActions = {}

function LocalActions.install(Readeck, deps)
    local L = deps.L
    local T = deps.T
    local Log = deps.Log

    function Readeck:processRemoteDeletes(remote_article_ids)
        local counts = Status.new_counts()
        if not self.remove_local_missing_remote then
            Log:debug("Processing of remote file removals disabled.")
            return counts
        end
        Log:debug("Articles IDs from server:", remote_article_ids)

        local candidates = self:confirmRemoteDeleteCandidates(self:collectRemoteDeleteCandidates(remote_article_ids))
        if #candidates == 0 then
            return counts
        end

        local info = InfoMessage:new({
            text = table.concat({
                L("Removing local files missing from Readeck…"),
                T(L("Will remove from KOReader: %1"), #candidates),
            }, "\n"),
        })
        UIManager:show(info)
        UIManager:forceRePaint()
        UIManager:close(info)
        for _, entry_path in ipairs(candidates) do
            Log:debug("Deleting local file (deleted on server):", entry_path)
            counts.local_removed = counts.local_removed + self:deleteLocalArticle(entry_path)
        end
        return counts
    end

    -- Absent from the fetched list is not the same as gone from Readeck (see
    -- readeck.sync.remote_presence): ask the server about each candidate and
    -- keep only the ones it confirms are gone.
    function Readeck:confirmRemoteDeleteCandidates(candidates)
        local confirmed = {}
        for _, entry_path in ipairs(candidates) do
            local id = self:getArticleID(entry_path)
            local bookmark, err = self:getApi():get_bookmark(id)
            if RemotePresence.should_remove_local(bookmark, err) then
                table.insert(confirmed, entry_path)
            else
                Log:info(
                    "Keeping local file, bookmark not confirmed gone from Readeck:",
                    id,
                    err and err.kind or "exists",
                    err and err.code or ""
                )
            end
        end
        return confirmed
    end

    function Readeck:collectRemoteDeleteCandidates(remote_article_ids)
        local candidates = {}
        for entry in lfs.dir(self.directory) do
            if entry ~= "." and entry ~= ".." then
                local entry_path = FFIUtil.joinPath(self.directory, entry)
                local id = self:getArticleID(entry_path)
                if id and not remote_article_ids[id] and lfs.attributes(entry_path, "mode") == "file" then
                    table.insert(candidates, entry_path)
                end
            end
        end
        return candidates
    end

    function Readeck:isCompletionProcessingEnabledForMode(mode)
        return not mode or mode == "manual" or self.process_completion_on_sync ~= false
    end

    function Readeck:getLocalCompletionAction(path, doc_settings)
        doc_settings = doc_settings or DocSettings:open(path)
        local summary = doc_settings:readSetting("summary")
        local status = summary and summary.status
        local percent_finished = doc_settings:readSetting("percent_finished")
        if status == "complete" or status == "abandoned" then
            if self.completion_action_finished_enabled then
                return {
                    mark_read_complete = (status == "complete") or (percent_finished == 1),
                }
            end
        elseif percent_finished == 1 then
            if self.completion_action_read_enabled then
                return {
                    mark_read_complete = true,
                }
            end
        end
    end

    function Readeck:getLocalReadingProgressAction(doc_settings, remote_article)
        local percent_finished = doc_settings:readSetting("percent_finished")
        if
            not Progress.should_update_remote_percent(
                percent_finished,
                remote_article and remote_article.read_progress or nil
            )
        then
            return nil
        end
        return {
            progress = Progress.percent_finished_to_readeck_progress(percent_finished),
        }
    end

    function Readeck:collectLocalFileActions(options)
        options = options or {}
        local completion_enabled = options.completion_enabled ~= false
        local completion_actions_enabled = completion_enabled
            and (self.completion_action_finished_enabled or self.completion_action_read_enabled)
        local should_scan = completion_actions_enabled or self.sync_reading_progress or self.send_review_as_tags
        local remote_articles_by_id = options.remote_articles_by_id or {}
        local files = {}
        local plan = {
            remote_archive_candidates = 0,
            remote_delete_candidates = 0,
            remote_progress_candidates = 0,
            local_remove_candidates = 0,
        }
        if not should_scan then
            return files, plan
        end

        for entry in lfs.dir(self.directory) do
            if entry ~= "." and entry ~= ".." then
                local entry_path = FFIUtil.joinPath(self.directory, entry)
                if lfs.attributes(entry_path, "mode") == "file" and DocSettings:hasSidecarFile(entry_path) then
                    local file_action = {
                        path = entry_path,
                    }
                    local article_id = self:getArticleID(entry_path)
                    local doc_settings = DocSettings:open(entry_path)
                    if completion_actions_enabled then
                        local completion_action = self:getLocalCompletionAction(entry_path, doc_settings)
                        if completion_action and article_id then
                            file_action.completion_action = completion_action
                            if self.archive_instead_of_delete then
                                plan.remote_archive_candidates = plan.remote_archive_candidates + 1
                            else
                                plan.remote_delete_candidates = plan.remote_delete_candidates + 1
                            end
                            plan.local_remove_candidates = plan.local_remove_candidates + 1
                        end
                    end
                    if self.sync_reading_progress and not file_action.completion_action and article_id then
                        local progress_action = self:getLocalReadingProgressAction(
                            doc_settings,
                            remote_articles_by_id[tostring(article_id)]
                        )
                        if progress_action then
                            file_action.progress_action = progress_action
                            plan.remote_progress_candidates = plan.remote_progress_candidates + 1
                        end
                    end
                    table.insert(files, file_action)
                end
            end
        end
        return files, plan
    end

    function Readeck:processLocalFiles(mode, options)
        options = options or {}
        local counts = Status.new_counts()
        local completion_enabled = self:isCompletionProcessingEnabledForMode(mode)
        if not completion_enabled then
            counts.completion_actions_disabled = 1
            if not self.send_review_as_tags and not self.sync_reading_progress then
                Log:debug("Automatic processing of local completion actions disabled.")
                return counts
            end
        end

        if
            self:getBearerToken({
                on_oauth_success = function()
                    NetworkMgr:runWhenOnline(function()
                        self:processLocalFiles(mode)
                        self:refreshCurrentDirIfNeeded()
                    end)
                end,
            }) == false
        then
            return counts
        end

        local local_files, plan = self:collectLocalFileActions({
            completion_enabled = completion_enabled,
            remote_articles_by_id = options.remote_articles_by_id,
        })
        if #local_files > 0 then
            local message = L("Processing local files…")
            if
                completion_enabled and (self.completion_action_finished_enabled or self.completion_action_read_enabled)
            then
                message = self:formatCompletionPlanMessage(plan)
            end
            local info = InfoMessage:new({ text = message })
            UIManager:show(info)
            UIManager:forceRePaint()
            UIManager:close(info)
        end
        for _, local_file in ipairs(local_files) do
            if self.send_review_as_tags then
                self:addTags(local_file.path)
            end
            if local_file.completion_action then
                Status.add(counts, self:removeArticle(local_file.path, local_file.completion_action.mark_read_complete))
            elseif local_file.progress_action then
                Status.add(counts, self:syncReadingProgress(local_file.path, local_file.progress_action.progress))
            end
        end
        return counts
    end

    function Readeck:syncReadingProgress(path, progress)
        local counts = Status.new_counts()
        local id = self:getArticleID(path)
        progress = tonumber(progress)
        if not id or not progress then
            return counts
        end

        local body = {
            read_progress = math.max(0, math.min(100, Math.round(progress))),
        }
        local remote_ok, err = self:getApi():update_bookmark(id, body)
        if remote_ok then
            counts.remote_progress_updated = counts.remote_progress_updated + 1
        else
            self:showAPIError(err)
            counts.failed = counts.failed + 1
        end
        return counts
    end

    function Readeck:addArticle(article_url)
        Log:debug("Adding article", article_url)

        if not article_url then
            return false
        end
        if
            self:getBearerToken({
                on_oauth_success = function()
                    NetworkMgr:runWhenOnline(function()
                        self:addArticle(article_url)
                        self:refreshCurrentDirIfNeeded()
                    end)
                end,
            }) == false
        then
            if self:isOAuthPollingActive() then
                return nil, Errors.new(Errors.KIND.AUTH_PENDING)
            end
            return false
        end

        local body = {
            url = article_url,
        }

        local auto_tags = Tags.split(self.auto_tags)
        if #auto_tags > 0 then
            body.labels = auto_tags
        end

        local result, err = self:getApi():create_bookmark(body)
        if not result then
            self:showAPIError(err)
        end
        return result, err
    end

    function Readeck:addTags(path)
        Log:debug("Managing tags for article", path)
        local id = self:getArticleID(path)
        if id then
            local doc_settings = DocSettings:open(path)
            local summary = doc_settings:readSetting("summary")
            local tags_text = summary and summary.note
            if tags_text and tags_text ~= "" then
                Log:debug("Sending tags", tags_text, "for", path)

                local body = {
                    add_labels = Tags.split(tags_text),
                }

                local _, err = self:getApi():update_bookmark(id, body)
                if err then
                    self:showAPIError(err)
                end
            else
                Log:debug("No tags to send for", path)
            end
        end
    end

    function Readeck:removeArticle(path, mark_read_complete)
        Log:debug("Removing article", path)
        local counts = Status.new_counts()
        local id = self:getArticleID(path)
        if id then
            local highlights_ok, highlight_counts = self:syncHighlightsForPath(path, { quiet = true })
            if highlight_counts and (highlight_counts.bookmark_missing or 0) > 0 then
                -- The bookmark is already gone from Readeck (404 while fetching
                -- its highlights): the completion action's goal - "this
                -- bookmark is archived/deleted" - is already met, there are no
                -- highlights left to protect, and retrying every sync would
                -- only fail the same way forever. Finish locally and move on.
                Log:info("Bookmark already gone from server, finishing completion action locally:", path)
                counts.remote_deleted = counts.remote_deleted + 1
                counts.processed_article_ids = {
                    [tostring(id)] = true,
                }
                counts.local_removed = counts.local_removed + self:deleteLocalArticle(path)
                return counts
            end
            if highlights_ok == false then
                Log:warn("Skipping completion action because highlight sync failed:", path)
                counts.failed = counts.failed + 1
                return counts
            end

            local remote_ok
            local bookmark_gone = false
            if self.archive_instead_of_delete then
                local body = {
                    is_archived = true,
                }
                if mark_read_complete then
                    body.read_progress = 100
                end
                if self.sync_star_status then
                    local doc_settings = DocSettings:open(path)
                    local summary = doc_settings:readSetting("summary")
                    if summary and summary.rating then
                        if summary.rating > 0 and self.sync_star_rating_as_label == true then
                            local label = { summary.rating .. "-star" }
                            body.add_labels = label
                        end
                        if summary.rating >= self.remote_star_threshold then
                            body.is_marked = true
                        end
                    end
                end
                local err
                remote_ok, err = self:getApi():update_bookmark(id, body)
                if remote_ok then
                    counts.remote_archived = counts.remote_archived + 1
                elseif Errors.is_not_found(err) then
                    bookmark_gone = true
                else
                    self:showAPIError(err)
                end
            else
                local err
                remote_ok, err = self:getApi():delete_bookmark(id)
                if remote_ok then
                    counts.remote_deleted = counts.remote_deleted + 1
                elseif Errors.is_not_found(err) then
                    bookmark_gone = true
                else
                    self:showAPIError(err)
                end
            end
            if bookmark_gone then
                -- The bookmark was deleted on the server between the highlight
                -- guard above and this request (a race, not a failure): same
                -- goal-already-met outcome as the bookmark_missing case.
                Log:info("Bookmark gone from server while completing action, finishing locally:", path)
                counts.remote_deleted = counts.remote_deleted + 1
                remote_ok = true
            end
            if remote_ok then
                counts.processed_article_ids = {
                    [tostring(id)] = true,
                }
                counts.local_removed = counts.local_removed + self:deleteLocalArticle(path)
            else
                counts.failed = counts.failed + 1
            end
        end
        return counts
    end

    function Readeck:deleteLocalArticle(path)
        if lfs.attributes(path, "mode") == "file" then
            FileManager:deleteFile(path, true)
            return 1
        end
        return 0
    end
end

return LocalActions
