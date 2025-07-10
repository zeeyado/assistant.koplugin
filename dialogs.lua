local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local gettext = require("gettext")
local _ = gettext    -- Keep the shorthand but make it local

local queryChatGPT = require("gpt_query")
local ConfigHelper = require("config_helper")
local MessageHistory = require("message_history")
local ChatHistoryManager = require("chat_history_manager")
local logger = require("logger")

local CONFIGURATION = nil
local input_dialog

-- Try to load configuration from the same directory as this script
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local plugin_dir = script_path()
local config_path = plugin_dir .. "configuration.lua"

local success, result = pcall(dofile, config_path)
if success then
    CONFIGURATION = result
else
    print("configuration.lua not found at " .. config_path .. ", skipping...")
end

-- Add a global variable to track active chat viewers
if not _G.ActiveChatViewer then
    _G.ActiveChatViewer = nil
end

local function showLoadingDialog()
    local loading = InfoMessage:new{
        text = _("Loading..."),
        timeout = 0.1
    }
    UIManager:show(loading)
end

-- Helper function to determine prompt context
local function getPromptContext(config)
    if config and config.features then
        if config.features.is_multi_book_context then
            return "multi_book"
        elseif config.features.is_book_context then
            return "book"
        elseif config.features.is_general_context then
            return "general"
        end
    end
    return "highlight"  -- default
end

local function createTempConfig(prompt, base_config)
    -- Use the passed base_config if available, otherwise fall back to CONFIGURATION
    local source_config = base_config or CONFIGURATION or {}
    local temp_config = {}
    
    for k, v in pairs(source_config) do
        if type(v) ~= "table" then
            temp_config[k] = v
        else
            temp_config[k] = {}
            for k2, v2 in pairs(v) do
                temp_config[k][k2] = v2
            end
        end
    end
    
    -- Only override if provider/model are specified in the prompt
    if prompt.provider then 
        temp_config.provider = prompt.provider
        if prompt.model then
            temp_config.provider_settings = temp_config.provider_settings or {}
            temp_config.provider_settings[temp_config.provider] = temp_config.provider_settings[temp_config.provider] or {}
            temp_config.provider_settings[temp_config.provider].model = prompt.model
        end
    end
    
    return temp_config
end

