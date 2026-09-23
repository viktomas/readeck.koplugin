-- Pure classification of a Readeck bookmark's article-content readiness.
--
-- Readeck fetches and converts an article's readable content asynchronously
-- after a bookmark is created. Until that finishes, the article.epub download
-- endpoint 404s. This module gives sync code a single, testable place to
-- decide whether a bookmark's article can be downloaded right now, will
-- never be downloadable, or is merely not ready yet.
--
-- Readeck's `state` field: 0 = loaded, 1 = error (extraction failed),
-- 2 = loading. Older/other servers may omit `state`, `loaded` and
-- `has_article` entirely; a bookmark missing all of these fields must be
-- treated exactly as today: ready to download.

local ArticleReadiness = {}

ArticleReadiness.READY = "ready"
ArticleReadiness.PENDING = "pending"
ArticleReadiness.ERROR = "error"
ArticleReadiness.DELETED = "deleted"

-- Returns one of ArticleReadiness.READY / PENDING / ERROR / DELETED for the
-- given bookmark table.
function ArticleReadiness.classify(article)
    article = article or {}

    if article.is_deleted == true then
        return ArticleReadiness.DELETED
    end

    if article.state == 1 then
        return ArticleReadiness.ERROR
    end

    if article.state == 2 then
        return ArticleReadiness.PENDING
    end

    if article.loaded == false then
        return ArticleReadiness.PENDING
    end

    -- Readeck's `loaded` is `state != loading` and `has_article` is "the
    -- article file exists" (internal/bookmarks/dataset/bookmarks.go). A
    -- failed extraction does not use state=1: it finishes with state=0,
    -- loaded=true, has_article=false and `errors` set (measured on 0.23.4
    -- with an empty page, a 404 and an unreachable host). That is final.
    if article.loaded == true and article.has_article == false then
        return ArticleReadiness.ERROR
    end

    if article.has_article == false then
        return ArticleReadiness.PENDING
    end

    return ArticleReadiness.READY
end

-- Convenience predicate: can we attempt a download of this bookmark's
-- article right now?
function ArticleReadiness.is_downloadable(article)
    return ArticleReadiness.classify(article) == ArticleReadiness.READY
end

return ArticleReadiness
