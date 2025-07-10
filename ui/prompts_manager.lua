local _ = require("gettext")
local logger = require("logger")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonTable = require("ui/widget/buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Font = require("ui/font")
local Screen = require("device").screen
local util = require("util")
local TextViewer = require("ui/widget/textviewer")

local PromptsManager = {}

function PromptsManager:new(plugin)
    local o = {
        plugin = plugin,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function PromptsManager:show()
    self:loadPrompts()
    self:showPromptsMenu()
end

function PromptsManager:loadPrompts()
    self.prompts = {}
    
    if not self.plugin.prompt_service then
        logger.warn("PromptsManager: PromptService not available")
        return
    end
    
    -- Load all prompts from all contexts
    local highlight_prompts = self.plugin.prompt_service:getAllPrompts("highlight", true)
    local book_prompts = self.plugin.prompt_service:getAllPrompts("book", true)
    local multi_book_prompts = self.plugin.prompt_service:getAllPrompts("multi_book", true)
    local general_prompts = self.plugin.prompt_service:getAllPrompts("general", true)
    
    -- Add highlight prompts
    for _, prompt in ipairs(highlight_prompts) do
        table.insert(self.prompts, {
            text = prompt.text,
            system_prompt = prompt.system_prompt,
            user_prompt = prompt.user_prompt,
            context = "highlight",
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
        })
    end
    
    -- Add book prompts (avoid duplicates for "both" context)
    for _, prompt in ipairs(book_prompts) do
        -- Check if this prompt already exists in highlight context
        local exists = false
        for _, existing in ipairs(self.prompts) do
            if existing.text == prompt.text and existing.source == prompt.source then
                -- Change context to "both"
                existing.context = "both"
                exists = true
                break
            end
        end
        
        if not exists then
            table.insert(self.prompts, {
                text = prompt.text,
                system_prompt = prompt.system_prompt,
                user_prompt = prompt.user_prompt,
                context = "book",
                source = prompt.source,
                enabled = prompt.enabled,
                requires = prompt.requires,
                id = prompt.id,
            })
        end
    end
    
    -- Add multi-book prompts
    for _, prompt in ipairs(multi_book_prompts) do
        table.insert(self.prompts, {
            text = prompt.text,
            system_prompt = prompt.system_prompt,
            user_prompt = prompt.user_prompt,
            context = "multi_book",
            source = prompt.source,
            enabled = prompt.enabled,
            requires = prompt.requires,
            id = prompt.id,
        })
    end
    
    -- Add general prompts
    for _, prompt in ipairs(general_prompts) do
        -- Check if this prompt already exists in other contexts
        local exists = false
        for _, existing in ipairs(self.prompts) do
            if existing.text == prompt.text and existing.source == prompt.source then
                -- Update context to include general
                if existing.context == "highlight" then
                    existing.context = "highlight+general"
                elseif existing.context == "file_browser" then
                    existing.context = "file_browser+general"
                elseif existing.context == "both" then
                    existing.context = "all"
                end
                exists = true
                break
            end
        end
        
        if not exists then
            table.insert(self.prompts, {
                text = prompt.text,
                system_prompt = prompt.system_prompt,
                user_prompt = prompt.user_prompt,
                context = "general",
                source = prompt.source,
                enabled = prompt.enabled,
                requires = prompt.requires,
                id = prompt.id,
            })
        end
    end
    
    logger.info("PromptsManager: Total prompts loaded: " .. #self.prompts)
end

function PromptsManager:setPromptEnabled(prompt_text, context, enabled)
    if self.plugin.prompt_service then
        self.plugin.prompt_service:setPromptEnabled(context, prompt_text, enabled)
    end
end

function PromptsManager:showPromptsMenu()
    local menu_items = {}
    
    -- Add help text at the top
    table.insert(menu_items, {
        text = _("Tap to toggle • Hold for details"),
        dim = true,
        enabled = false,
    })
    
    -- Add "Add New Prompt" item (grayed out for now)
    table.insert(menu_items, {
        text = _("+ Add New Prompt (planned)"),
        enabled = false,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Add new prompt feature coming soon..."),
            })
        end,
    })
    
    -- No separator needed here
    
    -- Group prompts by context
    local contexts = {
        { id = "highlight", text = _("Highlight Context") },
        { id = "file_browser", text = _("File Browser Context") },
        { id = "multi_file_browser", text = _("Multi-File Browser Context") },
        { id = "general", text = _("General Context") },
        { id = "both", text = _("Highlight & File Browser") },
        { id = "all", text = _("All Contexts") },
    }
    
    for _, context_info in ipairs(contexts) do
        local context_prompts = {}
        for _, prompt in ipairs(self.prompts) do
            if prompt.context == context_info.id then
                table.insert(context_prompts, prompt)
            end
        end
        
        if #context_prompts > 0 then
            -- Add context header with spacing
            -- No empty line needed, the section header provides visual separation
            table.insert(menu_items, {
                text = "▶ " .. context_info.text:upper(),
                enabled = false,
                dim = false,
                bold = true,
            })
            
            -- Add prompts for this context
            for _, prompt in ipairs(context_prompts) do
                local item_text = prompt.text
                
                -- Add source indicator for user prompts
                if prompt.source == "user" then
                    item_text = item_text .. " ✏"
                end
                
                -- Add requires indicator
                if prompt.requires then
                    item_text = item_text .. " [" .. prompt.requires .. "]"
                end
                
                -- Add checkbox with better spacing
                local checkbox = prompt.enabled and "☑" or "☐"
                item_text = checkbox .. "  " .. item_text
                
                table.insert(menu_items, {
                    text = item_text,
                    prompt = prompt,  -- Store reference to prompt
                    callback = function()
                        -- Toggle enabled state
                        self:setPromptEnabled(prompt.text, prompt.context, not prompt.enabled)
                        -- Refresh the menu
                        self:refreshMenu()
                    end,
                    hold_callback = function()
                        -- Show details on hold
                        -- Don't close the menu, just show the details dialog on top
                        self:showPromptDetails(prompt)
                    end,
                })
            end
        end
    end
    
    -- Create footer buttons
    local buttons = {
        {
            {
                text = _("Import"),
                enabled = false,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Import feature coming soon..."),
                    })
                end,
            },
            {
                text = _("Export"),
                enabled = false,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Export feature coming soon..."),
                    })
                end,
            },
            {
                text = _("Restore Defaults"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("This will remove all custom prompts and reset all prompt settings. Continue?"),
                        ok_callback = function()
                            UIManager:close(self.prompts_menu)
                            if self.plugin.restoreDefaultPrompts then
                                self.plugin:restoreDefaultPrompts()
                            end
                            -- Refresh the menu
                            UIManager:scheduleIn(0.1, function()
                                self:show()
                            end)
                        end,
                    })
                end,
            },
        },
    }
    
    self.prompts_menu = Menu:new{
        title = _("Manage Prompts"),
        item_table = menu_items,
        onMenuSelect = function(_, item)
            if item and item.callback then
                item.callback()
            end
        end,
        onMenuHold = function(_, item)
            if item and item.hold_callback then
                item.hold_callback()
            end
        end,
        close_callback = function()
            UIManager:close(self.prompts_menu)
        end,
        buttons_table = buttons,
    }
    
    UIManager:show(self.prompts_menu)
