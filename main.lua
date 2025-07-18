local Device = require("device")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local NetworkMgr = require("ui/network/manager")
local Dispatcher = require("dispatcher")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local T = require("ffi/util").template
local logger = require("logger")
local util = require("util")
local Screen = Device.screen

local showChatGPTDialog = require("dialogs")
local UpdateChecker = require("update_checker")
local SettingsSchema = require("settings_schema")
local SettingsManager = require("ui/settings_manager")
local PromptsManager = require("ui/prompts_manager")
local PromptService = require("prompt_service")

-- Load model lists
local ModelLists = {}
local ok, loaded_lists = pcall(function() 
    local path = package.path
    -- Add the current directory to the package path if not already there
    if not path:match("%./%?%.lua") then
        package.path = "./?.lua;" .. path
    end
    return require("model_lists") 
end)
if ok and loaded_lists then
    ModelLists = loaded_lists
    logger.info("Loaded model lists from model_lists.lua: " .. #(ModelLists.anthropic or {}) .. " Anthropic models, " .. 
                #(ModelLists.openai or {}) .. " OpenAI models, " .. 
                #(ModelLists.deepseek or {}) .. " DeepSeek models, " ..
                #(ModelLists.gemini or {}) .. " Gemini models, " ..
                #(ModelLists.ollama or {}) .. " Ollama models")
else
    logger.warn("Could not load model_lists.lua: " .. tostring(loaded_lists) .. ", using empty lists")
    -- Fallback to basic model lists
    ModelLists = {
        anthropic = {"claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307"},
        openai = {"gpt-4o", "gpt-4-turbo", "gpt-3.5-turbo"},
        deepseek = {"deepseek-chat"},
        gemini = {"gemini-1.5-pro", "gemini-1.0-pro"},
        ollama = {"llama3", "mistral", "mixtral"}
    }
end

-- Load the configuration directly
local configuration = {
    -- Default configuration values
    provider = "anthropic",
    features = {
        hide_highlighted_text = false,
        hide_long_highlights = true,
        long_highlight_threshold = 280,
        translate_to = "English",
        debug = false,
    }
}

-- Try to load the configuration file if it exists
-- Get the directory of this script
local function script_path()
   local str = debug.getinfo(2, "S").source:sub(2)
   return str:match("(.*/)")
end

local plugin_dir = script_path()
local config_path = plugin_dir .. "configuration.lua" 

local ok, loaded_config = pcall(dofile, config_path)
if ok and loaded_config then
    configuration = loaded_config
    logger.info("Loaded configuration from configuration.lua")
else
    logger.warn("Could not load configuration.lua, using defaults")
end

-- Helper function to count table entries
local function table_count(t)
    local count = 0
    if t then
        for _ in pairs(t) do
            count = count + 1
        end
    end
    return count
end

local AskGPT = WidgetContainer:extend{
  name = "assistant",
  is_doc_only = false,
}

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

function AskGPT:init()
  logger.info("Assistant plugin: init() called")
  
  -- Initialize settings
  self:initSettings()
  
  -- Initialize prompt service
  self.prompt_service = PromptService:new(self.settings)
  self.prompt_service:initialize()
  
  -- Register dispatcher actions
  self:onDispatcherRegisterActions()
  
  -- Add to highlight dialog if highlight feature is available
  if self.ui and self.ui.highlight then
    self.ui.highlight:addToHighlightDialog("assistant_dialog", function(_reader_highlight_instance)
      return {
        text = _("Assistant"),
        enabled = Device:hasClipboard(),
        callback = function()
          NetworkMgr:runWhenOnline(function()
            if not updateMessageShown then
              UpdateChecker.checkForUpdates()
              updateMessageShown = true -- Set flag to true so it won't show again
            end
            -- Make sure we're using the latest configuration
            self:updateConfigFromSettings()
            showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text, configuration, nil, self)
          end)
        end,
      }
    end)
    logger.info("Added Assistant to highlight dialog")
  else
    logger.warn("Highlight feature not available, skipping highlight dialog integration")
  end
  
  -- Register to main menu immediately
  self:registerToMainMenu()
  
  -- Also register when reader is ready as a backup
  self.onReaderReady = function()
    self:registerToMainMenu()
  end
  
  -- Register file dialog buttons with delays to ensure they appear at the bottom
  -- First attempt after a short delay to let core plugins register
  UIManager:scheduleIn(0.5, function()
    logger.info("Assistant: First file dialog button registration (0.5s delay)")
    self:addFileDialogButtons()
  end)
  
  -- Second attempt after other plugins should be loaded
  UIManager:scheduleIn(2, function()
    logger.info("Assistant: Second file dialog button registration (2s delay)")
    self:addFileDialogButtons()
  end)
  
  -- Final attempt to ensure registration in all contexts  
  UIManager:scheduleIn(5, function()
    logger.info("Assistant: Final file dialog button registration (5s delay)")
    self:addFileDialogButtons()
  end)
  
  -- Patch FileManager for multi-select support
  self:patchFileManagerForMultiSelect()
end

-- Button generator for single file actions
function AskGPT:generateFileDialogButtons(file, is_file, book_props)
  logger.info("Assistant: generateFileDialogButtons called with file=" .. tostring(file) .. 
              ", is_file=" .. tostring(is_file) .. ", has_book_props=" .. tostring(book_props ~= nil))
  
  -- Only show buttons for document files
  if is_file and self:isDocumentFile(file) then
    logger.info("Assistant: File is a document, creating Assistant button")
    
    -- Get metadata
    local title = book_props and book_props.title or file:match("([^/]+)$")
    local authors = book_props and book_props.authors or ""
    
    -- Return a row with the Assistant button
    -- FileManagerHistory expects a row (array of buttons)
    local buttons = {
      {
        text = _("Assistant"),
        callback = function()
          -- Close any open file dialog
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog and current_dialog.close then
            UIManager:close(current_dialog)
          end
          -- Show assistant dialog with book context
          self:showAssistantDialogForFile(file, title, authors, book_props)
        end,
      }
    }
    
    logger.info("Assistant: Returning button row")
    return buttons
  else
    logger.info("Assistant: Not a document file or is_file=false, returning nil")
    return nil
  end
end

-- Button generator for multiple file selection
function AskGPT:generateMultiSelectButtons(file, is_file, book_props)
  local FileManager = require("apps/filemanager/filemanager")
  -- Check if we have multiple files selected
  if FileManager.instance and FileManager.instance.selected_files and 
     next(FileManager.instance.selected_files) then
    logger.info("Assistant: Multiple files selected")
    return {
      {
        text = _("Compare Selected Books"),
        callback = function()
          local UIManager = require("ui/uimanager")
          local current_dialog = UIManager:getTopmostVisibleWidget()
          if current_dialog and current_dialog.close then
            UIManager:close(current_dialog)
          end
          self:compareSelectedBooks(FileManager.instance.selected_files)
        end,
      },
    }
  end
end

