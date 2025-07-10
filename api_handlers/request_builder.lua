local Defaults = require("api_handlers.defaults")

local RequestBuilder = {}

function RequestBuilder:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Message format transformers for each provider
local MESSAGE_TRANSFORMERS = {
    anthropic = function(messages)
        local transformed = {}
        for _, msg in ipairs(messages) do
            if msg.role ~= "system" then
                table.insert(transformed, {
                    role = msg.role == "assistant" and "assistant" or "user",
                    content = msg.content
                })
            end
        end
        return transformed
    end,
    
    gemini = function(messages)
        local transformed = {}
        for _, msg in ipairs(messages) do
            table.insert(transformed, {
                role = msg.role == "assistant" and "model" or "user",
                parts = {{ text = msg.content }}
            })
        end
        return transformed
    end,
    
    openai = function(messages)
        return messages -- OpenAI uses the standard format
    end,
    
    deepseek = function(messages)
        return messages -- DeepSeek uses the same format as OpenAI
    end,
    
    ollama = function(messages)
        local transformed = {}
        for _, msg in ipairs(messages) do
            table.insert(transformed, {
                role = msg.role,
                content = msg.content
            })
        end
        return transformed
    end
}

function RequestBuilder:buildRequestBody(message_history, config, provider)
    local defaults = Defaults.ProviderDefaults[provider]
    if not defaults then
        return nil, "Unsupported provider: " .. tostring(provider)
    end

    -- Transform messages according to provider format
    local transform = MESSAGE_TRANSFORMERS[provider]
    if not transform then
        return nil, "No message transformer found for provider: " .. tostring(provider)
    end

    local transformed_messages = transform(message_history)

    -- Build base request body
    local request_body = {
        model = config.model or defaults.model
    }

    -- Add messages/contents based on provider format
    if provider == "gemini" then
        request_body.contents = transformed_messages
    else
        request_body.messages = transformed_messages
    end

    -- Add additional parameters from defaults and config
    if defaults.additional_parameters then
        for key, default_value in pairs(defaults.additional_parameters) do
            -- Skip parameters that should be in headers
            if key ~= "anthropic_version" then
                request_body[key] = (config.additional_parameters and config.additional_parameters[key]) 
                    or default_value
            end
        end
    end

    return request_body
end

return RequestBuilder 