local function getAllPrompts(configuration, plugin)
    local prompts = {}
    local prompt_keys = {}  -- Array to store keys in order
    
    -- Use the passed configuration or the global one
    local config = configuration or CONFIGURATION
    
    -- Determine context
    local context = config and getPromptContext(config) or "highlight"
    
    -- Debug logging
    local logger = require("logger")
    logger.info("getAllPrompts: context = " .. context)
    
    -- Use PromptService if available
    if plugin and plugin.prompt_service then
        local service_prompts = plugin.prompt_service:getAllPrompts(context)
        logger.info("getAllPrompts: Got " .. #service_prompts .. " prompts from service")
        
        -- Convert from array to keyed table for compatibility
        for _, prompt in ipairs(service_prompts) do
            local key = prompt.id or ("prompt_" .. #prompt_keys + 1)
            prompts[key] = prompt
            table.insert(prompt_keys, key)
        end
    else
        logger.warn("getAllPrompts: PromptService not available, no prompts returned")
    end
    
    return prompts, prompt_keys
end

local function createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata)
    -- Guard against missing document path - allow special case for general context
    if not document_path and not is_general_context then
        UIManager:show(InfoMessage:new{
            text = _("Cannot save: no document context"),
            timeout = 2,
        })
        return
    end
    
    -- Use special path for general context chats
    if is_general_context and not document_path then
        document_path = "__GENERAL_CHATS__"
    end
    
    -- Get a suggested title from the conversation
    local suggested_title = history:getSuggestedTitle()
    
    -- Create the dialog with proper variable handling
    local save_dialog
    save_dialog = InputDialog:new{
        title = _("Save Chat"),
        input = suggested_title,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        -- Close the dialog and do nothing else
                        UIManager:close(save_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        -- First get the title
                        local chat_title = save_dialog:getInputText()
                        
                        -- Then close the dialog
                        UIManager:close(save_dialog)
                        
                        -- Now handle the save operation with error protection
                        local success, result = pcall(function()
                            -- Check if this chat already has an ID (continuation of existing chat)
                            local metadata = {}
                            if history.chat_id then
                                metadata.id = history.chat_id
                            end
                            
                            -- Add book metadata if available
                            if book_metadata then
                                metadata.book_title = book_metadata.title
                                metadata.book_author = book_metadata.author
                                logger.info("Assistant: Saving chat with metadata - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
                            else
                                logger.info("Assistant: No book metadata available for save")
                            end
                            
                            return chat_history_manager:saveChat(
                                document_path, 
                                chat_title, 
                                history,
                                metadata
                            )
                        end)
                        
                        -- Show appropriate message
                        if success and result then
                            -- Store the chat ID in history for future saves
                            if not history.chat_id then
                                history.chat_id = result
                            end
                            
                            UIManager:show(InfoMessage:new{
                                text = _("Chat saved successfully"),
                                timeout = 2,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to save chat: ") .. tostring(result),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    
    -- Show the dialog now that it's fully defined
    UIManager:show(save_dialog)
end

-- Function to show export options dialog for the current chat
local function showExportOptions(history)
    local ButtonDialog = require("ui/widget/buttondialog")
    local Device = require("device")
    local InfoMessage = require("ui/widget/infomessage")
    local T = require("ffi/util").template
    local _ = require("gettext")
    
    local buttons = {
        {
            {
                text = _("Copy as Text"),
                callback = function()
                    -- Create plain text format
                    local result = {}
                    table.insert(result, "Chat")
                    table.insert(result, "Date: " .. os.date("%Y-%m-%d %H:%M"))
                    table.insert(result, "Model: " .. (history:getModel() or "Unknown"))
                    table.insert(result, "")
                    
                    -- Format messages
                    for _, msg in ipairs(history:getMessages()) do
                        local role = msg.role:gsub("^%l", string.upper)
                        local content = msg.content
                        
                        -- Skip context messages in export by default
                        if not msg.is_context then
                            table.insert(result, role .. ": " .. content)
                            table.insert(result, "")
                        end
                    end
                    
                    local text = table.concat(result, "\n")
                    if text then
                        Device.input.setClipboardText(text)
                        UIManager:show(InfoMessage:new{
                            text = _("Chat copied to clipboard as text"),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text = _("Copy as Markdown"),
                callback = function()
                    -- Create markdown format
                    local result = {}
                    table.insert(result, "# Chat")
                    table.insert(result, "**Date:** " .. os.date("%Y-%m-%d %H:%M"))
                    table.insert(result, "**Model:** " .. (history:getModel() or "Unknown"))
                    table.insert(result, "")
                    
                    -- Format messages
                    for _, msg in ipairs(history:getMessages()) do
                        local role = msg.role:gsub("^%l", string.upper)
                        local content = msg.content
                        
                        -- Skip context messages in export by default
                        if not msg.is_context then
                            table.insert(result, "### " .. role)
                            table.insert(result, content)
                            table.insert(result, "")
                        end
                    end
                    
                    local markdown = table.concat(result, "\n")
                    if markdown then
                        Device.input.setClipboardText(markdown)
                        UIManager:show(InfoMessage:new{
                            text = _("Chat copied to clipboard as markdown"),
                            timeout = 2,
                        })
                    end
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    local dialog = UIManager.current_dialog
                    if dialog then
                        UIManager:close(dialog)
                    end
                end,
            },
        },
    }
    
    local export_dialog = ButtonDialog:new{
        title = _("Export Chat"),
        buttons = buttons,
    }
    
    -- Update the close button callback to use the local reference
    export_dialog.buttons[2][1].callback = function()
        UIManager:close(export_dialog)
    end
    
    UIManager:show(export_dialog)
end

local function showResponseDialog(title, history, highlightedText, addMessage, temp_config, document_path, plugin, book_metadata)
    local result_text = history:createResultText(highlightedText, temp_config or CONFIGURATION)
    local model_info = history:getModel() or ConfigHelper:getModelInfo(temp_config)
    
    -- Initialize chat history manager
    local chat_history_manager = ChatHistoryManager:new()
    
    -- Close existing chat viewer if any
    if _G.ActiveChatViewer then
        UIManager:close(_G.ActiveChatViewer)
        _G.ActiveChatViewer = nil
    end
    
    local chatgpt_viewer = ChatGPTViewer:new {
        title = title .. " (" .. model_info .. ")",
        text = result_text,
        configuration = temp_config or CONFIGURATION,  -- Pass configuration for debug toggle
        debug_mode = temp_config and temp_config.features and temp_config.features.debug or false,
        original_history = history,
        original_highlighted_text = highlightedText,
        settings_callback = function(path, value)
            -- Update plugin settings if plugin instance is available
            if plugin and plugin.settings then
                local parts = {}
                for part in path:gmatch("[^.]+") do
                    table.insert(parts, part)
                end
                
                -- Navigate to the setting and update it
                local setting = plugin.settings
                for i = 1, #parts - 1 do
                    setting = setting:readSetting(parts[i]) or {}
                end
                
                -- Update the final value
                if setting then
                    local existing = plugin.settings:readSetting(parts[1]) or {}
                    if #parts == 2 then
                        existing[parts[2]] = value
                    end
                    plugin.settings:saveSetting(parts[1], existing)
                    plugin.settings:flush()
                    
                    -- Also update configuration object
                    plugin:updateConfigFromSettings()
                    
                    -- Update temp_config if it exists
                    if temp_config and temp_config.features and parts[1] == "features" and parts[2] == "debug" then
                        temp_config.features.debug = value
                    end
                end
            end
        end,
        update_debug_callback = function(enabled)
            -- Update debug mode in history if available
            if history and history.debug_mode ~= nil then
                history.debug_mode = enabled
            end
        end,
        onAskQuestion = function(viewer, question)
            -- Show loading dialog
            showLoadingDialog()
            
            -- Process the question
            addMessage(question)
            
            -- Update the viewer with new content
            UIManager:scheduleIn(0.1, function()
                -- Check if our global reference is still the same
                if _G.ActiveChatViewer == viewer then
                    -- Always close the existing viewer
                    UIManager:close(viewer)
                    _G.ActiveChatViewer = nil
                    
                    -- Create a new viewer with updated content
                    local new_viewer = ChatGPTViewer:new {
                        title = title .. " (" .. model_info .. ")",
                        text = history:createResultText(highlightedText, temp_config or CONFIGURATION),
                        scroll_to_bottom = true, -- Scroll to bottom to show new question
                        debug_mode = viewer.debug_mode,
                        original_history = history,
                        original_highlighted_text = highlightedText,
                        settings_callback = viewer.settings_callback,
                        update_debug_callback = viewer.update_debug_callback,
                        onAskQuestion = viewer.onAskQuestion,
                        save_callback = viewer.save_callback,
                        export_callback = viewer.export_callback,
                        close_callback = function()
                            if _G.ActiveChatViewer == new_viewer then
                                _G.ActiveChatViewer = nil
                            end
                        end
                    }
                    
                    -- Set global reference to new viewer
                    _G.ActiveChatViewer = new_viewer
                    
                    -- Show the new viewer
                    UIManager:show(new_viewer)
                end
            end)
        end,
        save_callback = function()
            -- Check if auto-save all chats is enabled
            if temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
                UIManager:show(InfoMessage:new{
                    text = T("Auto-save all chats is on - this can be changed in the settings"),
                    timeout = 3,
                })
            else
                -- Call our helper function to handle saving
                local is_general_context = temp_config and temp_config.features and temp_config.features.is_general_context or false
                createSaveDialog(document_path, history, chat_history_manager, is_general_context, book_metadata)
            end
        end,
        export_callback = function()
            -- Call our helper function to handle exporting
            showExportOptions(history)
        end,
        close_callback = function()
            if _G.ActiveChatViewer == chatgpt_viewer then
                _G.ActiveChatViewer = nil
            end
        end
    }
    
    -- Set global reference
    _G.ActiveChatViewer = chatgpt_viewer
    
    -- Show the viewer
    UIManager:show(chatgpt_viewer)
    
    -- Auto-save if enabled
    if temp_config and temp_config.features and temp_config.features.auto_save_all_chats then
        -- Schedule auto-save to run after viewer is displayed
        UIManager:scheduleIn(0.1, function()
            local is_general_context = temp_config.features.is_general_context or false
            local suggested_title = history:getSuggestedTitle()
            
            -- Create metadata for saving
            local metadata = {}
            if history.chat_id then
                metadata.id = history.chat_id
            end
            if book_metadata then
                metadata.book_title = book_metadata.title
                metadata.book_author = book_metadata.author
            end
            
            -- Save with suggested title
            local success = chat_history_manager:saveChat(
                document_path or (is_general_context and "__GENERAL_CHATS__" or nil),
                suggested_title,
                history,
                metadata
            )
            
            if success then
                logger.info("Assistant: Auto-saved chat with title: " .. suggested_title)
            else
                logger.warn("Assistant: Failed to auto-save chat")
            end
        end)
    end
end

-- Helper function to build consolidated messages
local function buildConsolidatedMessage(prompt, context, data, system_prompt)
    local parts = {}
    
    -- Add system prompt if provided
    if system_prompt then
        table.insert(parts, "")  -- Add line break before [Instructions]
        table.insert(parts, "[Instructions]")
        table.insert(parts, system_prompt)
        table.insert(parts, "")
    end
    
    -- Get the user prompt template
    local user_prompt = prompt.user_prompt or "Please analyze:"
    
    -- Handle different contexts
    if context == "multi_file_browser" then
        -- Multi-file context with {count} and {books_list} substitution
        if data.books_info then
            local count = #data.books_info
            local books_list = {}
            for i, book in ipairs(data.books_info) do
                local book_str = string.format('%d. "%s"', i, book.title or "Unknown Title")
                if book.authors and book.authors ~= "" then
                    book_str = book_str .. " by " .. book.authors
                end
                table.insert(books_list, book_str)
            end
            user_prompt = user_prompt:gsub("{count}", tostring(count))
            user_prompt = user_prompt:gsub("{books_list}", table.concat(books_list, "\n"))
        elseif data.book_context then
            -- Fallback: use pre-formatted book context if books_info not available
            table.insert(parts, "[Context]")
            table.insert(parts, data.book_context)
            table.insert(parts, "")
        end
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)
        
    elseif context == "file_browser" then
        -- Add book context if available
        if data.book_metadata then
            local metadata = data.book_metadata
            -- Replace template variables
            user_prompt = user_prompt:gsub("{title}", metadata.title or "Unknown")
            user_prompt = user_prompt:gsub("{author}", metadata.author or "")
            user_prompt = user_prompt:gsub("{author_clause}", metadata.author_clause or "")
        end
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)
        
    elseif context == "general" then
        -- General context - just the prompt
        table.insert(parts, "[Request]")
        table.insert(parts, user_prompt)
        
    else  -- highlight context
        -- Add book context if requested
        if prompt.include_book_context and data.book_title then
            table.insert(parts, "[Context]")
            table.insert(parts, string.format('From "%s" by %s', 
                data.book_title or "Unknown Title", 
                data.book_author or "Unknown Author"))
            table.insert(parts, "")
        end
        
        -- Add highlighted text context
        if data.highlighted_text then
            -- Handle template replacement
            if user_prompt:find("{highlighted_text}") then
                user_prompt = user_prompt:gsub("{highlighted_text}", data.highlighted_text)
                table.insert(parts, "[Request]")
                table.insert(parts, user_prompt)
            else
                -- Old format: show text first, then prompt
                table.insert(parts, "Selected text:")
                table.insert(parts, '"' .. data.highlighted_text .. '"')
                table.insert(parts, "")
                table.insert(parts, "[Request]")
                table.insert(parts, user_prompt)
            end
        else
            table.insert(parts, "[Request]")
            table.insert(parts, user_prompt)
        end
    end
    
    -- Add additional user input if provided
    if data.additional_input and data.additional_input ~= "" then
        table.insert(parts, "")
        table.insert(parts, "[Additional user input]")
        table.insert(parts, data.additional_input)
    end
    
    return table.concat(parts, "\n")
end

local function handlePredefinedPrompt(prompt_type, highlightedText, ui, configuration, existing_history, plugin, additional_input)
    -- Use passed configuration or fall back to global
    local config = configuration or CONFIGURATION
    
    -- Get the prompts based on context
    local prompts, _ = getAllPrompts(config, plugin)
    
    -- Get prompt configuration
    local prompt = prompts[prompt_type]
    if not prompt then
        return nil, "Prompt '" .. prompt_type .. "' not found"
    end

    -- Create a temporary configuration using the passed config as base
    local temp_config = createTempConfig(prompt, config)
    if prompt.provider then
        if not temp_config.provider_settings[prompt.provider] then
            temp_config.provider_settings[prompt.provider] = {}
        end
        temp_config.provider_settings[prompt.provider].model = prompt.model
        temp_config.default_provider = prompt.provider
    end
    
    -- Determine system prompt based on context
    local system_prompt = prompt.system_prompt
    if not system_prompt and plugin and plugin.prompt_service then
        local context = getPromptContext(config)
        system_prompt = plugin.prompt_service:getSystemPrompt(context)
    end
    -- Use centralized default system prompt if none provided
    system_prompt = system_prompt or plugin.prompt_service:getSystemPrompt(nil, "default")
    
    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
    -- Pass prompt text for better chat naming
    local history = MessageHistory:new(nil, prompt.text)
    
    -- Determine context
    local context = getPromptContext(config)
    
    -- Build data for consolidated message
    local message_data = {
        highlighted_text = highlightedText,
        additional_input = additional_input,
        book_metadata = config.features.book_metadata,
        books_info = config.features.books_info,
        book_context = config.features.book_context
    }
    
    -- Add book info for highlight context if needed
    if context == "highlight" and prompt.include_book_context and ui and ui.document then
        message_data.book_title = ui.document:getProps().title
        message_data.book_author = ui.document:getProps().authors
    end
    
    -- Build and add the consolidated message (now including system prompt)
    local consolidated_message = buildConsolidatedMessage(prompt, context, message_data, system_prompt)
    history:addUserMessage(consolidated_message, true)
    
    -- Get response from AI
    local answer = queryChatGPT(history:getMessages(), temp_config)
    if answer then
        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config))
    end
    
    return history, temp_config
end

local function showChatGPTDialog(ui_instance, highlighted_text, config, prompt_type, plugin, book_metadata)
    -- Use the passed configuration or fall back to the global CONFIGURATION
    local configuration = config or CONFIGURATION
    
    -- Log which provider we're using
    local logger = require("logger")
    logger.info("Using AI provider: " .. (configuration.provider or "anthropic"))
    
    -- Log configuration structure
    if configuration and configuration.features then
        logger.info("Configuration has features")
        if configuration.features.prompts then
            local count = 0
            for k, v in pairs(configuration.features.prompts) do
                count = count + 1
                logger.info("  Found configured prompt: " .. k)
            end
            logger.info("Total configured prompts: " .. count)
        else
            logger.warn("No prompts in configuration.features")
        end
    else
        logger.warn("Configuration missing or no features")
    end
    
    local title = ui_instance and ui_instance.document and ui_instance.document:getProps().title or _("Unknown Title")
    local author = ui_instance and ui_instance.document and ui_instance.document:getProps().authors or _("Unknown Author")
    local document_path = ui_instance and ui_instance.document and ui_instance.document.file or nil
    
    -- Create book metadata object
    -- Check both document context and file browser context for metadata
    local book_metadata = nil
    if document_path then
        -- Document is open, use its metadata
        book_metadata = {
            title = title,
            author = author
        }
        logger.info("Assistant: Document context - title: " .. title .. ", author: " .. author)
    elseif configuration and configuration.features and configuration.features.book_metadata then
        -- File browser context, use metadata from configuration
        book_metadata = {
            title = configuration.features.book_metadata.title,
            author = configuration.features.book_metadata.author
        }
        -- For file browser context, get the document path from configuration
        if configuration.features.book_metadata.file then
            document_path = configuration.features.book_metadata.file
        end
        logger.info("Assistant: File browser context - title: " .. (book_metadata.title or "nil") .. ", author: " .. (book_metadata.author or "nil"))
    else
        logger.info("Assistant: No metadata available in either context")
    end

    -- Collect all buttons in priority order
    local all_buttons = {
        -- 1. Cancel
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(input_dialog)
            end
        },
        -- 2. Ask
        {
            text = _("Ask"),
            callback = function()
                UIManager:close(input_dialog)
                showLoadingDialog()
                UIManager:scheduleIn(0.1, function()
                    -- Determine system prompt based on context
                    local system_prompt = configuration.features.system_prompt
                    if not system_prompt then
                        -- Get the current context
                        local context = getPromptContext(configuration)
                        -- Use context-specific fallback system prompt
                        system_prompt = plugin.prompt_service:getSystemPrompt(context)
                    end
                    
                    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
                    local history = MessageHistory:new(nil, "Ask")
                    
                    -- Build consolidated message parts
                    local parts = {}
                    
                    -- Add system prompt
                    if system_prompt then
                        table.insert(parts, "")  -- Add line break before [Instructions]
                        table.insert(parts, "[Instructions]")
                        table.insert(parts, system_prompt)
                        table.insert(parts, "")
                    end
                    
                    -- Add appropriate context
                    if configuration.features.is_file_browser_context then
                        -- For file browser, highlighted_text contains the book metadata
                        table.insert(parts, "[Context]")
                        table.insert(parts, highlighted_text)
                        table.insert(parts, "")
                    elseif configuration.features.is_general_context then
                        -- For general context, no initial context needed
                        -- User will provide their question/prompt
                    elseif highlighted_text then
                        -- For highlighted text context
                        table.insert(parts, "[Context]")
                        if title and author then
                            table.insert(parts, string.format('From "%s" by %s', title, author))
                            table.insert(parts, "")
                            table.insert(parts, "Highlighted text:")
                            table.insert(parts, '"' .. highlighted_text .. '"')
                        else
                            table.insert(parts, "Highlighted text:")
                            table.insert(parts, '"' .. highlighted_text .. '"')
                        end
                        table.insert(parts, "")
                    end
                    
                    -- Add user question
                    local question = input_dialog:getInputText()
                    if question and question ~= "" then
                        table.insert(parts, "[User Question]")
                        table.insert(parts, question)
                    else
                        -- Default prompt if no question provided
                        table.insert(parts, "[User Question]")
                        table.insert(parts, "I have a question for you.")
                    end
                    
                    -- Create the consolidated message
                    local consolidated_message = table.concat(parts, "\n")
                    history:addUserMessage(consolidated_message, true)
                    
                    -- Get initial response
                    local answer = queryChatGPT(history:getMessages(), configuration)
                    if answer then
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration))
                    end
                    
                    local function addMessage(message, is_context)
                        history:addUserMessage(message, is_context)
                        local answer = queryChatGPT(history:getMessages(), configuration)
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration))
                        return answer
                    end
                    
                    showResponseDialog(_("Chat"), history, highlighted_text, addMessage, configuration, document_path, plugin, book_metadata)
                end)
            end
        }
    }

    -- 3. Translate (only for highlighted text context, not file browser or general)
    local translation_language = configuration.features.translation_language or configuration.features.translate_to or "English"
    if translation_language and not configuration.features.is_file_browser_context 
       and not configuration.features.is_general_context and highlighted_text then
        table.insert(all_buttons, {
            text = _("Translate"),
            prompt_type = "translate",
            callback = function()
                local additional_input = input_dialog:getInputText()
                UIManager:close(input_dialog)
                showLoadingDialog()
                UIManager:scheduleIn(0.1, function()
                    -- Use centralized translation system prompt
                    local translation_prompt = plugin.prompt_service:getSystemPrompt("translation", "translation")
                    
                    -- Create history WITHOUT system prompt (we'll include it in the consolidated message)
                    local history = MessageHistory:new(nil, "Translate")
                    
                    -- Build consolidated message parts
                    local parts = {}
                    
                    -- Add system prompt
                    if translation_prompt then
                        table.insert(parts, "")  -- Add line break before [Instructions]
                        table.insert(parts, "[Instructions]")
                        table.insert(parts, translation_prompt)
                        table.insert(parts, "")
                    end
                    
                    -- Add translation request
                    table.insert(parts, "[Request]")
                    -- Use centralized translation template
                    local translate_template = plugin.prompt_service:getActionTemplate("translate")
                    if translate_template then
                        local request = translate_template:gsub("{language}", translation_language):gsub("{text}", highlighted_text)
                        table.insert(parts, request)
                    else
                        -- Fallback
                        table.insert(parts, "Translate the following text to " .. translation_language .. ": " .. highlighted_text)
                    end
                    
                    -- Add additional user input if provided
                    if additional_input and additional_input ~= "" then
                        table.insert(parts, "")
                        table.insert(parts, "[Additional user input]")
                        table.insert(parts, additional_input)
                    end
                    
                    -- Create the consolidated message
                    local consolidated_message = table.concat(parts, "\n")
                    history:addUserMessage(consolidated_message, true)
                    
                    -- Get initial response
                    local answer = queryChatGPT(history:getMessages(), configuration)
                    if answer then
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration))
                    end
                    
                    local function addMessage(message, is_context)
                        history:addUserMessage(message, is_context)
                        local answer = queryChatGPT(history:getMessages(), configuration)
                        history:addAssistantMessage(answer, ConfigHelper:getModelInfo(configuration))
                        return answer
                    end
                    
                    showResponseDialog(_("Translation"), history, highlighted_text, addMessage, configuration, document_path, plugin, book_metadata)
                end)
            end
        })
    end

    -- 4. Custom prompts
    local prompts, prompt_keys = getAllPrompts(configuration, plugin)
    logger.info("showChatGPTDialog: Got " .. #prompt_keys .. " custom prompts")
    for _, prompt_type in ipairs(prompt_keys) do
        local prompt = prompts[prompt_type]
        if prompt and prompt.text then
            logger.info("Adding button for prompt: " .. prompt_type .. " with text: " .. prompt.text)
            table.insert(all_buttons, {
                text = gettext(prompt.text),
            prompt_type = prompt_type,
            callback = function()
                local additional_input = input_dialog:getInputText()
                UIManager:close(input_dialog)
                showLoadingDialog()
                UIManager:scheduleIn(0.1, function()
                    local history, temp_config = handlePredefinedPrompt(prompt_type, highlighted_text, ui_instance, configuration, nil, plugin, additional_input)
                    if history then
                        local function addMessage(message, is_context)
                            history:addUserMessage(message, is_context)
                            local answer = queryChatGPT(history:getMessages(), temp_config)
                            history:addAssistantMessage(answer, ConfigHelper:getModelInfo(temp_config))
                            return answer
                        end
                        showResponseDialog(gettext(prompt.text), history, highlighted_text, addMessage, temp_config, document_path, plugin, book_metadata)
                    else
                        UIManager:show(InfoMessage:new{
                            text = gettext("Error handling prompt: " .. prompt_type),
                            timeout = 2
                        })
                    end
                end)
            end
        })
        else
            logger.warn("Skipping prompt " .. prompt_type .. " - missing or invalid")
        end
    end

    -- Organize buttons into rows of three
    local button_rows = {}
    local current_row = {}
    for _, button in ipairs(all_buttons) do
        table.insert(current_row, button)
        if #current_row == 3 then
            table.insert(button_rows, current_row)
            current_row = {}
        end
    end
    
    -- Add any remaining buttons as the last row
    if #current_row > 0 then
        table.insert(button_rows, current_row)
    end

    -- Show the dialog with the button rows
    input_dialog = InputDialog:new{
        title = _("Assistant Actions"),
        input_hint = _("Type your question or additional instructions for any action..."),
        input_type = "text",
        buttons = button_rows,
        input_height = 6,
        allow_newline = true,
        input_multiline = true,
        text_height = 300,
    }
    
    -- If a prompt_type is specified, automatically trigger it after dialog is shown
    if prompt_type then
        UIManager:show(input_dialog)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(input_dialog)
            
            -- Find and trigger the corresponding button
            for _, row in ipairs(button_rows) do
                for _, button in ipairs(row) do
                    if button.prompt_type == prompt_type then
                        button.callback()
                        return
                    end
                end
            end
            
            -- If no matching prompt found, just close
            UIManager:show(InfoMessage:new{
                text = _("Unknown prompt type: ") .. tostring(prompt_type),
                timeout = 2
            })
        end)
    else
        UIManager:show(input_dialog)
    end
end

return showChatGPTDialog