end

function PromptsManager:refreshMenu()
    -- Close and reopen the menu to refresh it
    if self.prompts_menu then
        local menu = self.prompts_menu
        UIManager:close(menu)
        -- Schedule reopening after close
        UIManager:scheduleIn(0.1, function()
            self:show()
        end)
    end
end

function PromptsManager:showPromptDetails(prompt)
    local source_text
    if prompt.source == "builtin" then
        source_text = _("Built-in")
    elseif prompt.source == "config" then
        source_text = _("Custom (custom_prompts.lua)")
    elseif prompt.source == "ui" then
        source_text = _("User-defined (UI)")
    else
        source_text = prompt.source or _("Unknown")
    end
    
    local info_text = string.format(
        "%s\n\n%s: %s\n%s: %s\n%s: %s\n\n%s:\n%s\n\n%s:\n%s",
        prompt.text,
        _("Context"), self:getContextDisplayName(prompt.context),
        _("Source"), source_text,
        _("Status"), prompt.enabled and _("Enabled") or _("Disabled"),
        _("System Prompt"),
        prompt.system_prompt or _("(None)"),
        _("User Prompt"),
        prompt.user_prompt or _("(None)")
    )
    
    if prompt.requires then
        info_text = info_text .. "\n\n" .. _("Requires") .. ": " .. prompt.requires
    end
    
    local buttons = {}
    
    -- Edit button (only for user-created prompts, not built-in ones)
    if prompt.source == "ui" or prompt.source == "config" then
        table.insert(buttons, {
            text = _("Edit"),
            callback = function()
                self:showPromptEditor(prompt)
            end,
        })
        -- Only allow deletion of UI-created prompts (not custom_prompts.lua)
        if prompt.source == "ui" then
            table.insert(buttons, {
                text = _("Delete"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this prompt?"),
                        ok_callback = function()
                            self:deletePrompt(prompt)
                            -- Close and refresh the prompts menu
                            if self.prompts_menu then
                                UIManager:close(self.prompts_menu)
                            end
                            self:show() -- Refresh the list
                        end,
                    })
                end,
            })
        end
    end
    
    UIManager:show(TextViewer:new{
        title = _("Prompt Details"),
        text = info_text,
        buttons_table = buttons,
        width = self.width * 0.9,
        height = self.height * 0.8,
    })
end

