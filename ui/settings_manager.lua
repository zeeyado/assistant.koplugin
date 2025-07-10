local _ = require("gettext")
local logger = require("logger")

local SettingsManager = {}

-- Generate menu items from settings schema
function SettingsManager:generateMenuFromSchema(plugin, schema)
    local menu_items = {}
    
    for _, category in ipairs(schema.categories) do
        local category_item = {
            text = category.text,
            sub_item_table = {}
        }
        
        for _, item in ipairs(category.items) do
            local menu_item = self:createMenuItem(plugin, item, schema)
            if menu_item then
                table.insert(category_item.sub_item_table, menu_item)
            end
        end
        
        if #category_item.sub_item_table > 0 then
            table.insert(menu_items, category_item)
        end
    end
    
    return menu_items
end

-- Create a single menu item based on its schema definition
function SettingsManager:createMenuItem(plugin, item, schema)
    -- Handle special item types
    if item.type == "separator" then
        return { 
            text = "────────────────────",
            enabled = false,
            callback = function() end,  -- Empty callback to prevent any action
        }
    elseif item.type == "header" then
        return { 
            text = item.text,
            enabled = false,
            bold = true,
            callback = function() end,  -- Empty callback to prevent any action
        }
    end
    
    local menu_item = {
        text = item.text or item.id,
        enabled_func = function()
            -- First check if the item is explicitly disabled
            if item.enabled == false then
                return false
            end
            
            -- Then check dependencies
            if item.depends_on then
                if type(item.depends_on) == "table" then
                    -- Complex dependency
                    -- Need to find the path for the dependency item
                    local dep_path = nil
                    local function findItemPath(categories, id)
                        if not categories then return id end
                        for _, category in ipairs(categories) do
                            if category and category.items then
                                for _, subitem in ipairs(category.items) do
                                    if subitem and subitem.id == id then
                                        return subitem.path or subitem.id
                                    end
                                end
                            end
                        end
                        return id -- fallback to id if path not found
                    end
                    
                    -- Get the schema to find the path
                    local SettingsSchema = require("settings_schema")
                    dep_path = findItemPath(SettingsSchema.categories, item.depends_on.id)
                    
                    local dependency_value = self:getSettingValue(plugin, dep_path)
                    return dependency_value == item.depends_on.value
                else
                    -- Simple dependency - just check if has value
                    local dependency_value = self:getSettingValue(plugin, item.depends_on)
                    return dependency_value ~= nil
                end
            end
            return true
        end,
    }
    
    if item.type == "toggle" then
        menu_item.checked_func = function()
            return self:getSettingValue(plugin, item.path or item.id) == true
        end
        menu_item.callback = function(touchmenu_instance)
            local current = self:getSettingValue(plugin, item.path or item.id)
            self:setSettingValue(plugin, item.path or item.id, not current)
            plugin:updateConfigFromSettings()
            
            -- If this toggle affects dependencies, refresh the menu
            if item.id == "auto_save_all_chats" then
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end
        end
        menu_item.keep_menu_open = true
        
    elseif item.type == "radio" then
        -- Radio buttons need special handling
        menu_item.sub_item_table = {}
        for _, option in ipairs(item.options) do
            table.insert(menu_item.sub_item_table, {
                text = option.text,
                checked_func = function()
                    return self:getSettingValue(plugin, item.id) == option.value
                end,
                callback = function()
                    self:setSettingValue(plugin, item.id, option.value)
                    plugin:updateConfigFromSettings()
                end,
            })
        end
        
    elseif item.type == "number" then
        menu_item.callback = function()
            local MultiInputDialog = require("ui/widget/multiinputdialog")
            local UIManager = require("ui/uimanager")
            local current_value = self:getSettingValue(plugin, item.path or item.id) or item.default
            
            local dialog
            dialog = MultiInputDialog:new{
                title = item.text,
                fields = {
                    {
                        text = tostring(current_value),
                        hint = item.description,
                        input_type = "number",
                    },
                },
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            callback = function()
                                local value = tonumber(dialog:getField(1))
                                local valid, err = schema:validateSetting(item.id, value)
                                if valid then
                                    self:setSettingValue(plugin, item.path or item.id, value)
                                    plugin:updateConfigFromSettings()
                                    UIManager:close(dialog)
                                else
                                    local InfoMessage = require("ui/widget/infomessage")
                                    UIManager:show(InfoMessage:new{
                                        text = err or _("Invalid value"),
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end
        
    elseif item.type == "text" then
        menu_item.callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager = require("ui/uimanager")
            local current_value = self:getSettingValue(plugin, item.path or item.id)
            -- Only use default if current_value is nil or empty string
            if current_value == nil or current_value == "" then
                current_value = item.default or ""
            end
            
            local dialog
            dialog = InputDialog:new{
                title = item.text,
                input = current_value,
                input_hint = item.description,
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                local value = dialog:getInputText()
                                self:setSettingValue(plugin, item.path or item.id, value)
                                plugin:updateConfigFromSettings()
                                UIManager:close(dialog)
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end
        
    elseif item.type == "dynamic_select" then
        -- Dynamic select (like model selection)
        menu_item.sub_item_table_func = function()
            return plugin:getModelMenuItems()
        end
        
    elseif item.type == "action" then
        -- Action button
        if item.confirm then
            menu_item.callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                local UIManager = require("ui/uimanager")
                UIManager:show(ConfirmBox:new{
                    text = item.confirm_text or _("Are you sure?"),
                    ok_callback = function()
                        if plugin[item.callback] then
                            plugin[item.callback](plugin)
                        else
                            logger.warn("Settings action callback not found:", item.callback)
                        end
                    end,
                })
            end
        else
            menu_item.callback = function()
                if plugin[item.callback] then
                    plugin[item.callback](plugin)
                else
                    logger.warn("Settings action callback not found:", item.callback)
                end
            end
        end
        
    elseif item.type == "submenu" then
        if item.callback then
            -- Callback-based submenu
            menu_item.sub_item_table_func = function()
                if plugin[item.callback] then
                    return plugin[item.callback](plugin)
                else
                    logger.warn("Submenu callback not found:", item.callback)
                    return {}
                end
            end
        elseif item.dynamic then
            -- Dynamic submenu (like provider config)
            menu_item.sub_item_table_func = function()
                return plugin:getProviderConfigMenuItems()
            end
        elseif item.items then
            -- Static submenu with predefined items
            menu_item.sub_item_table = {}
            for _, subitem in ipairs(item.items) do
                local submenu_item = self:createMenuItem(plugin, subitem, schema)
                if submenu_item then
                    table.insert(menu_item.sub_item_table, submenu_item)
                end
            end
        end
    end
    
    return menu_item
end

-- Get a setting value using dot notation path
function SettingsManager:getSettingValue(plugin, path)
    if not path then return nil end
    
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    local value = plugin.settings.data
    for _, part in ipairs(parts) do
        if type(value) == "table" then
            value = value[part]
        else
            return nil
        end
    end
    
    return value
end

-- Set a setting value using dot notation path
function SettingsManager:setSettingValue(plugin, path, value)
    if not path then return end
    
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = plugin.settings.data
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end
    
    current[parts[#parts]] = value
    plugin.settings:flush()
end

-- Generate quick settings menu for gesture access
function SettingsManager:generateQuickSettingsMenu(plugin, schema)
    local quick_items = {}
    
    -- Add most commonly used settings
    table.insert(quick_items, {
        text = _("AI Provider"),
        sub_item_table_func = function()
            local provider_item = schema:getItemById("provider")
            if provider_item then
                return self:createMenuItem(plugin, provider_item, schema).sub_item_table
            end
            return {}
        end,
    })
    
    table.insert(quick_items, {
        text = _("Model"),
        sub_item_table_func = function()
            return plugin:getModelMenuItems()
        end,
    })
    
    -- Add debug mode toggle
    local debug_item = schema:getItemById("debug_mode")
    if debug_item then
        table.insert(quick_items, self:createMenuItem(plugin, debug_item, schema))
    end
    
    -- Add separator
    table.insert(quick_items, {
        text = "---",
    })
    
    -- Add link to full settings
    table.insert(quick_items, {
        text = _("All Settings..."),
        callback = function()
            plugin:onAssistantSettings()
        end,
    })
    
    return quick_items
end

return SettingsManager