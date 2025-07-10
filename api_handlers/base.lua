local json = require("json")

local BaseHandler = {}

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:handleApiResponse(success, code, responseBody, provider)
    if not success then
        -- Use consistent error format for connection failures
        return false, string.format("Error: Failed to connect to %s API - %s", provider, tostring(code))
    end

    local response = json.decode(table.concat(responseBody))
    if not response then
        -- Use consistent error format for invalid responses
        return false, string.format("Error: Invalid response from %s API", provider)
    end

    return true, response
end

function BaseHandler:query(message_history)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end

return BaseHandler 