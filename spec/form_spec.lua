package.path = "./?.lua;./readeck.koplugin/?.lua;" .. package.path

local install_koreader_stubs = require("spec.support.koreader_stubs")

-- Exercises Readeck:encodeFormData / Readeck:urlEncodeFormValue
-- (readeck/auth/form.lua). Pure functions used to build the body of every
-- OAuth request (device authorization, token, refresh).

local function build_instance()
    install_koreader_stubs()
    local Readeck = dofile("readeck.koplugin/main.lua")
    return setmetatable({}, { __index = Readeck })
end

describe("Readeck:urlEncodeFormValue", function()
    it("encodes a space as a plus sign", function()
        local instance = build_instance()
        assert.are.equal("a+b", instance:urlEncodeFormValue("a b"))
    end)

    it("turns a bare newline into CRLF before percent-escaping it", function()
        local instance = build_instance()
        -- \n -> \r\n, then both \r and \n get percent-escaped.
        assert.are.equal("a%0D%0Ab", instance:urlEncodeFormValue("a\nb"))
    end)

    it("percent-encodes reserved characters using uppercase hex", function()
        local instance = build_instance()
        assert.are.equal("%26%3D%3F%2F%3A", instance:urlEncodeFormValue("&=?/:"))
    end)

    it("does not escape the unreserved characters - _ . ~", function()
        local instance = build_instance()
        assert.are.equal("a-b_c.d~e", instance:urlEncodeFormValue("a-b_c.d~e"))
    end)

    it("does not escape alphanumeric characters", function()
        local instance = build_instance()
        assert.are.equal("abcXYZ019", instance:urlEncodeFormValue("abcXYZ019"))
    end)
end)

describe("Readeck:encodeFormData", function()
    it("repeats the key once per item for a table value", function()
        local instance = build_instance()
        assert.are.equal("scope=a&scope=b&scope=c", instance:encodeFormData({ scope = { "a", "b", "c" } }))
    end)

    it("sorts the encoded parts so output is reproducible", function()
        local instance = build_instance()
        -- Deliberately provide fields in an order that would produce a
        -- different (unsorted) string if the sort were dropped.
        local encoded = instance:encodeFormData({
            grant_type = "authorization_code",
            client_id = "abc",
            code = "xyz",
        })
        assert.are.equal("client_id=abc&code=xyz&grant_type=authorization_code", encoded)
    end)

    it("url-encodes both keys and values", function()
        local instance = build_instance()
        assert.are.equal("a+b=c%26d", instance:encodeFormData({ ["a b"] = "c&d" }))
    end)

    it("produces the same sorted output regardless of table iteration order", function()
        local instance = build_instance()
        local encoded_1 = instance:encodeFormData({ z = "1", a = "2", m = "3" })
        local encoded_2 = instance:encodeFormData({ a = "2", m = "3", z = "1" })
        assert.are.equal(encoded_1, encoded_2)
        assert.are.equal("a=2&m=3&z=1", encoded_1)
    end)
end)
