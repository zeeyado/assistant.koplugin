local api_key = nil
local CONFIGURATION = nil
local Defaults = require("api_handlers.defaults")
local ConfigHelper = require("config_helper")

-- Attempt to load the configuration module first
local success, result = pcall(function() return require("configuration") end)
if success then
    CONFIGURATION = result
else
    print("configuration.lua not found, attempting legacy api_key.lua...")
    -- Try legacy api_key as fallback
    success, result = pcall(function() return require("api_key") end)
    if success then
        api_key = result.key
        -- Create configuration from legacy api_key using defaults
        local provider = "anthropic" -- Default provider
        CONFIGURATION = Defaults.ProviderDefaults[provider]
        CONFIGURATION.api_key = api_key
    else
        print("No configuration found. Please set up configuration.lua")
    end
end

-- Define handlers table with proper error handling
local handlers = {}
local function loadHandler(name)
    local success, handler = pcall(function() 
        return require("api_handlers." .. name)
    end)
    if success then
        handlers[name] = handler
    else
        print("Failed to load " .. name .. " handler: " .. tostring(handler))
    end
end

loadHandler("anthropic")
loadHandler("openai")
loadHandler("deepseek")
loadHandler("ollama")
loadHandler("gemini")

local function getApiKey(provider)
    local success, apikeys = pcall(function() return require("apikeys") end)
    if success and apikeys and apikeys[provider] then
        return apikeys[provider]
    end
    return nil
end

local function queryChatGPT(message_history, temp_config)
    -- Merge config with defaults
    local config = ConfigHelper:mergeWithDefaults(temp_config or CONFIGURATION)
    
    -- Validate configuration
    local valid, error = ConfigHelper:validate(config)
    if not valid then
        -- Use consistent error format
        return "Error: " .. error
    end
    
    local provider = config.provider
    local handler = handlers[provider]
    
    -- Get API key for the selected provider
    config.api_key = getApiKey(provider)
    if not config.api_key then
        -- Use consistent error format for missing API key
        return string.format("Error: No API key found for provider %s. Please check apikeys.lua", provider)
    end
    
    local success, result = pcall(function()
        return handler:query(message_history, config)
    end)
    
    if not success then
        -- Use consistent error format for query errors
        return "Error: " .. tostring(result)
    end
    
    return result
end

return queryChatGPT