-- Add file dialog buttons using the FileManager instance API
function AskGPT:addFileDialogButtons()
  -- Prevent multiple registrations
  if self.file_dialog_buttons_added then
    logger.info("Assistant: File dialog buttons already registered, skipping")
    return true
  end
  
  logger.info("Assistant: Attempting to add file dialog buttons")
  
  local FileManager = require("apps/filemanager/filemanager")
  
  -- Load other managers carefully to avoid circular dependencies
  local FileManagerHistory, FileManagerCollection, FileManagerFileSearcher
  pcall(function()
    FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  end)
  pcall(function()
    FileManagerCollection = require("apps/filemanager/filemanagercollection")
  end)
  pcall(function()
    FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  end)
  
  -- Create closures that bind self
  local single_file_generator = function(file, is_file, book_props)
    local buttons = self:generateFileDialogButtons(file, is_file, book_props)
    if buttons then
      logger.info("Assistant: Generated buttons for file: " .. tostring(file))
    end
    return buttons
  end
  
  local multi_file_generator = function(file, is_file, book_props)
    return self:generateMultiSelectButtons(file, is_file, book_props)
  end
  
  local success_count = 0
  
  -- Method 1: Register via instance method if available
  if FileManager.instance and FileManager.instance.addFileDialogButtons then
    local success = pcall(function()
      FileManager.instance:addFileDialogButtons("zzz_assistant_file_actions", single_file_generator)
      FileManager.instance:addFileDialogButtons("zzz_assistant_multi_select", multi_file_generator)
    end)
    
    if success then
      logger.info("Assistant: File dialog buttons registered via instance method")
      success_count = success_count + 1
    end
  end
  
  -- Method 2: Register on all widget classes using static method pattern (like CoverBrowser)
  -- This ensures buttons appear in History, Collections, and Search dialogs
  local widgets_to_register = {
    filemanager = FileManager,
    history = FileManagerHistory,
    collections = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
  }
  
  for widget_name, widget_class in pairs(widgets_to_register) do
    if widget_class and FileManager.addFileDialogButtons then
      logger.info("Assistant: Attempting to register buttons on " .. widget_name .. " class")
      local success, err = pcall(function()
        FileManager.addFileDialogButtons(widget_class, "zzz_assistant_file_actions", single_file_generator)
        FileManager.addFileDialogButtons(widget_class, "zzz_assistant_multi_select", multi_file_generator)
      end)
      
      if success then
        logger.info("Assistant: File dialog buttons registered on " .. widget_name)
        success_count = success_count + 1
      else
        logger.warn("Assistant: Failed to register buttons on " .. widget_name .. ": " .. tostring(err))
      end
    else
      if not widget_class then
        logger.warn("Assistant: Widget class " .. widget_name .. " not loaded")
      else
        logger.warn("Assistant: FileManager.addFileDialogButtons not available")
      end
    end
  end
  
  -- Log diagnostic information
  if success_count > 0 then
    -- Mark as registered to prevent duplicate attempts
    self.file_dialog_buttons_added = true
    -- Check what History/Collections/Search can see
    self:checkButtonVisibility()
    return true
  else
    logger.error("Assistant: Failed to register file dialog buttons with any method")
    return false
  end
end

function AskGPT:removeFileDialogButtons()
  -- Remove file dialog buttons when plugin is unloaded
  if not self.file_dialog_buttons_added then
    return
  end
  
  logger.info("Assistant: Removing file dialog buttons")
  
  local FileManager = require("apps/filemanager/filemanager")
  local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
  local FileManagerCollection = require("apps/filemanager/filemanagercollection")
  local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
  
  -- Remove from instance if available
  if FileManager.instance and FileManager.instance.removeFileDialogButtons then
    pcall(function()
      FileManager.instance:removeFileDialogButtons("zzz_assistant_multi_select")
      FileManager.instance:removeFileDialogButtons("zzz_assistant_file_actions")
    end)
  end
  
  -- Remove from all widget classes
  local widgets_to_clean = {
    filemanager = FileManager,
    history = FileManagerHistory,
    collections = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
  }
  
  for widget_name, widget_class in pairs(widgets_to_clean) do
    if widget_class and FileManager.removeFileDialogButtons then
      pcall(function()
        FileManager.removeFileDialogButtons(widget_class, "zzz_assistant_multi_select")
        FileManager.removeFileDialogButtons(widget_class, "zzz_assistant_file_actions")
      end)
    end
  end
  
  self.file_dialog_buttons_added = false
  logger.info("Assistant: File dialog buttons removed")
end

