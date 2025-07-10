local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local _ = require("gettext")

local ChatHistoryManager = {}

-- Constants
ChatHistoryManager.CHAT_DIR = DataStorage:getDataDir() .. "/assistant_chats"

function ChatHistoryManager:new()
    local manager = {}
    setmetatable(manager, self)
    self.__index = self
    
    -- Ensure chat directory exists
    self:ensureChatDirectory()
    
    return manager
end

-- Make sure the chat storage directory exists
function ChatHistoryManager:ensureChatDirectory()
    local dir = self.CHAT_DIR
    if not lfs.attributes(dir, "mode") then
        logger.info("Creating chat history directory: " .. dir)
        lfs.mkdir(dir)
    end
end

-- Get document hash for consistent filename generation
function ChatHistoryManager:getDocumentHash(document_path)
    if not document_path then return nil end
    return md5(document_path)
end

-- Get document path from hash
function ChatHistoryManager:getDocumentPathFromHash(doc_hash)
    -- Look through the document directories
    local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
    if lfs.attributes(doc_dir, "mode") then
        -- Try to find a chat file to extract document_path
        for filename in lfs.dir(doc_dir) do
            if filename ~= "." and filename ~= ".." then
                local chat_path = doc_dir .. "/" .. filename
                local chat = self:loadChat(chat_path)
                if chat and chat.document_path then
                    return chat.document_path
                end
            end
        end
    end
    return nil
end

