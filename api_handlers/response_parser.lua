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
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,
    
    gemini = function(response)
        if response.candidates and response.candidates[1] and 
           response.candidates[1].content and response.candidates[1].content.parts and 
           response.candidates[1].content.parts[1] then
            return true, response.candidates[1].content.parts[1].text
        end
        return false, "Unexpected response format"
    end,
    
    deepseek = function(response)
        if response.choices and response.choices[1] and response.choices[1].message then
            return true, response.choices[1].message.content
        end
        return false, "Unexpected response format"
    end,
    
    ollama = function(response)
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
    
    return transform(response)
end

return ResponseParser 