function AskGPT:checkButtonVisibility()
  local FileManager = require("apps/filemanager/filemanager")
  
  -- Check instance buttons
  if FileManager.instance and FileManager.instance.file_dialog_added_buttons then
    logger.info("Assistant: FileManager.instance.file_dialog_added_buttons has " .. 
                #FileManager.instance.file_dialog_added_buttons .. " entries")
    
    -- List all button generators for debugging (limit to first 10 to avoid spam)
    local count = math.min(10, #FileManager.instance.file_dialog_added_buttons)
    for i = 1, count do
      local entry = FileManager.instance.file_dialog_added_buttons[i]
      local name = ""
      if type(entry) == "table" and entry.name then
        name = entry.name
      elseif type(entry) == "function" then
        name = "function"
      else
        name = "unknown"
      end
      logger.info("Assistant: Instance button generator " .. i .. ": " .. name)
    end
  end
  
  -- Check static buttons
  if FileManager.file_dialog_added_buttons then
    logger.info("Assistant: FileManager.file_dialog_added_buttons (static) has " .. 
                #FileManager.file_dialog_added_buttons .. " entries")
    
    -- List all button generators for debugging
    for i, entry in ipairs(FileManager.file_dialog_added_buttons) do
      local name = ""
      if type(entry) == "table" and entry.name then
        name = entry.name
      elseif type(entry) == "function" then
        -- Try to identify our functions
        local info = debug.getinfo(entry)
        if info and info.source and info.source:find("assistant.koplugin") then
          name = "assistant_function"
        else
          name = "function"
        end
      else
        name = tostring(type(entry))
      end
      logger.info("Assistant: Static button generator " .. i .. ": " .. name)
    end
  end
  
  -- Note: Cannot check FileManagerHistory/Collection here due to circular dependency
  -- They will be checked when they're actually created
  logger.info("Assistant: Button registration complete. History/Collection will see buttons when created.")
end

function AskGPT:showAssistantDialogForFile(file, title, authors, book_props)
  -- Create book context string
  local book_context = string.format("Book: %s", title)
  if authors and authors ~= "" then
    book_context = book_context .. string.format("\nAuthor: %s", authors)
  end
  if book_props then
    if book_props.series then
      book_context = book_context .. string.format("\nSeries: %s", book_props.series)
    end
    if book_props.language then
      book_context = book_context .. string.format("\nLanguage: %s", book_props.language)
    end
    if book_props.year then
      book_context = book_context .. string.format("\nYear: %s", book_props.year)
    end
  end
  
  -- Create a copy of configuration with file browser context
  local temp_config = {}
  for k, v in pairs(configuration) do
    if type(v) == "table" then
      temp_config[k] = {}
      for k2, v2 in pairs(v) do
        temp_config[k][k2] = v2
      end
    else
      temp_config[k] = v
    end
  end
  
  -- Ensure features exists
  temp_config.features = temp_config.features or {}
  
  -- Get book context configuration
  local book_context_config = temp_config.features.book_context or {
    prompts = {}
  }
  
  logger.info("Book context has " .. 
    (book_context_config.prompts and tostring(table_count(book_context_config.prompts)) or "0") .. 
    " prompts defined")
  
  -- Don't set system prompt here - let dialogs.lua handle it based on context
  -- Store book metadata separately for use in prompts
  if book_context and book_context ~= "" then
    temp_config.features.book_context = book_context
  end
  
  -- Mark this as book context
  temp_config.features.is_book_context = true
  
  -- Store the book metadata for template substitution
  temp_config.features.book_metadata = {
    title = title,
    author = authors,
    author_clause = authors ~= "" and string.format(" by %s", authors) or "",
    file = file  -- Add file path for chat saving
  }
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    -- Show dialog with book context instead of highlighted text
    showChatGPTDialog(self.ui, book_context, temp_config, nil, self)
  end)
end

function AskGPT:isDocumentFile(file)
  -- Check if the file is a supported document type
  local DocumentRegistry = require("document/documentregistry")
  return DocumentRegistry:hasProvider(file)
end


function AskGPT:compareSelectedBooks(selected_files)
  -- Check if we have selected files
  if not selected_files then
    logger.error("Assistant: compareSelectedBooks called with nil selected_files")
    UIManager:show(InfoMessage:new{
      text = _("No files selected for comparison"),
    })
    return
  end
  
  local DocumentRegistry = require("document/documentregistry")
  local FileManager = require("apps/filemanager/filemanager")
  local books_info = {}
  
  -- Try to load BookInfoManager to get cached metadata
  local BookInfoManager = nil
  local ok = pcall(function()
    BookInfoManager = require("bookinfomanager")
  end)
  
  -- Log how many files we're processing
  local file_count = 0
  for file, _ in pairs(selected_files) do
    file_count = file_count + 1
    logger.info("Assistant: Selected file " .. file_count .. ": " .. tostring(file))
  end
  logger.info("Assistant: Processing " .. file_count .. " selected files")
  
  -- Gather info about each selected book
  for file, _ in pairs(selected_files) do
    if self:isDocumentFile(file) then
      local title = nil
      local authors = ""
      
      -- First try to get metadata from BookInfoManager (cached)
      if ok and BookInfoManager then
        local book_info = BookInfoManager:getBookInfo(file)
        if book_info then
          title = book_info.title
          authors = book_info.authors or ""
        end
      end
      
      -- If no cached metadata, try to extract from filename
      if not title then
        -- Try to extract cleaner title from filename
        local filename = file:match("([^/]+)$")
        if filename then
          -- Remove extension
          title = filename:gsub("%.%w+$", "")
          -- Try to extract title and author from common filename patterns
          -- Pattern: "Title · Additional Info -- Author -- Other Info"
          local extracted_title, extracted_author = title:match("^(.-)%s*·.*--%s*([^-]+)")
          if extracted_title and extracted_author then
            title = extracted_title:gsub("%s+$", "")
            authors = extracted_author:gsub("%s+$", ""):gsub(",%s*$", "")
          else
            -- Pattern: "Author - Title"
            extracted_author, extracted_title = title:match("^([^-]+)%s*-%s*(.+)")
            if extracted_author and extracted_title and not extracted_title:match("%-") then
              title = extracted_title:gsub("%s+$", "")
              authors = extracted_author:gsub("%s+$", "")
            end
          end
        end
      end
      
      -- Final fallback
      if not title or title == "" then
        title = file:match("([^/]+)$") or "Unknown"
      end
      
      logger.info("Assistant: Book info - Title: " .. tostring(title) .. ", Authors: " .. tostring(authors))
      
      table.insert(books_info, {
        title = title,
        authors = authors,
        file = file
      })
    else
      logger.warn("Assistant: File is not a document: " .. tostring(file))
    end
  end
  
  logger.info("Assistant: Collected info for " .. #books_info .. " books")
  
  -- Create comparison prompt
  if #books_info < 2 then
    UIManager:show(InfoMessage:new{
      text = _("Please select at least 2 books to compare"),
    })
    return
  end
  
  local books_list = {}
  for i, book in ipairs(books_info) do
    if book.authors ~= "" then
      table.insert(books_list, string.format('%d. "%s" by %s', i, book.title, book.authors))
    else
      table.insert(books_list, string.format('%d. "%s"', i, book.title))
    end
  end
  
  logger.info("Assistant: Books list for comparison:")
  for i, book_str in ipairs(books_list) do
    logger.info("  " .. book_str)
  end
  
  -- Build the book context that will be used by the multi_file_browser prompts
  local prompt_text = string.format("Selected %d books for comparison:\n\n%s", 
                                    #books_info, 
                                    table.concat(books_list, "\n"))
  
  logger.info("Assistant: Book context for comparison: " .. prompt_text)
  
  -- Create a copy of configuration with file browser context
  local temp_config = {}
  for k, v in pairs(configuration) do
    if type(v) == "table" then
      temp_config[k] = {}
      for k2, v2 in pairs(v) do
        temp_config[k][k2] = v2
      end
    else
      temp_config[k] = v
    end
  end
  
  -- Ensure features exists
  temp_config.features = temp_config.features or {}
  
  -- Mark this as multi book context
  temp_config.features.is_multi_book_context = true
  
  -- Store the books list as context
  temp_config.features.book_context = prompt_text
  temp_config.features.books_info = books_info  -- Store the parsed book info for template substitution
  
  -- Store metadata for template substitution (using first book's info)
  if #books_info > 0 then
    temp_config.features.book_metadata = {
      title = books_info[1].title,
      author = books_info[1].authors,
      author_clause = books_info[1].authors ~= "" and string.format(" by %s", books_info[1].authors) or ""
    }
  end
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    -- Don't update from settings as we want our temp_config
    -- Pass the prompt as book context with book configuration
    -- Use FileManager.instance as the UI context
    local ui_context = self.ui or FileManager.instance
    showChatGPTDialog(ui_context, prompt_text, temp_config, nil, self)
  end)
end

-- Generate button for multi-select plus dialog
function AskGPT:genMultipleAssistantButton(close_dialog_toggle_select_mode_callback, button_disabled, selected_files)
  return {
    {
      text = _("Compare with Assistant"),
      enabled = not button_disabled,
      callback = function()
        -- Capture selected files before closing dialog
        local files_to_compare = selected_files or (FileManager.instance and FileManager.instance.selected_files)
        if files_to_compare then
          -- Make a copy of selected files since they may be cleared after dialog closes
          local files_copy = {}
          for file, val in pairs(files_to_compare) do
            files_copy[file] = val
          end
          -- Close the multi-select dialog first
          local dialog = UIManager:getTopmostVisibleWidget()
          if dialog then
            UIManager:close(dialog)
          end
          -- Don't toggle select mode yet - let the comparison finish first
          -- Schedule the comparison to run after dialog closes
          UIManager:scheduleIn(0.1, function()
            self:compareSelectedBooks(files_copy)
          end)
        else
          logger.error("Assistant: No selected files found for comparison")
          UIManager:show(InfoMessage:new{
            text = _("No files selected for comparison"),
          })
        end
      end,
    },
  }
end

function AskGPT:onDispatcherRegisterActions()
  logger.info("Assistant: onDispatcherRegisterActions called")
  
  if not Dispatcher then
    logger.warn("Assistant: Dispatcher module not available!")
    return
  end
  
  -- Register chat history action
  Dispatcher:registerAction("assistant_chat_history", {
    category = "none", 
    event = "AssistantChatHistory", 
    title = _("Assistant: Chat History"), 
    general = true
  })
  
  -- Register continue last saved chat action
  Dispatcher:registerAction("assistant_continue_last", {
    category = "none", 
    event = "AssistantContinueLast", 
    title = _("Assistant: Continue Last Saved Chat"), 
    general = true,
    separator = true
  })
  
  -- Register assistant settings action
  Dispatcher:registerAction("assistant_settings", {
    category = "none", 
    event = "AssistantSettings", 
    title = _("Assistant: Settings"), 
    general = true
  })
  
  -- Register general context chat action
  Dispatcher:registerAction("assistant_general_chat", {
    category = "none", 
    event = "AssistantGeneralChat", 
    title = _("Assistant: General Chat"), 
    general = true
  })
  
  -- Register file browser context action
  Dispatcher:registerAction("assistant_book_chat", {
    category = "none", 
    event = "AssistantBookChat", 
    title = _("Assistant: Chat About Book"), 
    general = true
  })
  
  logger.info("Assistant: Dispatcher actions registered successfully")
end

function AskGPT:registerToMainMenu()
  -- Add to KOReader's main menu
  if not self.menu_item and self.ui and self.ui.menu then
    self.menu_item = self.ui.menu:registerToMainMenu(self)
    logger.info("Registered Assistant to main menu")
  else
    if not self.ui then
      logger.warn("Cannot register to main menu: UI not available")
    elseif not self.ui.menu then
      logger.warn("Cannot register to main menu: Menu not available")
    end
  end
end

function AskGPT:initSettings()
  -- Create settings file path
  self.settings_file = DataStorage:getSettingsDir() .. "/assistant_settings.lua"
  -- Initialize settings with default values from configuration.lua
  self.settings = LuaSettings:open(self.settings_file)
  
  -- Perform one-time migration from old prompt format
  if not self.settings:readSetting("prompts_migrated_v2") then
    self:migratePromptsV2()
    self.settings:saveSetting("prompts_migrated_v2", true)
    self.settings:flush()
  end
  
  -- Set default values if they don't exist
  if not self.settings:has("provider") then
    self.settings:saveSetting("provider", configuration.provider or "anthropic")
  end
  
  if not self.settings:has("model") then
    self.settings:saveSetting("model", configuration.model)
  end
  
  if not self.settings:has("features") then
    self.settings:saveSetting("features", {
      hide_highlighted_text = configuration.features.hide_highlighted_text or false,
      hide_long_highlights = configuration.features.hide_long_highlights or true,
      long_highlight_threshold = configuration.features.long_highlight_threshold or 280,
      translate_to = configuration.features.translate_to or "English",
      debug = configuration.features.debug or false,
    })
  end
  
  self.settings:flush()
  
  -- Update the configuration with settings values
  self:updateConfigFromSettings()
end

function AskGPT:updateConfigFromSettings()
  -- Update configuration with values from settings
  configuration.provider = self.settings:readSetting("provider")
  configuration.model = self.settings:readSetting("model")
  
  local features = self.settings:readSetting("features")
  if features then
    -- Update all features from settings
    configuration.features = features
  end
  
  
  -- Log the current configuration for debugging
  logger.info("Updated configuration: provider=" .. (configuration.provider or "nil") .. 
              ", model=" .. (configuration.model or "default"))
end

function AskGPT:addToMainMenu(menu_items)
  -- Generate menu from schema
  local settings_menu = SettingsManager:generateMenuFromSchema(self, SettingsSchema)
  
  -- Create the main menu with quick actions at top level
  local assistant_menu = {
    {
      text = _("New General Chat"),
      callback = function()
        self:startGeneralChat()
      end,
    },
    {
      text = _("Chat History"),
      callback = function()
        self:showChatHistory()
      end,
    },
    {
      text = "────────────────────",
      enabled = false,
      callback = function() end,
    },
  }
  
  -- Add all settings categories
  for _, item in ipairs(settings_menu) do
    table.insert(assistant_menu, item)
  end
  
  menu_items["assistant"] = {
    text = _("Assistant"),
    sorting_hint = "tools",
    sorting_order = 1, -- Add explicit sorting order to appear at the top
    sub_item_table = assistant_menu,
  }
end


function AskGPT:showManageModelsDialog()
  -- Show a message that this feature is now managed through model_lists.lua
  UIManager:show(InfoMessage:new{
    text = _("Model lists are now managed through the model_lists.lua file. Please edit this file to add or remove models."),
  })
end

function AskGPT:showThresholdDialog()
  local features = self.settings:readSetting("features")
  -- Store dialog in self to ensure it remains in scope during callbacks
  self.threshold_dialog = MultiInputDialog:new{
    title = _("Long Highlight Threshold"),
    fields = {
      {
        text = tostring(features.long_highlight_threshold or 280),
        hint = _("Number of characters"),
        input_type = "number",
      },
    },
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(self.threshold_dialog)
          end,
        },
        {
          text = _("Save"),
          callback = function()
            local threshold = tonumber(self.threshold_dialog.fields[1].text)
            if threshold and threshold > 0 then
              features.long_highlight_threshold = threshold
              self.settings:saveSetting("features", features)
              self.settings:flush()
              self:updateConfigFromSettings()
              UIManager:close(self.threshold_dialog)
              UIManager:show(InfoMessage:new{
                text = T(_("Threshold set to %1 characters"), threshold),
              })
            else
              UIManager:show(InfoMessage:new{
                text = _("Please enter a valid positive number"),
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(self.threshold_dialog)
end

function AskGPT:toggleDebugMode()
  local features = self.settings:readSetting("features")
  features.debug = not features.debug
  self.settings:saveSetting("features", features)
  self.settings:flush()
  self:updateConfigFromSettings()
  UIManager:show(InfoMessage:new{
    text = features.debug and 
           _("Debug mode enabled") or
           _("Debug mode disabled"),
  })
end

function AskGPT:showTranslationDialog()
  local features = self.settings:readSetting("features")
  -- Store dialog in self to ensure it remains in scope during callbacks
  self.translation_dialog = MultiInputDialog:new{
    title = _("Translation Language"),
    fields = {
      {
        text = features.translate_to or "English",
        hint = _("Language name or leave blank to disable"),
      },
    },
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(self.translation_dialog)
          end,
        },
        {
          text = _("Save"),
          callback = function()
            local language = self.translation_dialog.fields[1].text
            if language == "" then
              language = nil
            end
            features.translate_to = language
            self.settings:saveSetting("features", features)
            self.settings:flush()
            self:updateConfigFromSettings()
            UIManager:close(self.translation_dialog)
            UIManager:show(InfoMessage:new{
              text = language and 
                     T(_("Translation set to %1"), language) or
                     _("Translation disabled"),
            })
          end,
        },
      },
    },
  }
  UIManager:show(self.translation_dialog)
end

-- Event handlers for gesture-triggered actions
function AskGPT:onAssistantChatHistory()
  -- Use the same implementation as the settings menu
  self:showChatHistory()
  return true
end

function AskGPT:onAssistantContinueLast()
  local ChatHistoryManager = require("chat_history_manager")
  local ChatHistoryDialog = require("chat_history_dialog")
  
  -- Get the most recent chat across all documents
  local most_recent_chat, document_path = ChatHistoryManager:getMostRecentChat()
  
  if not most_recent_chat then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("No saved chats found")
    })
    return true
  end
  
  logger.info("Continue last chat: found chat ID " .. (most_recent_chat.id or "nil") .. 
              " for document: " .. (document_path or "nil"))
  
  -- Continue the most recent chat
  local chat_history_manager = ChatHistoryManager:new()
  ChatHistoryDialog:continueChat(self.ui, document_path, most_recent_chat, chat_history_manager, configuration)
  return true
end

function AskGPT:onAssistantGeneralChat()
  if not configuration then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return true
  end
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()
    
    -- Create a temp config with general context flag
    local temp_config = {}
    for k, v in pairs(configuration) do
      if type(v) ~= "table" then
        temp_config[k] = v
      else
        temp_config[k] = {}
        for k2, v2 in pairs(v) do
          temp_config[k][k2] = v2
        end
      end
    end
    temp_config.features = temp_config.features or {}
    temp_config.features.is_general_context = true
    
    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, temp_config, nil, self)
  end)
  return true