-- Get a list of all documents that have chats
function ChatHistoryManager:getAllDocuments()
    local documents = {}
    
    -- Loop through all subdirectories in the chat directory
    if lfs.attributes(self.CHAT_DIR, "mode") then
        for doc_hash in lfs.dir(self.CHAT_DIR) do
            -- Skip . and ..
            if doc_hash ~= "." and doc_hash ~= ".." then
                local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
                -- Check if it's a directory
                if lfs.attributes(doc_dir, "mode") == "directory" then
                    -- Check if it contains any chat files
                    local has_chats = false
                    for filename in lfs.dir(doc_dir) do
                        -- Only count actual chat files, not backup files
                        if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                            has_chats = true
                            break
                        end
                    end
                    
                    if has_chats then
                        -- Get the document path from one of the chats
                        local document_path = self:getDocumentPathFromHash(doc_hash)
                        if document_path then
                            -- Handle special case for general context chats
                            local document_title, book_author
                            if document_path == "__GENERAL_CHATS__" then
                                document_title = _("General AI Chats")
                            else
                                -- Try to get book metadata from one of the chats
                                local book_title_found = nil
                                local book_author_found = nil
                                logger.info("ChatHistoryManager: Looking for metadata in " .. doc_dir)
                                for filename in lfs.dir(doc_dir) do
                                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                                        local chat_path = doc_dir .. "/" .. filename
                                        local chat = self:loadChat(chat_path)
                                        if chat then
                                            logger.info("ChatHistoryManager: Loaded chat - book_title: " .. (chat.book_title or "nil") .. ", book_author: " .. (chat.book_author or "nil"))
                                            if chat.book_title or chat.book_author then
                                                book_title_found = chat.book_title
                                                book_author_found = chat.book_author
                                                break
                                            end
                                        end
                                    end
                                end
                                
                                -- Use book metadata if available, otherwise fall back to filename
                                if book_title_found then
                                    document_title = book_title_found
                                    book_author = book_author_found
                                    logger.info("ChatHistoryManager: Using metadata - title: " .. document_title .. ", author: " .. (book_author or "nil"))
                                else
                                    -- Get the document title (just the filename without path)
                                    document_title = document_path:match("([^/]+)$") or document_path
                                    logger.info("ChatHistoryManager: No metadata found, using filename: " .. document_title)
                                end
                            end
                            
                            table.insert(documents, {
                                hash = doc_hash,
                                path = document_path,
                                title = document_title,
                                author = book_author
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- Sort: General AI Chats first, then alphabetically by title
    table.sort(documents, function(a, b) 
        -- General chats always come first
        if a.path == "__GENERAL_CHATS__" then
            return true
        elseif b.path == "__GENERAL_CHATS__" then
            return false
        else
            return a.title < b.title
        end
    end)
    
    return documents
end

-- Get document-specific chat directory
function ChatHistoryManager:getDocumentChatDir(document_path)
    local doc_hash = self:getDocumentHash(document_path)
    if not doc_hash then return nil end
    
    local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
    if not lfs.attributes(doc_dir, "mode") then
        lfs.mkdir(doc_dir)
    end
    
    return doc_dir
end

-- Generate a unique ID for a new chat
function ChatHistoryManager:generateChatId()
    return os.time() .. "_" .. math.random(1000, 9999)
end

-- Save a chat session
function ChatHistoryManager:saveChat(document_path, chat_title, message_history, metadata)
    if not document_path or not message_history then
        logger.warn("Cannot save chat: missing document path or message history")
        return false
    end
    
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then
        logger.warn("Cannot create document directory for chat history")
        return false
    end
    
    -- Generate a chat ID if not provided in metadata
    local chat_id = (metadata and metadata.id) or self:generateChatId()
    
    -- Create chat data structure
    local chat_data = {
        id = chat_id,
        title = chat_title or "Conversation",
        document_path = document_path,
        timestamp = os.time(),
        messages = message_history:getMessages(),
        model = message_history:getModel(),
        metadata = metadata or {},
        -- Store book metadata at top level for easier access
        book_title = metadata and metadata.book_title or nil,
        book_author = metadata and metadata.book_author or nil,
        -- Store prompt action for continued chats
        prompt_action = message_history.prompt_action or nil
    }
    
    -- Check if this is an update to an existing chat
    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
    local existing_chat = nil
    if lfs.attributes(chat_path, "mode") then
        logger.info("Updating existing chat: " .. chat_id)
        existing_chat = self:loadChat(chat_path)
        
        -- Remove any old backup file that might exist
        local backup_path = chat_path .. ".old"
        if lfs.attributes(backup_path, "mode") then
            os.remove(backup_path)
        end
        
        -- Rename the current file to .old as a backup
        os.rename(chat_path, backup_path)
    end
    
    -- Save to file
    local ok, err = pcall(function()
        local settings = LuaSettings:open(chat_path)
        settings:saveSetting("chat", chat_data)
        settings:flush()
    end)
    
    if not ok then
        logger.warn("Failed to save chat history: " .. (err or "unknown error"))
        -- If we failed to save and had renamed the original file, try to restore it
        if existing_chat then
            os.rename(chat_path .. ".old", chat_path)
        end
        return false
    end
    
    logger.info("Saved chat history: " .. chat_id .. " for document: " .. document_path)
    return chat_id
end

-- Get all chats for a document
function ChatHistoryManager:getChatsForDocument(document_path)
    if not document_path then 
        logger.warn("Cannot get chats: document_path is nil")
        return {} 
    end
    
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir or not lfs.attributes(doc_dir, "mode") then
        logger.info("No chat directory found for document: " .. document_path)
        return {}
    end
    
    local chats = {}
    for filename in lfs.dir(doc_dir) do
        -- Skip . and .. and backup files ending with .old
        if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
            local chat_path = doc_dir .. "/" .. filename
            logger.info("Loading chat file: " .. chat_path)
            local chat = self:loadChat(chat_path)
            if chat then
                logger.info("Loaded chat: " .. (chat.id or "unknown") .. " - " .. (chat.title or "Untitled"))
                table.insert(chats, chat)
            end
        end
    end
    
    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b) 
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    logger.info("Found " .. #chats .. " chats for document: " .. document_path)
    return chats
end

-- Load a chat from file
function ChatHistoryManager:loadChat(chat_path)
    local ok, settings = pcall(LuaSettings.open, LuaSettings, chat_path)
    if not ok or not settings then
        logger.warn("Failed to open chat file: " .. chat_path)
        return nil
    end
    
    local chat_data = settings:readSetting("chat")
    if not chat_data then
        logger.warn("No chat data found in file: " .. chat_path)
        return nil
    end
    
    -- Validate required fields
    if not chat_data.id then
        logger.warn("Chat missing ID in file: " .. chat_path)
        chat_data.id = string.gsub(chat_path, "^.*/([^/]+)%.lua$", "%1")
    end
    
    if not chat_data.messages or #chat_data.messages == 0 then
        logger.warn("Chat has no messages in file: " .. chat_path)
    end
    
    return chat_data
end

-- Get a specific chat by ID
function ChatHistoryManager:getChatById(document_path, chat_id)
    if not document_path or not chat_id then return nil end
    
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then return nil end
    
    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
    return self:loadChat(chat_path)
end

-- Delete a chat
function ChatHistoryManager:deleteChat(document_path, chat_id)
    if not document_path or not chat_id then return false end
    
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then return false end
    
    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
    if lfs.attributes(chat_path, "mode") then
        os.remove(chat_path)
        logger.info("Deleted chat: " .. chat_id)
        return true
    end
    
    return false
end

-- Rename a chat 
function ChatHistoryManager:renameChat(document_path, chat_id, new_title)
    if not document_path or not chat_id or not new_title then
        logger.warn("Cannot rename chat: missing document path, chat ID, or new title")
        return false
    end
    
    -- Load the chat
    local chat = self:getChatById(document_path, chat_id)
    if not chat then
        logger.warn("Cannot rename chat: chat not found")
        return false
    end
    
    -- Update the title
    chat.title = new_title
    
    -- Save the chat back to the file
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then return false end
    
    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
    
    -- Create backup
    local backup_path = chat_path .. ".old"
    if lfs.attributes(backup_path, "mode") then
        os.remove(backup_path)
    end
    
    -- Rename the current file to .old as a backup
    os.rename(chat_path, backup_path)
    
    -- Save updated chat
    local ok, err = pcall(function()
        local settings = LuaSettings:open(chat_path)
        settings:saveSetting("chat", chat)
        settings:flush()
    end)
    
    if not ok then
        logger.warn("Failed to save renamed chat: " .. (err or "unknown error"))
        -- Restore backup on failure
        os.rename(backup_path, chat_path)
        return false
    end
    
    logger.info("Renamed chat: " .. chat_id .. " to: " .. new_title)
    return true
end

-- Export chat to text format
function ChatHistoryManager:exportChatAsText(document_path, chat_id)
    local chat = self:getChatById(document_path, chat_id)
    if not chat then return nil end
    
    local result = {}
    table.insert(result, "Chat: " .. chat.title)
    table.insert(result, "Date: " .. os.date("%Y-%m-%d %H:%M", chat.timestamp))
    table.insert(result, "Document: " .. chat.document_path)
    table.insert(result, "Model: " .. (chat.model or "Unknown"))
    table.insert(result, "")
    
    -- Format messages
    for _, msg in ipairs(chat.messages) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content
        
        -- Skip context messages in export by default
        if not msg.is_context then
            table.insert(result, role .. ": " .. content)
            table.insert(result, "")
        end
    end
    
    return table.concat(result, "\n")
end

-- Export chat to markdown format
function ChatHistoryManager:exportChatAsMarkdown(document_path, chat_id)
    local chat = self:getChatById(document_path, chat_id)
    if not chat then return nil end
    
    local result = {}
    table.insert(result, "# " .. chat.title)
    table.insert(result, "**Date:** " .. os.date("%Y-%m-%d %H:%M", chat.timestamp))
    table.insert(result, "**Document:** " .. chat.document_path)
    table.insert(result, "**Model:** " .. (chat.model or "Unknown"))
    table.insert(result, "")
    
    -- Format messages
    for _, msg in ipairs(chat.messages) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content
        
        -- Skip context messages in export by default
        if not msg.is_context then
            table.insert(result, "### " .. role)
            table.insert(result, content)
            table.insert(result, "")
        end
    end
    
    return table.concat(result, "\n")
end

-- Get the most recently saved chat across all documents
function ChatHistoryManager:getMostRecentChat()
    local most_recent_chat = nil
    local most_recent_timestamp = 0
    local most_recent_doc_path = nil
    
    -- Loop through all document directories
    if lfs.attributes(self.CHAT_DIR, "mode") then
        for doc_hash in lfs.dir(self.CHAT_DIR) do
            if doc_hash ~= "." and doc_hash ~= ".." then
                local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
                if lfs.attributes(doc_dir, "mode") == "directory" then
                    -- Get chats from this document directory
                    for filename in lfs.dir(doc_dir) do
                        if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                            local chat_path = doc_dir .. "/" .. filename
                            local chat = self:loadChat(chat_path)
                            -- Validate chat has actual content
                            if chat and chat.timestamp and chat.timestamp > 0 and 
                               chat.messages and #chat.messages > 0 and
                               chat.timestamp > most_recent_timestamp then
                                logger.info("Found valid chat: " .. (chat.title or "Untitled") .. 
                                           " with timestamp: " .. chat.timestamp)
                                most_recent_chat = chat
                                most_recent_timestamp = chat.timestamp
                                -- Get document path from the chat itself
                                most_recent_doc_path = chat.document_path
                            end
                        end
                    end
                end
            end
        end
    end
    
    if most_recent_chat and most_recent_doc_path then
        return most_recent_chat, most_recent_doc_path
    end
    
    return nil, nil
end

return ChatHistoryManager 