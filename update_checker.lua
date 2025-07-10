local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local meta = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local logger = require("logger")

local UpdateChecker = {}

local function parseVersion(versionString)
    -- Parse semantic version like "0.1.0-beta" or "1.0.0"
    local major, minor, patch, prerelease = versionString:match("^(%d+)%.(%d+)%.(%d+)%-?(.*)$")
    if not major then
        return nil
    end
    
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        prerelease = prerelease ~= "" and prerelease or nil,
        original = versionString
    }
end

local function compareVersions(v1, v2)
    -- Returns: -1 if v1 < v2, 0 if v1 == v2, 1 if v1 > v2
    local ver1 = parseVersion(v1)
    local ver2 = parseVersion(v2)
    
    if not ver1 or not ver2 then
        return 0
    end
    
    -- Compare major.minor.patch
    if ver1.major ~= ver2.major then
        return ver1.major < ver2.major and -1 or 1
    end
    if ver1.minor ~= ver2.minor then
        return ver1.minor < ver2.minor and -1 or 1
    end
    if ver1.patch ~= ver2.patch then
        return ver1.patch < ver2.patch and -1 or 1
    end
    
    -- Handle prerelease versions
    -- No prerelease > prerelease (1.0.0 > 1.0.0-beta)
    if not ver1.prerelease and ver2.prerelease then
        return 1
    elseif ver1.prerelease and not ver2.prerelease then
        return -1
    elseif ver1.prerelease and ver2.prerelease then
        -- Compare prerelease strings (beta < rc < release)
        local prereleaseOrder = {
            alpha = 1,
            beta = 2,
            rc = 3,
            release = 4
        }
        
        local pre1Type = ver1.prerelease:match("^(%a+)")
        local pre2Type = ver2.prerelease:match("^(%a+)")
        
        local order1 = prereleaseOrder[pre1Type] or 0
        local order2 = prereleaseOrder[pre2Type] or 0
        
        if order1 ~= order2 then
            return order1 < order2 and -1 or 1
        end
        
        -- If same type, compare full strings
        return ver1.prerelease < ver2.prerelease and -1 or (ver1.prerelease > ver2.prerelease and 1 or 0)
    end
    
    return 0
end

function UpdateChecker.checkForUpdates(silent)
    local response_body = {}
    local request_result, code = http.request {
        url = "https://api.github.com/repos/zeeyado/Assistant/releases/latest",
        headers = {
            ["Accept"] = "application/vnd.github.v3+json",
            ["User-Agent"] = "KOReader-Assistant-Plugin"
        },
        sink = ltn12.sink.table(response_body)
    }
    
    if code == 200 then
        local data = table.concat(response_body)
        local success, parsed_data = pcall(json.decode, data)
        
        if not success then
            logger.err("Failed to parse GitHub API response:", parsed_data)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "Failed to check for updates: Invalid response format",
                    timeout = 3
                })
            end
            return false
        end
        
        local latest_version = parsed_data.tag_name
        if latest_version and latest_version:match("^v") then
            latest_version = latest_version:sub(2) -- Remove 'v' prefix
        end
        
        local current_version = meta.version
        local comparison = compareVersions(current_version, latest_version)
        
        if comparison < 0 then
            -- New version available
            local release_notes = parsed_data.body or "No release notes available."
            local download_url = parsed_data.html_url
            local is_prerelease = parsed_data.prerelease or false
            
            local message = string.format(
                "New %sversion available!\n\nCurrent: %s\nLatest: %s\n\nRelease notes:\n%s\n\nWould you like to visit the release page?",
                is_prerelease and "pre-release " or "",
                current_version,
                latest_version,
                release_notes:sub(1, 500) -- Limit release notes length
            )
            
            UIManager:show(ConfirmBox:new{
                text = message,
                ok_text = "Visit Release Page",
                ok_callback = function()
                    if Device:canOpenLink() then
                        Device:openLink(download_url)
                    else
                        UIManager:show(InfoMessage:new{
                            text = "Please visit:\n" .. download_url,
                            timeout = 10
                        })
                    end
                end,
            })
            
            return true, latest_version
        elseif comparison == 0 then
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "You are running the latest version (" .. current_version .. ")",
                    timeout = 3
                })
            end
            return false
        else
            -- Current version is newer (development version)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = "You are running a development version (" .. current_version .. ")",
                    timeout = 3
                })
            end
            return false
        end
    else
        logger.err("Failed to check for updates. HTTP code:", code)
        if not silent then
            UIManager:show(InfoMessage:new{
                text = "Failed to check for updates. Please check your internet connection.",
                timeout = 3
            })
        end
        return false
    end
end

function UpdateChecker.getCurrentVersion()
    return meta.version
end

function UpdateChecker.checkForUpdatesInBackground()
    -- Check for updates silently in the background
    UpdateChecker.checkForUpdates(true)
end

return UpdateChecker