end

function AskGPT:onAssistantBookChat()
  -- Check if we have a document open
  if not self.ui or not self.ui.document then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Please open a book first")
    })
    return true
  end
  
  -- Get book metadata and use the same implementation as showAssistantDialogForFile
  local doc_props = self.ui.document:getProps()
  local title = doc_props.title or "Unknown"
  local authors = doc_props.authors or ""
  
  -- Call the existing function that handles file browser context properly
  self:showAssistantDialogForFile(self.ui.document.file, title, authors, doc_props)
  return true
end

function AskGPT:onAssistantSettings()
  logger.info("Assistant: Opening settings menu")
  
  local UIManager = require("ui/uimanager")
  
  -- Check if we're in FileManager or Reader context
  if self.ui then
    -- First ensure the main menu exists
    if not self.ui.menu then
      self.ui:handleEvent(Event:new("ShowMenu"))
    end
    
    -- Use a slight delay to ensure the menu is ready
    UIManager:scheduleIn(0.1, function()
      if self.ui.menu and self.ui.menu.onShowMenu then
        -- Determine the correct tab index for Tools
        -- In FileManager: Tools is at index 3
        -- In ReaderUI (document open): Tools is at index 4 (due to document tab)
        local tools_tab_index = 3
        if self.ui.document then
          -- We're in a reader with a document open
          tools_tab_index = 4
          logger.info("Assistant: In reader mode, Tools tab is at index 4")
        else
          logger.info("Assistant: In file manager mode, Tools tab is at index 3")
        end
        
        -- Show the main menu at Tools tab
        self.ui.menu:onShowMenu(tools_tab_index)
        
        -- After menu is shown, navigate to Assistant
        UIManager:scheduleIn(0.2, function()
          -- Try to access the menu container
          local menu_container = self.ui.menu.menu_container
          if menu_container and menu_container[1] then
            local touch_menu = menu_container[1]
            
            -- Now we should be on the Tools tab
            -- Get the current page items
            local current_items = touch_menu.item_table
            if current_items then
              logger.info("Assistant: Tools tab has " .. #current_items .. " items on current page")
              
              -- Look for Assistant on the current page
              for i, item in ipairs(current_items) do
                logger.info("  Item " .. i .. ": " .. (item.text or "no text"))
                if item.text == _("Assistant") or item.text == "Assistant" then
                  logger.info("Assistant: Found Assistant at position " .. i .. ", selecting it")
                  touch_menu:onMenuSelect(item)
                  return
                end
              end
              
              -- If not found, look for next page indicator
              logger.info("Assistant: Not found on current page, checking for next page")
              for i, item in ipairs(current_items) do
                -- In KOReader, the next page is usually indicated by "More" or similar
                if item.text and (item.text:match("More") or item.text:match(">>") or i == #current_items) then
                  logger.info("Assistant: Going to next page")
                  touch_menu:onMenuSelect(item)
                  
                  -- After navigating to next page, look for Assistant
                  UIManager:scheduleIn(0.2, function()
                    local new_items = touch_menu.item_table
                    if new_items then
                      logger.info("Assistant: Next page has " .. #new_items .. " items")
                      for j, new_item in ipairs(new_items) do
                        logger.info("  Item " .. j .. ": " .. (new_item.text or "no text"))
                        if new_item.text == _("Assistant") or new_item.text == "Assistant" then
                          logger.info("Assistant: Found Assistant on next page at position " .. j)
                          touch_menu:onMenuSelect(new_item)
                          return
                        end
                      end
                    end
                    logger.warn("Assistant: Could not find Assistant on next page either")
                  end)
                  return
                end
              end
              
              logger.warn("Assistant: Could not find Assistant or next page indicator")
            else
              logger.warn("Assistant: No items found in Tools menu")
            end
          else
            logger.warn("Assistant: Could not access menu container")
          end
        end)
      end
    end)
  else
    UIManager:show(require("ui/widget/infomessage"):new{
      text = _("Please open a book or file browser first"),
    })
  end
  
  return true
end

-- New settings system callback methods
function AskGPT:getModelMenuItems()
  local current_provider = self.settings:readSetting("provider")
  local current_model = self.settings:readSetting("model")
  local provider_models = ModelLists[current_provider] or {}
  
  local sub_item_table = {}
  
  -- Add models from the list
  for idx, model_name in ipairs(provider_models) do
    table.insert(sub_item_table, {
      text = model_name,
      callback = function()
        self.settings:saveSetting("model", model_name)
        self.settings:flush()
        self:updateConfigFromSettings()
        UIManager:show(InfoMessage:new{
          text = T(_("Model set to %1"), model_name),
        })
      end,
      checked_func = function()
        return self.settings:readSetting("model") == model_name
      end,
    })
  end
  
  -- Add option to use default model
  table.insert(sub_item_table, {
    text = _("Use Default Model"),
    callback = function()
      self.settings:saveSetting("model", nil)
      self.settings:flush()
      self:updateConfigFromSettings()
      UIManager:show(InfoMessage:new{
        text = _("Using default model for selected provider"),
      })
    end,
    checked_func = function()
      return self.settings:readSetting("model") == nil
    end,
  })
  
  -- Add option to enter custom model
  table.insert(sub_item_table, {
    text = _("Enter Custom Model..."),
    callback = function()
      local current_provider = self.settings:readSetting("provider") or "anthropic"
      local provider_name = ({
        anthropic = _("Anthropic"),
        openai = _("OpenAI"),
        deepseek = _("DeepSeek"),
        gemini = _("Google Gemini"),
        ollama = _("Ollama")
      })[current_provider] or current_provider
      self:showCustomModelDialogForProvider(current_provider, provider_name)
    end,
  })
  
  return sub_item_table
end

function AskGPT:getProviderModelMenu()
  local providers = {
    { id = "anthropic", name = _("Anthropic") },
    { id = "openai", name = _("OpenAI") },
    { id = "deepseek", name = _("DeepSeek") },
    { id = "gemini", name = _("Google Gemini") },
    { id = "ollama", name = _("Ollama") },
  }
  
  local menu_items = {}
  
  -- Create a submenu for each provider
  for i, provider in ipairs(providers) do
    table.insert(menu_items, {
      text = provider.name,
      sub_item_table_func = function()
        -- Regenerate model items each time the submenu is opened
        return self:getProviderModelItems(provider.id, provider.name)
      end,
      checked_func = function()
        return self.settings:readSetting("provider") == provider.id
      end,
    })
  end
  
  return menu_items
end

function AskGPT:getFlatProviderModelMenu()
  local providers = {
    { id = "anthropic", name = _("Anthropic") },
    { id = "openai", name = _("OpenAI") },
    { id = "deepseek", name = _("DeepSeek") },
    { id = "gemini", name = _("Google Gemini") },
    { id = "ollama", name = _("Ollama") },
  }
  
  local current_provider = self.settings:readSetting("provider") or "anthropic"
  local current_model = self.settings:readSetting("model")
  
  local menu_items = {}
  
  -- Create flattened menu showing "Provider: Model" entries
  for idx, provider in ipairs(providers) do
    local provider_models = ModelLists[provider.id] or {}
    
    -- Add separator before each provider group (except first)
    if #menu_items > 0 then
      table.insert(menu_items, { 
        text = "────────────────────",
        enabled = false,
        callback = function() end,
      })
    end
    
    -- Add header for this provider
    table.insert(menu_items, {
      text = provider.name,
      enabled = false,
      bold = true,
    })
    
    -- Add default model option
    table.insert(menu_items, {
      text = _("   Default Model"),
      checked_func = function()
        return self.settings:readSetting("provider") == provider.id and 
               self.settings:readSetting("model") == nil
      end,
      callback = function()
        self.settings:saveSetting("provider", provider.id)
        self.settings:saveSetting("model", nil)
        self.settings:flush()
        self:updateConfigFromSettings()
        UIManager:show(InfoMessage:new{
          text = T(_("Using %1 with default model"), provider.name),
          timeout = 2,
        })
      end,
    })
    
    -- Add specific models
    for model_idx, model_name in ipairs(provider_models) do
      table.insert(menu_items, {
        text = "   " .. model_name,
        checked_func = function()
          return self.settings:readSetting("provider") == provider.id and 
                 self.settings:readSetting("model") == model_name
        end,
        callback = function()
          self.settings:saveSetting("provider", provider.id)
          self.settings:saveSetting("model", model_name)
          self.settings:flush()
          self:updateConfigFromSettings()
          UIManager:show(InfoMessage:new{
            text = T(_("Using %1: %2"), provider.name, model_name),
            timeout = 2,
          })
        end,
      })
    end
    
    -- Add custom model option
    table.insert(menu_items, {
      text = _("   Enter Custom Model..."),
      callback = function()
        self:showCustomModelDialogForProvider(provider.id, provider.name)
      end,
    })
  end
  
  return menu_items
end

function AskGPT:getProviderModelItems(provider_id, provider_name)
  local provider_models = ModelLists[provider_id] or {}
  local model_items = {}
  
  -- Add specific models for this provider
  for idx, model_name in ipairs(provider_models) do
    table.insert(model_items, {
      text = model_name,
      checked_func = function()
        return self.settings:readSetting("provider") == provider_id and 
               self.settings:readSetting("model") == model_name
      end,
      callback = function(touchmenu_instance)
        self.settings:saveSetting("provider", provider_id)
        self.settings:saveSetting("model", model_name)
        self.settings:flush()
        self:updateConfigFromSettings()
        
        UIManager:show(InfoMessage:new{
          text = T(_("Provider set to %1, Model set to %2"), provider_name, model_name),
          timeout = 2,
        })
        
        -- Go back to parent menu to see updated provider checkmark
        if touchmenu_instance then
          touchmenu_instance:onBack()
        end
      end,
    })
  end
  
  -- Add separator
  if #model_items > 0 then
    table.insert(model_items, { text = "----" })
  end
  
  -- Add "Use Default Model" option
  table.insert(model_items, {
    text = _("Use Default Model"),
    checked_func = function()
      return self.settings:readSetting("provider") == provider_id and 
             self.settings:readSetting("model") == nil
    end,
    callback = function(touchmenu_instance)
      self.settings:saveSetting("provider", provider_id)
      self.settings:saveSetting("model", nil)
      self.settings:flush()
      self:updateConfigFromSettings()
      
      UIManager:show(InfoMessage:new{
        text = T(_("Provider set to %1 with default model"), provider_name),
        timeout = 2,
      })
      
      -- Go back to parent menu to see updated provider checkmark
      if touchmenu_instance then
        touchmenu_instance:onBack()
      end
    end,
  })
  
  -- Add "Enter Custom Model" option
  table.insert(model_items, {
    text = _("Enter Custom Model..."),
    callback = function()
      self:showCustomModelDialogForProvider(provider_id, provider_name)
    end,
  })
  
  return model_items
end

function AskGPT:showCustomModelDialogForProvider(provider_id, provider_name)
  local InputDialog = require("ui/widget/inputdialog")
  
  local custom_model_dialog
  custom_model_dialog = InputDialog:new{
    title = T(_("Custom Model for %1"), provider_name),
    input = "",
    input_hint = _("Enter custom model name"),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(custom_model_dialog)
          end,
        },
        {
          text = _("OK"),
          is_enter_default = true,
          callback = function()
            local model = custom_model_dialog:getInputText()
            if model and model ~= "" then
              self.settings:saveSetting("provider", provider_id)
              self.settings:saveSetting("model", model)
              self.settings:flush()
              self:updateConfigFromSettings()
              UIManager:close(custom_model_dialog)
              UIManager:show(InfoMessage:new{
                text = T(_("Provider set to %1, Model set to %2"), provider_name, model),
              })
            end
          end,
        },
      },
    },
  }
  UIManager:show(custom_model_dialog)
  custom_model_dialog:onShowKeyboard()
