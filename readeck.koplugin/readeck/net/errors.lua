local Errors = {}

Errors.KIND = {
    NETWORK_ERROR = "network_error",
    FILE_ERROR = "file_error",
    JSON_ERROR = "json_error",
    AUTH_PENDING = "auth_pending",
    AUTH_ERROR = "auth_error",
    HTTP_ERROR = "http_error",
    CONFIG_ERROR = "config_error",
}

function Errors.new(kind, code, status)
    return {
        kind = kind,
        code = code,
        status = status,
    }
end

return Errors