function PromptsManager:showPromptEditor(existing_prompt)
    local is_edit = existing_prompt ~= nil
    
    local dialog = MultiInputDialog:new{
        title = is_edit and _("Edit Prompt") or _("Add New Prompt"),
        fields = {
            {
                text = existing_prompt and existing_prompt.text or "",
                hint = _("Prompt name (e.g., 'Summarize')"),
            },
            {
                text = existing_prompt and existing_prompt.system_prompt or "",
                hint = _("System prompt (AI behavior instructions)"),
                height = 100,
            },
            {
                text = existing_prompt and existing_prompt.user_prompt or "",
                hint = _("User prompt template (use {highlighted_text}, {title}, {author})"),
                height = 100,
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        -- Don't reopen menu on cancel
                    end,
                },
                {
                    text = _("Context"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showContextSelector(dialog, existing_prompt)
                    end,
                },
                {
                    text = is_edit and _("Save") or _("Add"),
                    callback = function()
                        local name = dialog.fields[1].text
                        local system_prompt = dialog.fields[2].text
                        local user_prompt = dialog.fields[3].text
                        
                        if name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Prompt name cannot be empty"),
                            })
                            return
                        end
                        
                        if user_prompt == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("User prompt cannot be empty"),
                            })
                            return
                        end
                        
                        local context = dialog.context or (existing_prompt and existing_prompt.context) or "both"
                        
                        if is_edit then
                            self:updatePrompt(existing_prompt, name, system_prompt, user_prompt, context)
                        else
                            self:addPrompt(name, system_prompt, user_prompt, context)
                        end
                        
                        UIManager:close(dialog)
                        -- Close and refresh the prompts menu
                        if self.prompts_menu then
                            UIManager:close(self.prompts_menu)
                        end
                        self:show()
                    end,
                },
            },
        },
    }
    
    dialog.context = existing_prompt and existing_prompt.context or "both"
    
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PromptsManager:showContextSelector(parent_dialog, existing_prompt)
    local context_options = {
        { value = "highlight", text = _("Highlight Context Only") },
        { value = "book", text = _("Book Context Only") },
        { value = "multi_book", text = _("Multi-Book Context Only") },
        { value = "general", text = _("General Context Only") },
        { value = "both", text = _("Highlight & Book") },
        { value = "all", text = _("All Contexts") },
    }
    
    local radio_buttons = {}
    for _, option in ipairs(context_options) do
        table.insert(radio_buttons, {
            {
                text = option.text,
                checked_func = function()
                    return parent_dialog.context == option.value
                end,
                callback = function()
                    parent_dialog.context = option.value
                    UIManager:close(self.context_dialog)
                    UIManager:show(parent_dialog)
                end,
            },
        })
    end
    
    self.context_dialog = FrameContainer:new{
        background = 0,
        bordersize = 2,
        padding = 10,
        VerticalGroup:new{
            align = "left",
            ButtonTable:new{
                title = _("Select Context"),
                buttons = radio_buttons,
            },
        },
    }
    
    UIManager:show(self.context_dialog)
end

function PromptsManager:addPrompt(name, system_prompt, user_prompt, context)
    if self.plugin.prompt_service then
        self.plugin.prompt_service:addUserPrompt({
            text = name,
            system_prompt = system_prompt,
            user_prompt = user_prompt,
            context = context,
            enabled = true,
        })
        
        UIManager:show(InfoMessage:new{
            text = _("Prompt added successfully"),
        })
    end
end

function PromptsManager:updatePrompt(existing_prompt, name, system_prompt, user_prompt, context)
    if self.plugin.prompt_service then
        if existing_prompt.source == "ui" then
            -- Find the index of this prompt in custom_prompts
            local custom_prompts = self.plugin.settings:readSetting("custom_prompts") or {}
            
            for i, prompt in ipairs(custom_prompts) do
                if prompt.text == existing_prompt.text then
                    self.plugin.prompt_service:updateUserPrompt(i, {
                        text = name,
                        system_prompt = system_prompt,
                        user_prompt = user_prompt,
                        context = context,
                        enabled = existing_prompt.enabled,
                    })
                    
                    UIManager:show(InfoMessage:new{
                        text = _("Prompt updated successfully"),
                    })
                    break
                end
            end
        elseif existing_prompt.source == "config" then
            -- Prompts from custom_prompts.lua cannot be edited via UI
            UIManager:show(InfoMessage:new{
                text = _("This prompt is defined in custom_prompts.lua.\nPlease edit that file directly to modify it."),
            })
        end
    end
end

function PromptsManager:deletePrompt(prompt)
    if self.plugin.prompt_service and prompt.source == "ui" then
        -- Find the index of this prompt in custom_prompts
        local custom_prompts = self.plugin.settings:readSetting("custom_prompts") or {}
        
        for i = #custom_prompts, 1, -1 do
            if custom_prompts[i].text == prompt.text then
                self.plugin.prompt_service:deleteUserPrompt(i)
                
                UIManager:show(InfoMessage:new{
                    text = _("Prompt deleted successfully"),
                })
                break
            end
        end
    end
end

function PromptsManager:getContextDisplayName(context)
    if context == "highlight" then
        return _("Highlight")
    elseif context == "book" then
        return _("Book")
    elseif context == "multi_book" then
        return _("Multi-Book")
    elseif context == "general" then
        return _("General")
    elseif context == "both" then
        return _("Highlight & Book")
    elseif context == "all" then
        return _("All Contexts")
    else
        return context
    end
end

return PromptsManager