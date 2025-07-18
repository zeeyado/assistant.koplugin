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

    -- Handle empty response body
    if not responseBody or #responseBody == 0 then
        return false, string.format("Error: Empty response from %s API", provider)
    end

    -- Try to decode JSON response
    local responseText = table.concat(responseBody)
    local decode_success, response = pcall(json.decode, responseText)
    
    if not decode_success then
        -- Use consistent error format for invalid responses
        return false, string.format("Error: Invalid JSON response from %s API: %s", 
                                   provider, responseText:sub(1, 100))
    end

    -- Check HTTP status codes in the response (some APIs return errors with 200 OK)
    if code >= 400 then
        local error_msg = "Unknown error"
        if response and response.error then
            error_msg = response.error.message or response.error.type or json.encode(response.error)
        end
        return false, string.format("Error: %s API returned status %d: %s", provider, code, error_msg)
    end

    return true, response
end

function BaseHandler:query(message_history)
    -- To be implemented by specific handlers
    error("query method must be implemented")
end

return BaseHandler 