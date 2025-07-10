local Device = require("device")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen
local _ = require("gettext")
local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local MessageHistory = require("message_history")
local queryChatGPT = require("gpt_query")
local logger = require("logger")

-- Helper function to safely concatenate strings with translations
local function T(text)
    return _(text)
end

local ChatHistoryDialog = {}


function ChatHistoryDialog:showChatListMenuOptions(ui, document, chat_history_manager, config)
    local buttons = {
        {
            {
                text = T("Delete all chats for this book"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T("Delete all chats for") .. " \"" .. document.title .. "\"?\n\n" .. T("This action cannot be undone."),
                        ok_text = T("Delete"),
                        ok_callback = function()
                            -- TODO: Implement delete all chats for document
                            UIManager:show(InfoMessage:new{
                                text = T("Delete all for book not yet implemented"),
                                timeout = 2,
                            })
                        end,
                    })
                end,
            },
        },
        {
            {
                text = T("Close"),
                callback = function()
                    local dialog = UIManager.current_dialog
                    if dialog then
                        UIManager:close(dialog)
                    end
                end,
            },
        },
    }
    
    local dialog = ButtonDialog:new{
        title = document.title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ChatHistoryDialog:showDocumentMenuOptions(ui, chat_history_manager, config)
    local buttons = {
        {
            {
                text = T("Delete all chats"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T("Delete all saved chats?\n\nThis action cannot be undone."),
                        ok_text = T("Delete"),
                        ok_callback = function()
                            -- TODO: Implement delete all functionality
                            UIManager:show(InfoMessage:new{
                                text = T("Delete all not yet implemented"),
                                timeout = 2,
                            })
                        end,
                    })
                end,
            },
        },
        {
            {
                text = T("Close"),
                callback = function()
                    local dialog = UIManager.current_dialog
                    if dialog then
                        UIManager:close(dialog)
                    end
                end,
            },
        },
    }
    
    local dialog = ButtonDialog:new{
        title = T("Chat History Options"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ChatHistoryDialog:showChatHistoryBrowser(ui, current_document_path, chat_history_manager, config, nav_context)
    -- Initialize navigation context if not provided
    nav_context = nav_context or {
        level = "documents",  -- documents, chats, options
        came_from_document = current_document_path ~= nil,
        initial_document = current_document_path
    }
    
    -- Get all documents that have chats
    local documents = chat_history_manager:getAllDocuments()
    
    if #documents == 0 then
        UIManager:show(InfoMessage:new{
            text = T("No saved chats found"),
            timeout = 2,
        })
        return
    end
    
    -- Check if we should directly show chats for the current document
    if current_document_path then
        for _, doc in ipairs(documents) do
            if doc.path == current_document_path then
                -- We found the current document, show its chats directly
                self:showChatsForDocument(ui, doc, chat_history_manager, config, nav_context)
                return
            end
        end
    end
    
    -- Create the document selection menu first (so we can reference it in callbacks)
    local document_menu
    
    -- Create menu items for each document
    local menu_items = {}
    
    logger.info("Chat history: Creating menu items for " .. #documents .. " documents")
    
    for _, doc in ipairs(documents) do
        logger.info("Chat history: Document - title: " .. (doc.title or "nil") .. ", author: " .. (doc.author or "nil") .. ", path: " .. (doc.path or "nil"))
        -- Get chats for this document to count them
        local chats = chat_history_manager:getChatsForDocument(doc.path)
        local chat_count = #chats
        
        -- Find the most recent chat timestamp
        local latest_timestamp = 0
        for _, chat in ipairs(chats) do
            if chat.timestamp and chat.timestamp > latest_timestamp then
                latest_timestamp = chat.timestamp
            end
        end
        
        -- Format date string manually
        local date_str = ""
        if latest_timestamp > 0 then
            date_str = os.date("%Y-%m-%d", latest_timestamp)
        else
            date_str = T("Unknown")
        end
        
        -- Format display text for better appearance
        local display_text = doc.title
        if doc.author and doc.author ~= "" then
            -- Add author on same line with separator
            display_text = display_text .. " • " .. doc.author
        end
        
        -- Format right text
        local right_text = tostring(chat_count) .. " " .. (chat_count == 1 and T("chat") or T("chats")) .. " • " .. date_str
        
        -- Create menu item
        table.insert(menu_items, {
            text = display_text,
            mandatory = right_text,
            mandatory_dim = true,
            bold = true,
            help_text = doc.path == "__GENERAL_CHATS__" and T("AI conversations without book context") or doc.path,
            callback = function()
                logger.info("Direct document callback for: " .. doc.title)
                -- Use the menu's onClose method to properly clean up
                document_menu:onClose()
                -- Then show the chat list
                self:showChatsForDocument(ui, doc, chat_history_manager, config, nav_context)
            end
        })
    end
    
    -- Now create the menu
    document_menu = Menu:new{
        title = T("Chat History"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",
        multilines_show_more_text = true,  -- Enable multi-line display
        items_max_lines = 2,               -- Allow up to 2 lines per item
        single_line = false,               -- Force multi-line mode
        multilines_forced = true,          -- Force TextBoxWidget for multi-line
        items_font_size = 18,              -- Main font size
        items_mandatory_font_size = 14,    -- Smaller font for metadata on right
        onLeftButtonTap = function()
            -- Show menu with options
            self:showDocumentMenuOptions(ui, chat_history_manager, config)
        end,
    }
    
    -- Let the Menu widget handle its own close_callback
    
    UIManager:show(document_menu)
end

function ChatHistoryDialog:showChatsForDocument(ui, document, chat_history_manager, config, nav_context)
    -- Update navigation context
    nav_context = nav_context or {}
    nav_context.level = "chats"
    nav_context.current_document = document
    
    -- Load all chats for this document
    local chats = chat_history_manager:getChatsForDocument(document.path)
    
    if #chats == 0 then
        UIManager:show(InfoMessage:new{
            text = T("No saved chats found for this document"),
            timeout = 2,
        })
        return
    end
    
    -- Create menu items for each chat
    local menu_items = {}
    -- logger already imported at top of file
    
    -- Store the original chat objects directly in the menu items WITH DIRECT CALLBACKS
    for i, chat in ipairs(chats) do
        -- Log each chat's ID to help with debugging
        logger.info("Chat " .. i .. " ID: " .. (chat.id or "unknown") .. " - " .. (chat.title or "Untitled"))
        
        local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
        local title = chat.title or "Untitled"
        local model = chat.model or "Unknown"
        local msg_count = #(chat.messages or {})
        
        -- Get first few words of first message for preview
        local preview = ""
        for _, msg in ipairs(chat.messages or {}) do
            if msg.role == "user" and not msg.is_context then
                local content = msg.content or ""
                -- Take first 30 chars
                preview = content:sub(1, 30)
                if #content > 30 then
                    preview = preview .. "..."
                end
                break
            end
        end
        
        -- Create menu item
        table.insert(menu_items, {
            text = title .. " • " .. date_str,
            mandatory = model .. " • " .. msg_count .. " " .. (msg_count == 1 and T("message") or T("messages")),
            mandatory_dim = true,
            bold = true,
            help_text = preview,
            callback = function()
                logger.info("Direct callback for chat: " .. (chat.id or "unknown") .. " - " .. (chat.title or "Untitled"))
                self:showChatOptions(ui, document.path, chat, chat_history_manager, config)
            end
        })
    end
    
    -- Create the menu with a back button to return to document list
    local chat_menu = Menu:new{
        title = T("Chats for:") .. " " .. document.title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        title_bar_left_icon = "appbar.menu",  -- Keep hamburger menu in title bar
        -- CoverBrowser-style display settings
        items_per_page = 8,                    -- Fewer items = larger item height
        multilines_show_more_text = true,      -- Enable multi-line display
        items_max_lines = 2,                   -- Allow up to 2 lines per item
        single_line = false,                   -- Force multi-line mode
        items_font_size = 20,                  -- Larger main font size
        items_mandatory_font_size = 16,        -- Smaller font for metadata on right
        align_baselines = false,               -- Don't try to align baselines
        with_dots = false,                     -- No dots between text and mandatory
        onLeftButtonTap = function()
            -- Show menu with options for this document
            self:showChatListMenuOptions(ui, document, chat_history_manager, config)
        end,
        onReturn = function()
            logger.info("Chat history: Return button pressed in chat list")
            -- Call the menu's close callback which will handle navigation
            chat_menu.close_callback()
        end,
    }
    
    -- Enable the return button at bottom left
    table.insert(chat_menu.paths, true)  -- This enables the return button
    
    -- Set up close callback to handle navigation
    chat_menu.close_callback = function()
        logger.info("Chat menu close callback - navigating back to document list")
        UIManager:close(chat_menu)
        -- Show the document browser
        self:showChatHistoryBrowser(ui, nil, chat_history_manager, config, nav_context)
    end

    UIManager:show(chat_menu)
end

function ChatHistoryDialog:showChatOptions(ui, document_path, chat, chat_history_manager, config)
    if not chat then
        UIManager:show(InfoMessage:new{
            text = T("Error: Cannot load chat data."),
            timeout = 2,
        })
        return
    end
    
    -- Format date for display
    local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
    local model = chat.model or "Unknown"
    local msg_count = #(chat.messages or {})
    
    -- Create a more detailed title with chat information
    local detailed_title = (chat.title or T("Untitled Chat")) .. "\n" ..
        T("Date:") .. " " .. date_str .. "\n" ..
        T("Model:") .. " " .. model .. "\n" ..
        T("Messages:") .. " " .. tostring(msg_count)
    
    local buttons = {
        {
            {
                text = T("Continue Chat"),
                callback = function()
                    self:continueChat(ui, document_path, chat, chat_history_manager, config)
                end,
            },
            {
                text = T("Rename"),
                callback = function()
                    self:showRenameDialog(ui, document_path, chat, chat_history_manager, config)
                end,
            },
        },
        {
            {
                text = T("Export"),
                callback = function()
                    self:showExportOptions(document_path, chat.id, chat_history_manager)
                end,
            },
            {
                text = T("Delete"),
                callback = function()
                    self:confirmDelete(document_path, chat.id, chat_history_manager)
                end,
            },
        },
        {
            {
                text = T("Close"),
                callback = function()
                    local dialog = UIManager.current_dialog
                    if dialog then
                        UIManager:close(dialog)
                    end
                end,
            },
        },
    }
    
    local chat_options_dialog = ButtonDialog:new{
        title = detailed_title,
        buttons = buttons,
    }
    
    -- Update the close button callback to use the local reference
    chat_options_dialog.buttons[3][1].callback = function()
        UIManager:close(chat_options_dialog)
    end
    
    UIManager:show(chat_options_dialog)
end

function ChatHistoryDialog:showRenameDialog(ui, document_path, chat, chat_history_manager, config)
    -- T is already defined at the top of file
    
    -- Create a dialog with the current title pre-filled
    local rename_dialog
    rename_dialog = InputDialog:new{
        title = T("Rename Chat"),
        input = chat.title or T("Untitled Chat"),
        buttons = {
            {
                {
                    text = T("Cancel"),
                    callback = function()
                        UIManager:close(rename_dialog)
                    end,
                },
                {
                    text = T("Rename"),
                    callback = function()
                        -- Get the new title
                        local new_title = rename_dialog:getInputText()
                        
                        -- Close the dialog first
                        UIManager:close(rename_dialog)
                        
                        -- Rename the chat
                        local success = chat_history_manager:renameChat(document_path, chat.id, new_title)
                        
                        if success then
                            UIManager:show(InfoMessage:new{
                                text = T("Chat renamed successfully"),
                                timeout = 2,
                            })
                            
                            -- Refresh the chat list to show the new name
                            self:showChatsForDocument(ui, {path = document_path, title = document_path:match("([^/]+)$") or document_path}, chat_history_manager, config)
                        else
                            UIManager:show(InfoMessage:new{
                                text = T("Failed to rename chat"),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    
    UIManager:show(rename_dialog)
end

function ChatHistoryDialog:continueChat(ui, document_path, chat, chat_history_manager, config)
    if not chat then
        UIManager:show(InfoMessage:new{
            text = T("Error: Cannot load chat data."),
            timeout = 2,
        })
        return
    end
    
    -- Ensure config has proper structure
    if not config then
        config = {}
    end
    if not config.features then
        config.features = {}
    end

    -- Create a message history from the saved chat
    local history
    local ok, err = pcall(function()
        history = MessageHistory:fromSavedMessages(chat.messages, chat.model, chat.id, chat.prompt_action)
    end)
    
    if not ok or not history then
        local logger = require("logger")
        logger.warn("Failed to load message history: " .. (err or "unknown error"))
        UIManager:show(InfoMessage:new{
            text = T("Error: Failed to load chat messages."),
            timeout = 2,
        })
        return
    end
    
    -- Function to add new messages
    local function addMessage(message, is_context)
        if not message or message == "" then return nil end
        
        history:addUserMessage(message, is_context)
        local answer = queryChatGPT(history:getMessages(), config)
        history:addAssistantMessage(answer, history:getModel() or config and config.model)
        
        -- Save updated chat if auto-save is enabled (either auto-save all or auto-save continued)
        if config.features.auto_save_all_chats or (config.features.auto_save_chats ~= false) then
            local save_ok = chat_history_manager:saveChat(document_path, chat.title, history, {id = chat.id})
            if not save_ok then
                local logger = require("logger")
                logger.warn("Failed to save updated chat")
            end
        end
        
        return answer
    end
    
    -- Function to update viewer title when chat is modified (like after renaming)
    local function updateViewerTitle(viewer)
        -- Reload the chat to get the latest title
        local updated_chat = chat_history_manager:getChatById(document_path, chat.id)
        if updated_chat then
            -- Format date information
            local date_str = os.date("%Y-%m-%d %H:%M", updated_chat.timestamp or 0)
            local msg_count = #(updated_chat.messages or {})
            local model = updated_chat.model or "AI"
            
            -- Create a more detailed title for the chat viewer
            local detailed_title = (updated_chat.title or T("Untitled")) .. " • " .. 
                              date_str .. " • " .. 
                              model .. " • " ..
                              tostring(msg_count) .. " " .. T("msgs")
            
            viewer:setTitle(detailed_title)
        end
    end
    
    -- Format date information
    local date_str = os.date("%Y-%m-%d %H:%M", chat.timestamp or 0)
    local msg_count = #(chat.messages or {})
    local model = chat.model or "AI"
    
    -- Create a more detailed title for the chat viewer
    local detailed_title = (chat.title or T("Untitled")) .. " • " .. 
                          date_str .. " • " .. 
                          model .. " • " ..
                          tostring(msg_count) .. " " .. T("msgs")
    
    -- Show loading dialog function
    local function showLoadingDialog()
        local InfoMessage = require("ui/widget/infomessage")
        local loading = InfoMessage:new{
            text = T("Loading..."),
            timeout = 0.1
        }
        UIManager:show(loading)
    end
    
    -- Keep track of the current viewer globally
    -- This will help ensure we never have multiple viewers open
    if not ChatHistoryDialog.current_chat_viewer then
        ChatHistoryDialog.current_chat_viewer = nil
    end
    
    -- Close any existing chat viewer
    if ChatHistoryDialog.current_chat_viewer then
        UIManager:close(ChatHistoryDialog.current_chat_viewer)
        ChatHistoryDialog.current_chat_viewer = nil
    end
    
    -- Create a new function to show the chat content in a fresh viewer
    local function showChatViewer(content_text)
        -- Always close existing viewer if any
        if ChatHistoryDialog.current_chat_viewer then
            UIManager:close(ChatHistoryDialog.current_chat_viewer)
            ChatHistoryDialog.current_chat_viewer = nil
        end
        
        -- Create a fresh viewer
        local viewer = ChatGPTViewer:new{
            title = detailed_title,
            text = content_text or history:createResultText("", config),
            configuration = config,  -- Pass configuration for debug mode and other settings
            original_history = history,  -- Needed for debug toggle to regenerate text
            original_highlighted_text = "",  -- No highlighted text in continued chats
            settings_callback = function(path, value)
                -- Update plugin settings if we have access to the plugin
                local plugin = ui and ui.assistant
                if not plugin then
                    -- Try to find the assistant plugin from UIManager
                    local top_widget = UIManager:getTopmostVisibleWidget()
                    if top_widget and top_widget.ui and top_widget.ui.assistant then
                        plugin = top_widget.ui.assistant
                    end
                end
                
                if plugin and plugin.settings then
                    local parts = {}
                    for part in path:gmatch("[^.]+") do
                        table.insert(parts, part)
                    end
                    
                    if #parts == 1 then
                        plugin.settings:saveSetting(parts[1], value)
                    elseif #parts == 2 then
                        local group = plugin.settings:readSetting(parts[1]) or {}
                        group[parts[2]] = value
                        plugin.settings:saveSetting(parts[1], group)
                    end
                    plugin.settings:flush()
                    
                    -- Also update the config object for this session
                    if config and config.features and parts[1] == "features" and parts[2] == "debug" then
                        config.features.debug = value
                    end
                end
            end,
            update_debug_callback = function(debug_mode)
                -- Update debug mode in history if available
                if history and history.debug_mode ~= nil then
                    history.debug_mode = debug_mode
                end
            end,
            onAskQuestion = function(_, question)
                -- Show loading indicator
                showLoadingDialog()
                
                -- Process the question in a scheduled task
                UIManager:scheduleIn(0.1, function()
                    -- Add the message and get response
                    local answer = addMessage(question)
                    
                    -- Update by creating a new viewer with fresh content
                    if answer then
                        -- Create a fresh text with the updated history
                        local new_content = history:createResultText("", config)
                        
                        -- Now show a fresh viewer with the updated content
                        showChatViewer(new_content)
                    else
                        UIManager:show(InfoMessage:new{
                            text = T("Failed to get response. Please try again."),
                            timeout = 2,
                        })
                    end
                end)
            end,
            save_callback = function()
                -- Check if auto-save all is enabled first
                if config.features.auto_save_all_chats then
                    UIManager:show(InfoMessage:new{
                        text = T("Auto-save all chats is on - this can be changed in the settings"),
                        timeout = 3,
                    })
                elseif config.features.auto_save_chats ~= false then  -- Default to true if not set
                    UIManager:show(InfoMessage:new{
                        text = T("Continued chats are automatically saved - this can be changed in the settings"),
                        timeout = 3,
                    })
                else
                    -- Manual save when auto-save is disabled
                    local save_ok = chat_history_manager:saveChat(document_path, chat.title, history, {id = chat.id})
                    if save_ok then
                        UIManager:show(InfoMessage:new{
                            text = T("Chat saved successfully"),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = T("Failed to save chat"),
                            timeout = 2,
                        })
                    end
                end
            end,
            export_callback = function()
                self:showExportOptions(document_path, chat.id, chat_history_manager)
            end,
            update_title_callback = updateViewerTitle,
            close_callback = function()
                -- Clear the global reference when closed
                ChatHistoryDialog.current_chat_viewer = nil
            end
        }
        
        -- Store reference to the new viewer
        ChatHistoryDialog.current_chat_viewer = viewer
        
        -- Show the new viewer
        UIManager:show(viewer)
    end
    
    -- Call function to show the initial viewer
    showChatViewer()
end

function ChatHistoryDialog:showExportOptions(document_path, chat_id, chat_history_manager)
    local buttons = {
        {
            {
                text = T("Copy as Text"),
                callback = function()
                    local text = chat_history_manager:exportChatAsText(document_path, chat_id)
                    if text then
                        Device.input.setClipboardText(text)
                        UIManager:show(InfoMessage:new{
                            text = T("Chat copied to clipboard as text"),
                            timeout = 2,
                        })
                    end
                end,
            },
            {
                text = T("Copy as Markdown"),
                callback = function()
                    local markdown = chat_history_manager:exportChatAsMarkdown(document_path, chat_id)
                    if markdown then
                        Device.input.setClipboardText(markdown)
                        UIManager:show(InfoMessage:new{
                            text = T("Chat copied to clipboard as markdown"),
                            timeout = 2,
                        })
                    end
                end,
            },
        },
        {
            {
                text = T("Close"),
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
        title = T("Export Chat"),
        buttons = buttons,
    }
    
    -- Update the close button callback to use the local reference
    export_dialog.buttons[2][1].callback = function()
        UIManager:close(export_dialog)
    end
    
    UIManager:show(export_dialog)
end

function ChatHistoryDialog:confirmDelete(document_path, chat_id, chat_history_manager)
    UIManager:show(ConfirmBox:new{
        text = T("Are you sure you want to delete this chat?"),
        ok_text = T("Delete"),
        ok_callback = function()
            local success = chat_history_manager:deleteChat(document_path, chat_id)
            if success then
                UIManager:show(InfoMessage:new{
                    text = T("Chat deleted successfully"),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = T("Failed to delete chat"),
                    timeout = 2,
                })
            end
        end,
    })
end

return ChatHistoryDialog 