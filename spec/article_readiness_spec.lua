package.path = "./readeck.koplugin/?.lua;" .. package.path

local ArticleReadiness = require("readeck.core.article_readiness")

describe("readeck.core.article_readiness", function()
    it("treats a fully loaded article as ready", function()
        local article = { state = 0, loaded = true, has_article = true, is_deleted = false }
        assert.are.equal(ArticleReadiness.READY, ArticleReadiness.classify(article))
        assert.is_true(ArticleReadiness.is_downloadable(article))
    end)

    it("treats state = 2 (loading) as pending", function()
        local article = { state = 2, loaded = false, has_article = false }
        assert.are.equal(ArticleReadiness.PENDING, ArticleReadiness.classify(article))
        assert.is_false(ArticleReadiness.is_downloadable(article))
    end)

    it("treats loaded = false as pending even without a state field", function()
        assert.are.equal(ArticleReadiness.PENDING, ArticleReadiness.classify({ loaded = false }))
    end)

    it("treats has_article = false as pending even without a state field", function()
        assert.are.equal(ArticleReadiness.PENDING, ArticleReadiness.classify({ has_article = false }))
    end)

    it("treats a finished bookmark without an article as a permanent error", function()
        -- What Readeck reports for an empty page, a 404 or an unreachable host.
        local article = {
            state = 0,
            loaded = true,
            has_article = false,
            errors = { "could not extract content" },
        }
        assert.are.equal(ArticleReadiness.ERROR, ArticleReadiness.classify(article))
    end)

    it("treats state = 1 (extraction error) as a permanent error", function()
        local article = { state = 1, loaded = true, has_article = false }
        assert.are.equal(ArticleReadiness.ERROR, ArticleReadiness.classify(article))
        assert.is_false(ArticleReadiness.is_downloadable(article))
    end)

    it("treats is_deleted = true as deleted regardless of other fields", function()
        local article = { state = 0, loaded = true, has_article = true, is_deleted = true }
        assert.are.equal(ArticleReadiness.DELETED, ArticleReadiness.classify(article))
        assert.is_false(ArticleReadiness.is_downloadable(article))
    end)

    it("treats a bookmark with none of the fields present as ready (older/other servers)", function()
        assert.are.equal(ArticleReadiness.READY, ArticleReadiness.classify({ id = "abc", title = "Some article" }))
        assert.is_true(ArticleReadiness.is_downloadable({ id = "abc" }))
    end)

    it("treats a nil article as ready rather than erroring", function()
        assert.are.equal(ArticleReadiness.READY, ArticleReadiness.classify(nil))
    end)
end)
