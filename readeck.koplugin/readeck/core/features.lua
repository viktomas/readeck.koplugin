local Features = {}

-- Readeck advertises only "oauth" in /api/info (plus "email" when the caller has
-- the email:send permission) - see internal/server/server.go in the Readeck
-- source. There is no feature string for annotation notes or for the "none"
-- highlight colour, so both are gated on the server version that introduced
-- them instead: 0.22.0 ("Highlights with annotations" in Readeck's changelog).
-- Measured by the e2e suite against real release binaries: 0.21.6 silently
-- drops a note, 0.22.0 and 0.22.1 store it. The gate used to be 0.22.2, which
-- stripped notes from exports to 0.22.0/0.22.1 servers.
local ANNOTATION_FEATURES_MIN_VERSION = "0.22.0"

local function parse_version(version)
    version = tostring(version or "")
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then
        return nil
    end
    return {
        tonumber(major) or 0,
        tonumber(minor) or 0,
        tonumber(patch) or 0,
    }
end

function Features.has_feature(info, feature)
    if type(info) ~= "table" or type(info.features) ~= "table" then
        return nil
    end
    for _, value in ipairs(info.features) do
        if value == feature then
            return true
        end
    end
    return false
end

function Features.supports_oauth(info)
    return Features.has_feature(info, "oauth")
end

function Features.version(info)
    if type(info) ~= "table" or type(info.version) ~= "table" then
        return nil
    end
    return info.version.canonical or info.version.release
end

function Features.version_at_least(info, target)
    local current = parse_version(Features.version(info))
    local expected = parse_version(target)
    if not current or not expected then
        return false
    end

    for i = 1, 3 do
        if current[i] > expected[i] then
            return true
        end
        if current[i] < expected[i] then
            return false
        end
    end
    return true
end

function Features.supports_annotation_notes(info)
    return Features.version_at_least(info, ANNOTATION_FEATURES_MIN_VERSION)
end

function Features.supports_annotation_none_color(info)
    return Features.version_at_least(info, ANNOTATION_FEATURES_MIN_VERSION)
end

function Features.highlight_payload_profile(info)
    return {
        notes = Features.supports_annotation_notes(info),
        none_color = Features.supports_annotation_none_color(info),
    }
end

return Features
