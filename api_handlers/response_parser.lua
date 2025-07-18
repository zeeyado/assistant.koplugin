local ResponseParser = {}

-- Response format transformers for each provider
local RESPONSE_TRANSFORMERS = {
    anthropic = function(response)
        if response.type == "error" and response.error then
            return false, response.error.message
        end
        
        if response.content and response.content[1] and response.content[1].text then
            return true, response.content[1].text
        end
        return false, "Unexpected response format"
    end,
    
    openai = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,
    
    gemini = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.code or "Unknown error"
        end
        
        -- Check for direct text response (some Gemini endpoints return this)
        if response.text then
            return true, response.text
        end
        
        -- Check for standard candidates format
        if response.candidates and response.candidates[1] then
            local candidate = response.candidates[1]
            if candidate.content and candidate.content.parts and candidate.content.parts[1] then
                return true, candidate.content.parts[1].text
            end
        end
        
        return false, "Unexpected response format"
    end,
    
    deepseek = function(response)
        -- Check for error response
        if response.error then
            return false, response.error.message or response.error.type or "Unknown error"
        end
        
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,
    
    ollama = function(response)
        -- Check for error response
        if response.error then
            return false, response.error
        end
        
        if response.message and response.message.content then
            return true, response.message.content
        end
        return false, "Unexpected response format"
    end
}

function ResponseParser:parseResponse(response, provider)
    local transform = RESPONSE_TRANSFORMERS[provider]
    if not transform then
        return false, "No response transformer found for provider: " .. tostring(provider)
    end
    
    -- Add detailed logging for debugging
    local success, result = transform(response)
    if not success and result == "Unexpected response format" then
        -- Provide more details about what was received
        local json = require("json")
        local response_str = "Unable to encode response"
        pcall(function() response_str = json.encode(response) end)
        return false, string.format("Unexpected response format from %s. Response: %s", 
                                   provider, response_str:sub(1, 200))
    end
    
    return success, result
end

return ResponseParser 