end

function AskGPT:getProviderConfigMenuItems()
  -- TODO: Implement provider-specific configuration options
  return {
    {
      text = _("Provider configuration coming soon..."),
      callback = function()
        UIManager:show(InfoMessage:new{
          text = _("Provider-specific configuration will be available in a future update."),
        })
      end,
    },
  }
end

function AskGPT:testProviderConnection()
  local InfoMessage = require("ui/widget/infomessage")
  local UIManager = require("ui/uimanager")
  local queryChatGPT = require("gpt_query")
  local MessageHistory = require("message_history")
  
  UIManager:show(InfoMessage:new{
    text = _("Testing connection..."),
    timeout = 2,
  })
  
  -- Create a simple test message
  local test_message_history = MessageHistory:new()
  test_message_history:addUserMessage("Hello, this is a connection test. Please respond with 'Connection successful'.")
  
  -- Get current configuration (global configuration is updated with settings in init)
  local test_config = {
    provider = configuration.provider,
    model = configuration.model,
    temperature = 0.1,
    max_tokens = 50,
    features = {
      debug = configuration.features and configuration.features.debug or false
    }
  }
  
  -- Perform the test query asynchronously
  UIManager:scheduleIn(0.1, function()
    local response = queryChatGPT(test_message_history:getMessages(), test_config)
    
    if response and type(response) == "string" then
      if response:match("^Error:") then
        -- Connection failed
        UIManager:show(InfoMessage:new{
          text = _("Connection test failed:\n") .. response,
          timeout = 5,
        })
      else
        -- Connection successful
        UIManager:show(InfoMessage:new{
          text = string.format(_("Connection test successful!\n\nProvider: %s\nModel: %s\n\nResponse: %s"), 
            test_config.provider, test_config.model or "default", response:sub(1, 100)),
          timeout = 5,
        })
      end
    else
      -- Unexpected response format
      UIManager:show(InfoMessage:new{
        text = _("Connection test failed: Unexpected response format"),
        timeout = 5,
      })
    end
  end)
