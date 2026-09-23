local DocSettings = require("docsettings")
local EpubSource = require("readeck.annotations.epub_source")
local Errors = require("readeck.net.errors")
local Event = require("ui/event")
local FFIUtil = require("ffi/util")
local Features = require("readeck.core.features")
local Highlights = require("readeck.annotations.highlights")
local InfoMessage = require("ui/widget/infomessage")
local LinkedSync = require("readeck.annotations.linked_sync")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Export = {}

local function new_highlight_counts()
    return {
        success = 0,
        error = 0,
        skipped = 0,
        invalid = 0,
        imported = 0,
        import_skipped = 0,
        import_failed = 0,
        remote_deleted = 0,
        updated_local = 0,
        updated_remote = 0,
        conflicts = 0,
    }
end

local function add_highlight_counts(target, source)
    target = target or new_highlight_counts()
    for key, value in pairs(source or {}) do
        if type(value) == "string" then
            -- Reasons (error_message) are text, not tallies: keep the first one
            -- instead of coercing it to 0 the way a count would be.
            if target[key] == nil then
                target[key] = value
            end
        else
            target[key] = (target[key] or 0) + (tonumber(value) or 0)
        end
    end
    return target
end

-- Exposed for tests: the merge rule for text reasons is easy to break silently.
Export.add_highlight_counts = add_highlight_counts

-- The full-sync summary used to fold every highlight-sync outcome into a bare
-- `highlights_failed` count; this is the one reason worth keeping (export
-- rejection beats import failure only because there is one slot to fill).
local function highlight_failure_message(counts)
    if type(counts) ~= "table" then
        return nil
    end
    return counts.error_message or counts.import_error_message
end

Export.highlight_failure_message = highlight_failure_message

