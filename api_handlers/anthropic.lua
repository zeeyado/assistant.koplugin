local BaseHandler = require("api_handlers.base")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local Defaults = require("api_handlers.defaults")
local RequestBuilder = require("api_handlers.request_builder")
local ResponseParser = require("api_handlers.response_parser")

local AnthropicHandler = BaseHandler:new()

function AnthropicHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing API key in configuration"
    end

    local defaults = Defaults.ProviderDefaults.anthropic
    
    -- Use the RequestBuilder to create the request body
    local request_body, error = RequestBuilder:buildRequestBody(message_history, config, "anthropic")
    if not request_body then
        return "Error: " .. error
    end

    -- Debug: Print request body
    if config and config.features and config.features.debug then
        print("Anthropic Request Body:", json.encode(request_body))
    end

    local requestBody = json.encode(request_body)
    local responseBody = {}
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = config.api_key,
        ["anthropic-version"] = defaults.additional_parameters.anthropic_version
    }

    local success, code = https.request({
        url = config.base_url or defaults.base_url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(requestBody),
        sink = ltn12.sink.table(responseBody)
    })

    -- Debug: Print raw response
    if config and config.features and config.features.debug then
        print("Anthropic Raw Response:", table.concat(responseBody))
    end

    local success, response = self:handleApiResponse(success, code, responseBody, "Anthropic")
    if not success then
        return response
    end
    
    -- Debug: Print parsed response
    if config and config.features and config.features.debug then
        print("Anthropic Parsed Response:", json.encode(response))
    end
    
    local success, result = ResponseParser:parseResponse(response, "anthropic")
    if not success then
        return "Error: " .. result
    end
    
    return result
end

return AnthropicHandler 