end

function AskGPT:showPromptsManager()
  local prompts_manager = PromptsManager:new(self)
  prompts_manager:show()
end

function AskGPT:importPrompts()
  UIManager:show(InfoMessage:new{
    text = _("Import prompts feature coming soon..."),
  })
end

function AskGPT:exportPrompts()
  UIManager:show(InfoMessage:new{
    text = _("Export prompts feature coming soon..."),
  })
end

function AskGPT:restoreDefaultPrompts()
  -- Clear custom prompts and disabled prompts
  self.settings:saveSetting("custom_prompts", {})
  self.settings:saveSetting("disabled_prompts", {})
  self.settings:flush()
  
  UIManager:show(InfoMessage:new{
    text = _("Default prompts restored"),
  })
end

function AskGPT:saveSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
  })
end

function AskGPT:loadSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
  })
end

function AskGPT:deleteSettingsProfile()
  UIManager:show(InfoMessage:new{
    text = _("Settings profiles feature coming soon..."),
  })
end

function AskGPT:startGeneralChat()
  -- Same logic as onAssistantGeneralChat
  if not configuration then
    UIManager:show(InfoMessage:new{
      icon = "notice-warning",
      text = _("Configuration not found. Please set up configuration.lua first.")
    })
    return
  end
  
  NetworkMgr:runWhenOnline(function()
    if not updateMessageShown then
      UpdateChecker.checkForUpdates()
      updateMessageShown = true
    end
    -- Make sure we're using the latest configuration
    self:updateConfigFromSettings()
    
    -- Create a temp config with general context flag
    local temp_config = {}
    for k, v in pairs(configuration) do
      if type(v) ~= "table" then
        temp_config[k] = v
      else
        temp_config[k] = {}
        for k2, v2 in pairs(v) do
          temp_config[k][k2] = v2
        end
      end
    end
    temp_config.features = temp_config.features or {}
    temp_config.features.is_general_context = true
    
    -- Show dialog with general context
    showChatGPTDialog(self.ui, nil, temp_config, nil, self)
  end)
