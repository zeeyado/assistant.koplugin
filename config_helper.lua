local Defaults = require("api_handlers.defaults")

local ConfigHelper = {}

function ConfigHelper:mergeWithDefaults(config, provider)
    if not config then return nil end
    
    -- Deep copy the config to avoid modifying the original
    local merged = {}
    for k, v in pairs(config) do
        merged[k] = type(v) == "table" and self:deepCopy(v) or v
    end
    
    -- Get provider, falling back to default
    provider = provider or merged.provider or "anthropic"
    local defaults = Defaults.ProviderDefaults[provider]
    if not defaults then return nil end
    
    -- Ensure provider settings exist
    merged.provider = provider
    merged.provider_settings = merged.provider_settings or {}
    merged.provider_settings[provider] = merged.provider_settings[provider] or {}
    
    -- Merge with defaults
    local provider_settings = merged.provider_settings[provider]
    for k, v in pairs(defaults) do
        if k == "additional_parameters" then
            provider_settings[k] = provider_settings[k] or {}
            for param_k, param_v in pairs(v) do
                provider_settings[k][param_k] = provider_settings[k][param_k] or param_v
            end
        else
            provider_settings[k] = provider_settings[k] or v
        end
    end
    
    -- Handle top-level model override
    if merged.model then
        merged.provider_settings[provider].model = merged.model
    end
    
    return merged
end

function ConfigHelper:getModelInfo(config)
    if not config then return "default" end
    local provider = config.provider
    
    return (config.provider_settings and 
        config.provider_settings[provider] and 
        config.provider_settings[provider].model) or
        (config.model) or
        (Defaults.ProviderDefaults[provider] and 
        Defaults.ProviderDefaults[provider].model) or
        "default"
end

function ConfigHelper:deepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = type(v) == "table" and self:deepCopy(v) or v
    end
    return copy
end

function ConfigHelper:validate(config)
    if not config then 
        return false, "No configuration found" 
    end
    
    local provider = config.provider
    if not provider then
        return false, "No provider specified in configuration"
    end
    
    if not Defaults.ProviderDefaults[provider] then
        return false, "Unsupported provider: " .. provider
    end
    
    return true
end

return ConfigHelper 