function Export.install(Readeck, deps)
    local L = deps.L
    local T = deps.T
    local Log = deps.Log

    function Readeck:getCurrentAnnotations()
        if self.ui and self.ui.annotation and self.ui.annotation.annotations then
            return self.ui.annotation.annotations
        end
        if self.ui and self.ui.view and self.ui.view.ui and self.ui.view.ui.annotation then
            return self.ui.view.ui.annotation.annotations
        end
    end

    function Readeck:getAnnotationsForPath(path, options)
        options = options or {}
        if options.annotations then
            return options.annotations
        end
        if self.ui and self.ui.document and self.ui.document.file == path then
            return self:getCurrentAnnotations()
        end
        if DocSettings:hasSidecarFile(path) then
            return DocSettings:open(path):readSetting("annotations")
        end
    end

    function Readeck:saveAnnotationsForPath(path, annotations)
        if not path or not annotations then
            return true
        end

        local settings
        local is_current_document = self.ui and self.ui.document and self.ui.document.file == path
        if is_current_document and self.ui.doc_settings then
            settings = self.ui.doc_settings
        else
            settings = DocSettings:open(path)
        end
        if not settings or type(settings.saveSetting) ~= "function" then
            return false
        end

        settings:saveSetting("annotations", annotations)
        if not is_current_document then
            settings:saveSetting("annotations_externally_modified", true)
        end
        if type(settings.flush) == "function" then
            settings:flush()
        end
        return true
    end

    -- The translation between KOReader xpointers and Readeck selectors for the
    -- downloaded EPUB at `path` (readeck/annotations/position_map.lua), or nil.
    function Readeck:getPositionMap(path)
        if not path then
            return nil, "no_path"
        end
        local document = self.ui and self.ui.document
        if not (document and document.file == path) then
            document = nil
        end
        local map, reason = EpubSource.position_map(path, document)
        if not map then
            Log:info("No highlight position map for", path, reason)
        end
        return map, reason
    end

    function Readeck:localHighlightOverlapsRemote(local_highlight, remote_highlight, profile, position_map)
        if Highlights.local_matches_remote_id(local_highlight, remote_highlight) then
            return true
        end
        local local_payload = Highlights.build_payload(local_highlight, profile, position_map)
        return local_payload and Highlights.overlap(local_payload, remote_highlight, position_map) or false
    end

    function Readeck:remoteHighlightExistsLocally(annotations, remote_highlight, profile, position_map)
        for _, local_highlight in pairs(annotations or {}) do
            if self:localHighlightOverlapsRemote(local_highlight, remote_highlight, profile, position_map) then
                return true
            end
        end
        return false
    end

    function Readeck:indexRemoteHighlightsByID(remote_highlights)
        local ids = {}
        for _, remote_highlight in ipairs(remote_highlights or {}) do
            if remote_highlight.id then
                ids[tostring(remote_highlight.id)] = remote_highlight
            end
        end
        return ids
    end

    function Readeck:shouldKeepRemoteDeletedHighlightLocal(local_highlight, remote_highlight_ids)
        if self.highlight_sync_policy ~= "respect_remote_deletions" then
            return false
        end
        local remote_id = local_highlight and local_highlight.readeck_annotation_id
        return remote_id ~= nil and tostring(remote_id) ~= "" and not remote_highlight_ids[tostring(remote_id)]
    end

    function Readeck:getHighlightPayloadProfile()
        local policy = self.highlight_feature_policy or "auto"
        if policy == "modern" then
            return { notes = true, none_color = true }
        end
        if policy == "legacy" then
            return { notes = false, none_color = false }
        end
        return Features.highlight_payload_profile(self.server_info or self:refreshServerInfo(true))
    end

    -- With the book open, crengine has the last word: the positions must
    -- resolve to text, and the highlight gets crengine's own rendering of it.
    function Readeck:checkPositionsInDocument(local_annotation)
        local document = self.ui.document
        if type(document.getTextFromXPointers) ~= "function" then
            return true
        end
        local ok, text = pcall(document.getTextFromXPointers, document, local_annotation.pos0, local_annotation.pos1)
        if not ok or type(text) ~= "string" or text:match("^%s*$") then
            return false
        end
        local_annotation.text = text
        return true
    end

    function Readeck:addRemoteHighlightToAnnotations(
        path,
        annotations,
        remote_highlight,
        profile,
        options,
        position_map
    )
        local local_annotation, reason = Highlights.remote_to_local_annotation(remote_highlight, profile, position_map)
        if not local_annotation then
            return false, reason
        end

        local is_current_document = self.ui and self.ui.document and self.ui.document.file == path
        if is_current_document and self.ui.annotation and type(self.ui.annotation.addItem) == "function" then
            if not self:checkPositionsInDocument(local_annotation) then
                return false, "unresolved_position"
            end
            if self.ui.toc and type(self.ui.toc.getTocTitleByPage) == "function" then
                local_annotation.chapter = self.ui.toc:getTocTitleByPage(local_annotation.page)
                    or local_annotation.chapter
            end
            local index = self.ui.annotation:addItem(local_annotation)
            annotations = self.ui.annotation.annotations or annotations
            if self.ui.handleEvent then
                self.ui:handleEvent(Event:new("AnnotationsModified", {
                    local_annotation,
                    nb_highlights_added = 1,
                    index_modified = index,
                }))
            end
        else
            table.insert(annotations, local_annotation)
        end

        if not self:saveAnnotationsForPath(path, annotations, options) then
            return false, "save_failed"
        end
        return true
    end

    -- Earlier versions imported Readeck annotations with the Readeck selector
    -- as the KOReader position ("section[1]/article[1]/p[4].4"), which
    -- crengine cannot resolve, so they were never drawn. Re-derive the
    -- positions of such linked highlights from the server's annotation.
    function Readeck:repairImportedPositions(path, annotations, remote_highlights_by_id, position_map, counts)
        if not position_map then
            return false
        end
        local changed = false
        local is_current_document = self.ui and self.ui.document and self.ui.document.file == path
        for _, h in pairs(annotations or {}) do
            local remote = h.readeck_annotation_id and remote_highlights_by_id[tostring(h.readeck_annotation_id)]
            if remote and type(h.pos0) == "string" and h.pos0:sub(1, 1) ~= "/" then
                local pos0, pos1, text = Highlights.remote_positions(remote, position_map)
                if pos0 then
                    local old0, old1, old_text = h.pos0, h.pos1, h.text
                    h.pos0, h.pos1, h.page = pos0, pos1, pos0
                    h.text = text ~= "" and text or h.text
                    if is_current_document and not self:checkPositionsInDocument(h) then
                        h.pos0, h.pos1, h.page, h.text = old0, old1, old0, old_text
                    else
                        changed = true
                        counts.updated_local = counts.updated_local + 1
                        Log:info("Repaired position of imported highlight", h.readeck_annotation_id)
                    end
                end
            end
        end
        if changed and is_current_document and self.ui.annotation then
            if type(self.ui.annotation.updateAnnotations) == "function" then
                pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
            end
        end
        return changed
    end

    function Readeck:describeImportFailure(reason)
        if reason == "no_position_map" then
            return L("the downloaded article could not be read")
        end
        if reason == "unresolved_position" or reason == "invalid_position" then
            return L("its text is not in the downloaded article")
        end
        return nil
    end

    function Readeck:importRemoteHighlightsForPath(
        path,
        annotations,
        remote_highlights,
        profile,
        counts,
        options,
        position_map
    )
        if not path then
            return counts
        end
        annotations = annotations or {}
        counts = counts or new_highlight_counts()
        if position_map == nil then
            position_map = self:getPositionMap(path)
        end

        for _, remote_highlight in ipairs(remote_highlights or {}) do
            if self:remoteHighlightExistsLocally(annotations, remote_highlight, profile, position_map) then
                counts.import_skipped = counts.import_skipped + 1
            else
                local ok, reason = self:addRemoteHighlightToAnnotations(
                    path,
                    annotations,
                    remote_highlight,
                    profile,
                    options,
                    position_map
                )
                if ok then
                    counts.imported = counts.imported + 1
                else
                    counts.import_failed = counts.import_failed + 1
                    if not counts.import_error_message then
                        counts.import_error_message = self:describeImportFailure(reason)
                    end
                    Log:info("Skipping remote highlight import:", reason)
                end
            end
        end

        return counts
    end

    function Readeck:formatHighlightSyncMessage(counts)
        counts = counts or {}
        local message_parts = {}
        if (counts.imported or 0) > 0 then
            table.insert(message_parts, T(L("Imported: %1"), counts.imported))
        end
        if (counts.success or 0) > 0 then
            table.insert(message_parts, T(L("Exported: %1"), counts.success))
        end
        if (counts.error or 0) > 0 then
            if counts.error_message then
                table.insert(message_parts, T(L("Failed: %1 (%2)"), counts.error, counts.error_message))
            else
                table.insert(message_parts, T(L("Failed: %1"), counts.error))
            end
        end
        if (counts.skipped or 0) > 0 then
            table.insert(message_parts, T(L("Skipped (overlap): %1"), counts.skipped))
        end
        if (counts.invalid or 0) > 0 then
            table.insert(message_parts, T(L("Skipped (unsupported): %1"), counts.invalid))
        end
        if (counts.import_failed or 0) > 0 then
            if counts.import_error_message then
                table.insert(
                    message_parts,
                    T(L("Import failed: %1 (%2)"), counts.import_failed, counts.import_error_message)
                )
            else
                table.insert(message_parts, T(L("Import failed: %1"), counts.import_failed))
            end
        end
        if (counts.remote_deleted or 0) > 0 then
            table.insert(message_parts, T(L("Kept local only: %1"), counts.remote_deleted))
        end
        if (counts.updated_local or 0) > 0 then
            table.insert(message_parts, T(L("Updated in KOReader: %1"), counts.updated_local))
        end
        if (counts.updated_remote or 0) > 0 then
            table.insert(message_parts, T(L("Updated in Readeck: %1"), counts.updated_remote))
        end
        if (counts.conflicts or 0) > 0 then
            table.insert(message_parts, T(L("Conflicts merged: %1"), counts.conflicts))
        end

        if #message_parts > 0 then
            return T(L("Finished syncing highlights.\n%1"), table.concat(message_parts, "\n"))
        end
        return L("Finished syncing highlights. No local or remote changes found.")
    end

    function Readeck:formatHighlightExportMessage(counts)
        return self:formatHighlightSyncMessage(counts)
    end

    function Readeck:syncHighlightsForArticle(article_id, path, annotations, options)
        options = options or {}
        annotations = annotations or {}

        if
            self:getBearerToken({
                on_oauth_success = function()
                    NetworkMgr:runWhenOnline(function()
                        self:syncHighlightsForArticle(article_id, path, annotations, options)
                    end)
                end,
            }) == false
        then
            return false, add_highlight_counts(new_highlight_counts(), { error = 1 })
        end

        local existing_highlights_raw, err = self:getApi():list_annotations(article_id)
        local existing_highlights = {}
        if err then
            if err.kind == Errors.KIND.AUTH_PENDING then
                return false, add_highlight_counts(new_highlight_counts(), { error = 1 })
            end
            if Errors.is_not_found(err) then
                -- The bookmark itself is gone: there is nothing left to sync
                -- and nothing to protect, so this counts as done rather than
                -- failed. Callers that guard a completion action on this
                -- (removeArticle) rely on `bookmark_missing` to stop retrying.
                Log:info("Bookmark gone from server, nothing to sync:", article_id)
                return true, add_highlight_counts(new_highlight_counts(), { bookmark_missing = 1 })
            end
            if not options.quiet then
                UIManager:show(InfoMessage:new({
                    text = L("Could not fetch existing highlights from Readeck. Aborting highlight sync."),
                }))
            end
            return false, add_highlight_counts(new_highlight_counts(), { error = 1 })
        end
        if existing_highlights_raw and type(existing_highlights_raw) == "table" then
            existing_highlights = existing_highlights_raw
        end

        local highlight_profile = self:getHighlightPayloadProfile()
        local counts = new_highlight_counts()
        local position_map = path and self:getPositionMap(path) or nil
        local remote_highlights_by_id = self:indexRemoteHighlightsByID(existing_highlights)
        local local_annotations_changed =
            self:repairImportedPositions(path, annotations, remote_highlights_by_id, position_map, counts)
        self:importRemoteHighlightsForPath(
            path,
            annotations,
            existing_highlights,
            highlight_profile,
            counts,
            options,
            position_map or false
        )

        for _, h in pairs(annotations) do
            local local_highlight, skip_reason = Highlights.build_payload(h, highlight_profile, position_map)

            if local_highlight then
                if self:shouldKeepRemoteDeletedHighlightLocal(h, remote_highlights_by_id) then
                    counts.remote_deleted = counts.remote_deleted + 1
                    Log:info("Keeping remote-deleted highlight local only:", h.readeck_annotation_id)
                else
                    local is_overlapping = false
                    local linked_remote_highlight = nil
                    for _, remote_h in ipairs(existing_highlights) do
                        if Highlights.local_matches_remote_id(h, remote_h) then
                            is_overlapping = true
                            linked_remote_highlight = remote_h
                            break
                        elseif Highlights.overlap(local_highlight, remote_h, position_map) then
                            is_overlapping = true
                            break
                        end
                    end

                    if is_overlapping then
                        if linked_remote_highlight then
                            local changed = LinkedSync.sync(
                                self,
                                article_id,
                                h,
                                linked_remote_highlight,
                                highlight_profile,
                                counts,
                                existing_highlights
                            )
                            local_annotations_changed = changed or local_annotations_changed
                        else
                            counts.skipped = counts.skipped + 1
                            Log:info("Skipping overlapping highlight:", local_highlight.text)
                        end
                    else
                        Log:debug(
                            "Start selector:",
                            local_highlight.start_selector,
                            "End selector:",
                            local_highlight.end_selector
                        )

                        local result, export_err = self:getApi():create_annotation(article_id, local_highlight)
                        if result then
                            counts.success = counts.success + 1
                            if type(result) == "table" and result.id then
                                local synced_result = {}
                                for key, value in pairs(local_highlight) do
                                    synced_result[key] = value
                                end
                                for key, value in pairs(result) do
                                    synced_result[key] = value
                                end
                                h.readeck_annotation_id = result.id
                                Highlights.apply_sync_snapshot(h, synced_result, highlight_profile)
                                local_annotations_changed = true
                                table.insert(existing_highlights, synced_result)
                                remote_highlights_by_id[tostring(result.id)] = synced_result
                            else
                                Highlights.apply_sync_snapshot(h, local_highlight, highlight_profile)
                                local_annotations_changed = true
                                table.insert(existing_highlights, local_highlight)
                            end
                        else
                            counts.error = counts.error + 1
                            -- Keep the first reason: one concrete cause beats a bare count.
                            if not counts.error_message and export_err and export_err.message then
                                counts.error_message = export_err.message
                            end
                            Log:warn(
                                "Highlight export rejected:",
                                export_err and export_err.message or (export_err and export_err.kind) or "unknown"
                            )
                        end
                    end
                end
            elseif skip_reason then
                counts.invalid = counts.invalid + 1
                Log:info("Skipping unsupported highlight:", skip_reason)
            end
        end
        if local_annotations_changed then
            self:saveAnnotationsForPath(path, annotations)
        end

        if not options.quiet then
            UIManager:show(InfoMessage:new({ text = self:formatHighlightSyncMessage(counts) }))
        end
        return counts.error == 0 and counts.import_failed == 0, counts
    end

    function Readeck:exportHighlightsForArticle(article_id, annotations, options)
        return self:syncHighlightsForArticle(article_id, nil, annotations, options)
    end

    function Readeck:syncHighlightsForPath(path, options)
        options = options or {}
        local article_id = self:getArticleID(path)
        if not article_id then
            if not options.quiet then
                UIManager:show(InfoMessage:new({ text = L("Could not find Readeck article ID for this document.") }))
            end
            return false, add_highlight_counts(new_highlight_counts(), { error = 1 })
        end
        return self:syncHighlightsForArticle(article_id, path, self:getAnnotationsForPath(path, options), options)
    end

    function Readeck:exportHighlightsForPath(path, options)
        return self:syncHighlightsForPath(path, options)
    end

    function Readeck:syncHighlightsForLocalFiles(options)
        options = options or {}
        if self:isempty(self.directory) or lfs.attributes(self.directory, "mode") ~= "directory" then
            return true, new_highlight_counts()
        end

        local ok = true
        local total_counts = new_highlight_counts()
        for _, path in ipairs(self:listLocalHighlightPaths()) do
            local export_ok, export_counts = self:syncHighlightsForPath(path, options)
            add_highlight_counts(total_counts, export_counts)
            if export_ok == false then
                ok = false
            end
        end
        return ok, total_counts
    end

    function Readeck:listLocalHighlightPaths()
        local paths = {}
        if self:isempty(self.directory) or lfs.attributes(self.directory, "mode") ~= "directory" then
            return paths
        end

        for entry in lfs.dir(self.directory) do
            if entry ~= "." and entry ~= ".." then
                local path = FFIUtil.joinPath(self.directory, entry)
                if self:getArticleID(path) and lfs.attributes(path, "mode") == "file" then
                    table.insert(paths, path)
                end
            end
        end
        return paths
    end

    function Readeck:syncHighlightsForLocalFilesAsync(options, done)
        options = options or {}
        done = done or function() end

        local paths = self:listLocalHighlightPaths()
        local total_counts = new_highlight_counts()
        local ok = true
        local total = #paths

        if total == 0 then
            UIManager:scheduleIn(0, function()
                done(true, total_counts)
            end)
            return true
        end

        if type(options.on_progress) == "function" then
            options.on_progress(0, total, total_counts)
        end

        local index = 0
        local function step()
            index = index + 1
            local path = paths[index]
            if not path then
                done(ok, total_counts)
                return
            end

            local export_ok, export_counts = self:syncHighlightsForPath(path, options)
            add_highlight_counts(total_counts, export_counts)
            if export_ok == false then
                ok = false
            end
            if type(options.on_progress) == "function" then
                options.on_progress(index, total, total_counts, path)
            end
            UIManager:scheduleIn(0, step)
        end

        UIManager:scheduleIn(0, step)
        return true
    end

    function Readeck:exportHighlightsForLocalFiles(options)
        return self:syncHighlightsForLocalFiles(options)
    end

    function Readeck:syncCurrentDocumentHighlights(options)
        local document = self.ui.document
        if not document then
            if not (options and options.quiet) then
                UIManager:show(InfoMessage:new({ text = L("No document opened.") }))
            end
            return true
        end
        return self:syncHighlightsForPath(document.file, options)
    end

    function Readeck:exportCurrentDocumentHighlights(options)
        return self:syncCurrentDocumentHighlights(options)
    end

    function Readeck:syncHighlights()
        return self:syncCurrentDocumentHighlights({ quiet = false })
    end

    function Readeck:exportHighlights()
        return self:syncHighlights()
    end
end

return Export