end

function AskGPT:showChatHistory()
  -- Load the chat history manager
  local ChatHistoryManager = require("chat_history_manager")
  local chat_history_manager = ChatHistoryManager:new()
  
  -- Get the current document path if a document is open
  local document_path = nil
  if self.ui and self.ui.document and self.ui.document.file then
      document_path = self.ui.document.file
  end
  
  -- Show the chat history browser
  local ChatHistoryDialog = require("chat_history_dialog")
  ChatHistoryDialog:showChatHistoryBrowser(
      self.ui, 
      document_path,
      chat_history_manager, 
      configuration
  )
end

function AskGPT:importSettings()
  UIManager:show(InfoMessage:new{
    text = _("Import settings feature coming soon..."),
  })
end

function AskGPT:exportSettings()
  UIManager:show(InfoMessage:new{
    text = _("Export settings feature coming soon..."),
  })
end

function AskGPT:editConfigurationFile()
  UIManager:show(InfoMessage:new{
    text = _("To edit advanced settings, please modify configuration.lua in the plugin directory."),
  })
end

function AskGPT:checkForUpdates()
  NetworkMgr:runWhenOnline(function()
    UpdateChecker.checkForUpdates(false) -- false = not silent
  end)
end

function AskGPT:showAbout()
  UIManager:show(InfoMessage:new{
    text = _("KOReader Assistant Plugin\nVersion: ") .. 
          (UpdateChecker.getCurrentVersion() or "Unknown") .. 
          "\nProvides AI assistant capabilities via various API providers." ..
          "\n\nGesture Support:\nAssign gestures in Settings → Gesture Manager",
  })
end

-- Event handlers for registering buttons with different FileManager views
function AskGPT:onFileManagerReady(filemanager)
  logger.info("Assistant: onFileManagerReady event received")
  
  -- Register immediately since FileManager should be ready
  self:addFileDialogButtons()
  
  -- Also register with a delay as a fallback
  UIManager:scheduleIn(0.1, function()
    logger.info("Assistant: Late registration of file dialog buttons (onFileManagerReady)")
    self:addFileDialogButtons()
  end)
end

