-- Centralized Prompt Service for managing all prompts
local logger = require("logger")

local PromptService = {}

function PromptService:new(settings)
    local o = {
        settings = settings,
        prompts_cache = nil,
        builtin_prompts = nil,
        ai_instructions = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function PromptService:init()
    -- Load built-in prompts once
    local ok, builtin = pcall(require, "builtin_prompts")
    if ok then
        self.builtin_prompts = builtin
        logger.info("PromptService: Loaded built-in prompts")
    else
        logger.err("PromptService: Failed to load builtin_prompts.lua: " .. tostring(builtin))
        self.builtin_prompts = { highlight_context = { prompts = {} }, file_browser_context = { prompts = {} }, multi_file_browser_context = { prompts = {} }, general_context = { prompts = {} } }
    end
    
    -- Load AI instructions
    local ok_ai, instructions = pcall(require, "ai_instructions")
    if ok_ai then
        self.ai_instructions = instructions
        logger.info("PromptService: Loaded AI instructions")
    else
        logger.err("PromptService: Failed to load ai_instructions.lua: " .. tostring(instructions))
        self.ai_instructions = nil
    end
end

function PromptService:getAllPrompts(context, include_disabled)
    if not self.prompts_cache then
        self:loadPrompts()
    end
    
    local prompts = {}
    local context_key = context
    
    -- Map context names to cache keys
    if context == "highlight" then
        context_key = "highlight"
    elseif context == "file_browser" or context == "book" then
        context_key = "book"
    elseif context == "multi_file_browser" or context == "multi_book" then
        context_key = "multi_book"
    elseif context == "general" then
        context_key = "general"
    else
        -- Return empty if unknown context
        return prompts
    end
    
    -- Return prompts for the specified context
    for _, prompt in ipairs(self.prompts_cache[context_key] or {}) do
        if include_disabled or prompt.enabled then
            table.insert(prompts, prompt)
        end
    end
    
    return prompts
end

function PromptService:getPrompt(context, prompt_id)
    local prompts = self:getAllPrompts(context, true)
    for _, prompt in ipairs(prompts) do
        if prompt.id == prompt_id then
            return prompt
        end
    end
    return nil
end

function PromptService:loadPrompts()
    logger.info("PromptService: Loading all prompts")
    
    self.prompts_cache = {
        highlight = {},
        book = {},
        multi_book = {},
        general = {}
    }
    
    -- 1. Load built-in prompts
    if self.builtin_prompts then
        -- Load highlight context prompts
        if self.builtin_prompts.highlight_context and self.builtin_prompts.highlight_context.prompts then
            for id, prompt in pairs(self.builtin_prompts.highlight_context.prompts) do
                self:addPromptToCache("highlight", id, prompt, "builtin", nil)
            end
        end
        
        -- Load book context prompts (backwards compatible with file_browser_context)
        if self.builtin_prompts.book_context and self.builtin_prompts.book_context.prompts then
            for id, prompt in pairs(self.builtin_prompts.book_context.prompts) do
                self:addPromptToCache("book", id, prompt, "builtin", nil)
            end
        elseif self.builtin_prompts.file_browser_context and self.builtin_prompts.file_browser_context.prompts then
            -- Backwards compatibility
            for id, prompt in pairs(self.builtin_prompts.file_browser_context.prompts) do
                self:addPromptToCache("book", id, prompt, "builtin", nil)
            end
        end
        
        -- Load multi book context prompts (backwards compatible with multi_file_browser_context)
        if self.builtin_prompts.multi_book_context and self.builtin_prompts.multi_book_context.prompts then
            for id, prompt in pairs(self.builtin_prompts.multi_book_context.prompts) do
                self:addPromptToCache("multi_book", id, prompt, "builtin", nil)
            end
        elseif self.builtin_prompts.multi_file_browser_context and self.builtin_prompts.multi_file_browser_context.prompts then
            -- Backwards compatibility
            for id, prompt in pairs(self.builtin_prompts.multi_file_browser_context.prompts) do
                self:addPromptToCache("multi_book", id, prompt, "builtin", nil)
            end
        end
        
        -- Load general context prompts
        if self.builtin_prompts.general_context and self.builtin_prompts.general_context.prompts then
            for id, prompt in pairs(self.builtin_prompts.general_context.prompts) do
                self:addPromptToCache("general", id, prompt, "builtin", nil)
            end
        end
    end
    
    -- 2. Load custom prompts from custom_prompts.lua
    local custom_prompts_path = self:getCustomPromptsPath()
    if custom_prompts_path then
        local ok, custom_prompts = pcall(dofile, custom_prompts_path)
        if ok and custom_prompts then
            logger.info("PromptService: Loading custom prompts from custom_prompts.lua")
            for i, prompt in ipairs(custom_prompts) do
                local id = "config_" .. i
                self:addCustomPrompt(id, prompt, "config")
            end
        end
    end
    
    -- 3. Load UI-created prompts from settings
    local ui_prompts = self.settings:readSetting("custom_prompts") or {}
    logger.info("PromptService: Loading " .. #ui_prompts .. " UI-created prompts")
    for i, prompt in ipairs(ui_prompts) do
        local id = "ui_" .. i
        self:addCustomPrompt(id, prompt, "ui")
    end
    
    -- Log summary
    local highlight_count = #(self.prompts_cache.highlight or {})
    local book_count = #(self.prompts_cache.book or {})
    local multi_book_count = #(self.prompts_cache.multi_book or {})
    local general_count = #(self.prompts_cache.general or {})
    logger.info("PromptService: Loaded " .. highlight_count .. " highlight prompts, " .. 
                book_count .. " book prompts, " ..
                multi_book_count .. " multi book prompts, " ..
                general_count .. " general prompts")
end

function PromptService:addPromptToCache(context, id, prompt, source, default_system_prompt)
    local disabled_prompts = self.settings:readSetting("disabled_prompts") or {}
    local key = context .. ":" .. (prompt.text or id)
    
    local prompt_data = {
        id = id,
        text = prompt.text or id,
        system_prompt = prompt.system_prompt or default_system_prompt,
        user_prompt = prompt.user_prompt,
        enabled = not disabled_prompts[key],
        source = source,
        provider = prompt.provider,
        model = prompt.model,
        requires = prompt.requires,
        include_book_context = prompt.include_book_context
    }
    
    table.insert(self.prompts_cache[context], prompt_data)
end

function PromptService:addCustomPrompt(id, prompt, source)
    -- Handle context specification
    local contexts = {}
    if prompt.context == "both" then
        contexts = {"highlight", "book"}
    elseif prompt.context == "all" then
        contexts = {"highlight", "book", "multi_book", "general"}
    elseif prompt.context == "highlight" or prompt.context == "book" or prompt.context == "multi_book" or prompt.context == "general" then
        contexts = {prompt.context}
    -- Handle legacy names
    elseif prompt.context == "file_browser" then
        contexts = {"book"}
    elseif prompt.context == "multi_file_browser" then
        contexts = {"multi_book"}
    else
        -- Default to both highlight and book if not specified
        contexts = {"highlight", "book"}
    end
    
    -- Add to each specified context
    for _, context in ipairs(contexts) do
        self:addPromptToCache(context, id, prompt, source, nil)
    end
end

function PromptService:setPromptEnabled(context, prompt_text, enabled)
    local disabled_prompts = self.settings:readSetting("disabled_prompts") or {}
    local key = context .. ":" .. prompt_text
    
    if enabled then
        disabled_prompts[key] = nil
    else
        disabled_prompts[key] = true
    end
    
    self.settings:saveSetting("disabled_prompts", disabled_prompts)
    self.settings:flush()
    
    -- Invalidate cache to force reload
    self.prompts_cache = nil
end

function PromptService:addUserPrompt(prompt_data)
    local custom_prompts = self.settings:readSetting("custom_prompts") or {}
    table.insert(custom_prompts, prompt_data)
    self.settings:saveSetting("custom_prompts", custom_prompts)
    self.settings:flush()
    
    -- Invalidate cache to force reload
    self.prompts_cache = nil
end

function PromptService:updateUserPrompt(index, prompt_data)
    local custom_prompts = self.settings:readSetting("custom_prompts") or {}
    if custom_prompts[index] then
        custom_prompts[index] = prompt_data
        self.settings:saveSetting("custom_prompts", custom_prompts)
        self.settings:flush()
        
        -- Invalidate cache to force reload
        self.prompts_cache = nil
    end
end

function PromptService:deleteUserPrompt(index)
    local custom_prompts = self.settings:readSetting("custom_prompts") or {}
    if custom_prompts[index] then
        table.remove(custom_prompts, index)
        self.settings:saveSetting("custom_prompts", custom_prompts)
        self.settings:flush()
        
        -- Invalidate cache to force reload
        self.prompts_cache = nil
    end
end

function PromptService:getSystemPrompt(context, prompt_type)
    -- Check for overrides from configuration first
    local config = self:loadConfiguration()
    if config and config.ai_instructions and config.ai_instructions.system_prompts then
        if prompt_type and config.ai_instructions.system_prompts[prompt_type] then
            return config.ai_instructions.system_prompts[prompt_type]
        end
    end
    
    -- Use centralized AI instructions if available
    if self.ai_instructions and self.ai_instructions.system_prompts then
        if prompt_type and self.ai_instructions.system_prompts[prompt_type] then
            return self.ai_instructions.system_prompts[prompt_type]
        end
        
        -- Map context to prompt type if not specified
        if context == "highlight" then
            return self.ai_instructions.system_prompts.highlight or 
                   self.ai_instructions.system_prompts.default
        elseif context == "book" or context == "file_browser" then
            return self.ai_instructions.system_prompts.book or
                   self.ai_instructions.system_prompts.file_browser or  -- backwards compat
                   self.ai_instructions.system_prompts.default
        elseif context == "multi_book" or context == "multi_file_browser" then
            return self.ai_instructions.system_prompts.multi_book or
                   self.ai_instructions.system_prompts.multi_file_browser or  -- backwards compat
                   self.ai_instructions.system_prompts.default
        elseif context == "general" then
            return self.ai_instructions.system_prompts.general or
                   self.ai_instructions.system_prompts.default
        elseif context == "translation" then
            return self.ai_instructions.system_prompts.translation or
                   self.ai_instructions.system_prompts.default
        elseif context == "conversation" then
            return self.ai_instructions.system_prompts.conversation or
                   self.ai_instructions.system_prompts.default
        end
    end
    
    -- Final fallback
    return "You are a helpful assistant."
end

function PromptService:getActionTemplate(template_name)
    -- Check for overrides from configuration first
    local config = self:loadConfiguration()
    if config and config.ai_instructions and config.ai_instructions.action_templates then
        if config.ai_instructions.action_templates[template_name] then
            return config.ai_instructions.action_templates[template_name]
        end
    end
    
    -- Use centralized AI instructions
    if self.ai_instructions and self.ai_instructions.action_templates then
        return self.ai_instructions.action_templates[template_name]
    end
    
    return nil
end


function PromptService:getErrorTemplate(template_name)
    -- Check for overrides from configuration first
    local config = self:loadConfiguration()
    if config and config.ai_instructions and config.ai_instructions.error_templates then
        if config.ai_instructions.error_templates[template_name] then
            return config.ai_instructions.error_templates[template_name]
        end
    end
    
    -- Use centralized AI instructions
    if self.ai_instructions and self.ai_instructions.error_templates then
        return self.ai_instructions.error_templates[template_name]
    end
    
    return nil
end

function PromptService:loadConfiguration()
    local config_path = self:getConfigPath()
    local ok, config = pcall(dofile, config_path)
    if ok and config then
        return config
    end
    return nil
end

function PromptService:getConfigPath()
    -- Get the directory of this script
    local function script_path()
       local str = debug.getinfo(2, "S").source:sub(2)
       return str:match("(.*/)")
    end
    
    local plugin_dir = script_path()
    return plugin_dir .. "configuration.lua"
end

function PromptService:getCustomPromptsPath()
    -- Get the directory of this script
    local function script_path()
       local str = debug.getinfo(2, "S").source:sub(2)
       return str:match("(.*/)") or "./"
    end
    
    local plugin_dir = script_path()
    local custom_prompts_file = plugin_dir .. "custom_prompts.lua"
    
    -- Check if file exists
    local f = io.open(custom_prompts_file, "r")
    if f then
        f:close()
        return custom_prompts_file
    end
    
    return nil
end

-- Initialize the service when loaded
function PromptService:initialize()
    self:init()
end

return PromptService