-- Patch FileManager to add our multi-select button
function AskGPT:patchFileManagerForMultiSelect()
  local FileManager = require("apps/filemanager/filemanager")
  local ButtonDialog = require("ui/widget/buttondialog")
  
  if not FileManager or not ButtonDialog then
    logger.warn("Assistant: Could not load required modules for multi-select patching")
    return
  end
  
  -- Store reference to self for the closure
  local assistant_plugin = self
  
  -- Patch ButtonDialog.new to inject our button into multi-select dialogs
  if not ButtonDialog._orig_new_assistant then
    ButtonDialog._orig_new_assistant = ButtonDialog.new
    
    ButtonDialog.new = function(self, o)
      -- Check if this is a FileManager multi-select dialog
      if o and o.buttons and o.title and type(o.title) == "string" and 
         (o.title:find("file.*selected") or o.title:find("No files selected")) and
         FileManager.instance and FileManager.instance.selected_files then
        
        local fm = FileManager.instance
        local select_count = util.tableSize(fm.selected_files)
        local actions_enabled = select_count > 0
        
        if actions_enabled then
          -- Find insertion point (after coverbrowser button if present)
          local insert_position = 7
          for i, row in ipairs(o.buttons) do
            if row and row[1] and row[1].text == _("Refresh cached book information") then
              insert_position = i + 1
              break
            end
          end
          
          -- Create the close callback
          local close_callback = function()
            -- The dialog will be assigned to the variable after construction
            UIManager:scheduleIn(0, function()
              local dialog = UIManager:getTopmostVisibleWidget()
              if dialog then
                UIManager:close(dialog)
              end
              fm:onToggleSelectMode(true)
            end)
          end
          
          -- Add assistant button
          local assistant_button = assistant_plugin:genMultipleAssistantButton(
            close_callback,
            not actions_enabled,
            fm.selected_files
          )
          
          if assistant_button then
            table.insert(o.buttons, insert_position, assistant_button)
            logger.info("Assistant: Added multi-select button to dialog at position " .. insert_position)
          end
        end
      end
      
      -- Call original constructor
      return ButtonDialog._orig_new_assistant(self, o)
    end
    
    logger.info("Assistant: Patched ButtonDialog.new for multi-select support")
  end
end

-- These events don't actually exist in KOReader, but we keep them for future compatibility
function AskGPT:onFileManagerHistoryReady(filemanager_history)
  logger.info("Assistant: onFileManagerHistoryReady event received (deprecated)")
end

function AskGPT:onFileManagerCollectionReady(filemanager_collection)
  logger.info("Assistant: onFileManagerCollectionReady event received (deprecated)")
end

-- Support for FileSearcher (search results) - this event also doesn't exist
function AskGPT:onShowFileSearch()
  logger.info("Assistant: onShowFileSearch event received (deprecated)")
end


-- Legacy event handlers for compatibility
function AskGPT:onFileManagerShow(filemanager)
  logger.info("Assistant: onFileManagerShow event received")
  -- Don't register buttons immediately - let delayed registration handle it
  -- But do register ourselves for multi-select support
  if filemanager then
    filemanager.assistant = self
    logger.info("Assistant: Registered with FileManager for multi-select support")
  end
end

-- Try to catch when file dialogs are about to be shown
function AskGPT:onSetDimensions(dimen)
  -- This event is fired when various UI elements are being set up
  -- Don't register immediately - let delayed registration handle it
  logger.info("Assistant: onSetDimensions event received")
end

function AskGPT:onFileManagerInstance(filemanager)
  logger.info("Assistant: onFileManagerInstance event received")
  -- Don't register immediately - let delayed registration handle it
end

-- Additional event handlers that might help catch FileManager initialization
function AskGPT:onFileManagerSetDimensions()
  logger.info("Assistant: onFileManagerSetDimensions event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:onPathChanged()
  -- This event fires when FileManager changes directory
  -- Don't register immediately - let delayed registration handle it
  logger.info("Assistant: onPathChanged event received")
end

-- Hook into FileSearcher initialization
function AskGPT:onShowFileSearch(searcher)
  logger.info("Assistant: onShowFileSearch event received")
  -- Don't register immediately - let delayed registration handle it
end

-- Hook into Collections/History views
function AskGPT:onShowHistoryMenu()
  logger.info("Assistant: onShowHistoryMenu event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:onShowCollectionMenu()
  logger.info("Assistant: onShowCollectionMenu event received")
  -- Don't register immediately - let delayed registration handle it
end

function AskGPT:migratePromptsV2()
  logger.info("Assistant: Performing one-time prompt migration to v2 format")
  
  -- Check if we have any old configuration that needs migration
  local old_config_path = script_path() .. "configuration.lua"
  local ok, old_config = pcall(dofile, old_config_path)
  
  local migrated = false
  local custom_prompts = self.settings:readSetting("custom_prompts") or {}
  
  -- First check for old format prompts (features.prompts)
  if ok and old_config and old_config.features and old_config.features.prompts then
    -- We have old format prompts that need migration
    logger.info("Assistant: Found old format prompts, migrating to custom_prompts")
    
    -- Migrate each old prompt to custom prompts
    for key, prompt in pairs(old_config.features.prompts) do
      if type(prompt) == "table" and prompt.text then
        -- Create a new custom prompt entry
        local migrated_prompt = {
          text = prompt.text,
          context = "highlight", -- Old prompts were for highlights
          system_prompt = prompt.system_prompt,
          user_prompt = prompt.user_prompt,
          provider = prompt.provider,
          model = prompt.model,
          include_book_context = prompt.include_book_context
        }
        
        -- Fix user_prompt to use template variable if needed
        if migrated_prompt.user_prompt and not migrated_prompt.user_prompt:find("{highlighted_text}") then
          migrated_prompt.user_prompt = migrated_prompt.user_prompt .. "{highlighted_text}"
        end
        
        -- Check if this prompt already exists (by text)
        local exists = false
        for _, existing in ipairs(custom_prompts) do
          if existing.text == migrated_prompt.text then
            exists = true
            break
          end
        end
        
        if not exists then
          table.insert(custom_prompts, migrated_prompt)
          logger.info("Assistant: Migrated prompt: " .. migrated_prompt.text)
          migrated = true
        end
      end
    end
  end
  
  -- Also check for custom_prompts in configuration.lua (since we're moving them to a separate file)
  if ok and old_config and old_config.custom_prompts then
    logger.info("Assistant: Found custom_prompts in configuration.lua, migrating to UI settings")
    
    for _, prompt in ipairs(old_config.custom_prompts) do
      if type(prompt) == "table" and prompt.text then
        -- Check if this prompt already exists (by text)
        local exists = false
        for _, existing in ipairs(custom_prompts) do
          if existing.text == prompt.text then
            exists = true
            break
          end
        end
        
        if not exists then
          table.insert(custom_prompts, prompt)
          logger.info("Assistant: Migrated custom prompt: " .. prompt.text)
          migrated = true
        end
      end
    end
  end
  
  -- Save migrated prompts
  if migrated and #custom_prompts > 0 then
    self.settings:saveSetting("custom_prompts", custom_prompts)
    self.settings:flush()
    logger.info("Assistant: Migration complete, saved " .. #custom_prompts .. " custom prompts")
  else
    logger.info("Assistant: No prompts found to migrate")
  end
end

return AskGPT