--[[--
Displays some text in a scrollable view.

@usage
    local chatgptviewer = ChatGPTViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(chatgptviewer)
]]
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local logger = require("logger")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen
local MD = require("apps/filemanager/lib/md")

-- CSS for markdown rendering
local VIEWER_CSS = [[
@page {
    margin: 0;
    font-family: 'Noto Sans';
}

body {
    margin: 0;
    line-height: 1.3;
    text-align: justify;
    padding: 0;
}

blockquote {
    margin: 0.5em 0;
    padding-left: 1em;
    border-left: 3px solid #ccc;
}

code {
    background-color: #f0f0f0;
    padding: 0.1em 0.3em;
    border-radius: 3px;
    font-family: monospace;
    font-size: 0.9em;
}

pre {
    background-color: #f0f0f0;
    padding: 0.5em;
    border-radius: 3px;
    overflow-x: auto;
    margin: 0.5em 0;
}

pre code {
    background-color: transparent;
    padding: 0;
}

ol, ul {
    margin: 0.5em 0;
    padding-left: 1.5em;
}

h1, h2, h3, h4, h5, h6 {
    margin: 0.5em 0 0.3em 0;
    font-weight: bold;
}

h1 { font-size: 1.5em; }
h2 { font-size: 1.3em; }
h3 { font-size: 1.1em; }

p {
    margin: 0.5em 0;
}

table {
    border-collapse: collapse;
    margin: 0.5em 0;
}

td, th {
    border: 1px solid #ccc;
    padding: 0.3em 0.5em;
}

th {
    background-color: #f0f0f0;
    font-weight: bold;
}
]]

local ChatGPTViewer = InputContainer:extend {
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,
  -- See TextBoxWidget for details about these options
  -- We default to justified and auto_para_direction to adapt
  -- to any kind of text we are given (book descriptions,
  -- bookmarks' text, translation results...).
  -- When used to display more technical text (HTML, CSS,
  -- application logs...), it's best to reset them to false.
  alignment = "left",
  justified = true,
  render_markdown = true, -- Convert markdown to HTML for display
  markdown_font_size = 20, -- Font size for markdown rendering
  lang = nil,
  para_direction_rtl = nil,
  auto_para_direction = true,
  alignment_strict = false,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_face = Font:getFace("x_smallinfofont"),
  fgcolor = Blitbuffer.COLOR_BLACK,
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil,
  save_callback = nil, -- New callback for saving chat
  export_callback = nil, -- New callback for exporting chat
  scroll_to_bottom = false, -- Whether to scroll to bottom on show
}

function ChatGPTViewer:init()
  -- calculate window dimension
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  self.width = self.width or Screen:getWidth() - Screen:scaleBySize(30)
  self.height = self.height or Screen:getHeight() - Screen:scaleBySize(30)

  self._find_next = false
  self._find_next_button = false
  self._old_virtual_line_num = 1

  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  if Device:isTouchDevice() then
    local range = Geom:new {
      x = 0, y = 0,
      w = Screen:getWidth(),
      h = Screen:getHeight(),
    }
    self.ges_events = {
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- Allow selection of one or more words (see textboxwidget.lua):
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- callback function when HoldReleaseText is handled as args
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  local titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = self.title,
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback
  local prev_at_top = false -- Buttons were created enabled
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()
      else
        button:disable()
      end
      button:refresh()
    end
  end
  self._buttons_scroll_callback = function(low, high)
    if prev_at_top and low > 0 then
      button_update("top", true)
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)
      prev_at_top = true
    end
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)
      prev_at_bottom = true
    end
  end

  -- buttons - organize into multiple rows for better layout
  local default_buttons = {
    -- First row: Main actions
    {
      {
        text = _("Reply"),
        id = "ask_another_question",
        callback = function()
          self:askAnotherQuestion()
        end,
      },
      {
        text = _("Save"),
        id = "save_chat",
        callback = function()
          if self.save_callback then
            self.save_callback()
          else
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
              text = _("Save function not available"),
              timeout = 2,
            })
          end
        end,
        hold_callback = self.default_hold_callback,
      },
      {
        text = _("Export"),
        id = "export_chat",
        callback = function()
          if self.export_callback then
            self.export_callback()
          else
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{
              text = _("Export function not available"),
              timeout = 2,
            })
          end
        end,
        hold_callback = self.default_hold_callback,
      },
    },
    -- Second row: Controls and toggles
    {
      {
        text_func = function()
          return self.render_markdown and "MD" or "Text"
        end,
        id = "toggle_markdown",
        callback = function()
          self:toggleMarkdown()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("Toggle between markdown and plain text display"),
            timeout = 2,
          })
        end,
      },
      {
        text_func = function()
          return self.debug_mode and "Debug ON" or "Debug OFF"
        end,
        id = "toggle_debug",
        callback = function()
          self:toggleDebugMode()
        end,
        hold_callback = function()
          UIManager:show(Notification:new{
            text = _("Toggle debug mode for detailed message info"),
            timeout = 2,
          })
        end,
      },
      {
        text = "⇱",
        id = "top",
        callback = function()
          if self.render_markdown then
            -- If rendering in a ScrollHtmlWidget, use scrollToRatio
            self.scroll_text_w:scrollToRatio(0)
          else
            self.scroll_text_w:scrollToTop()
          end
        end,
        hold_callback = self.default_hold_callback,
        allow_hold_when_disabled = true,
      },
      {
        text = "⇲",
        id = "bottom",
        callback = function()
          if self.render_markdown then
            -- If rendering in a ScrollHtmlWidget, use scrollToRatio
            self.scroll_text_w:scrollToRatio(1)
          else
            self.scroll_text_w:scrollToBottom()
          end
        end,
        hold_callback = self.default_hold_callback,
        allow_hold_when_disabled = true,
      },
      {
        text = _("Close"),
        callback = function()
          self:onClose()
        end,
        hold_callback = self.default_hold_callback,
      },
    },
  }
  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    -- Add both rows
    for _, row in ipairs(default_buttons) do
      table.insert(buttons, row)
    end
  end
  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }

  local textw_height = self.height - titlebar:getHeight() - self.button_table:getSize().h

  -- Load configuration and check if markdown rendering is enabled
  self.configuration = {}
  local ok, loaded_config = pcall(dofile, require("datastorage"):getSettingsDir() .. "/assistant.koplugin/configuration.lua")
  if ok and loaded_config then
    self.configuration = loaded_config
  end
  
  -- Use configuration setting if present, otherwise use instance setting
  if self.configuration.features and self.configuration.features.render_markdown ~= nil then
    self.render_markdown = self.configuration.features.render_markdown
  end
  if self.configuration.features and self.configuration.features.markdown_font_size then
    self.markdown_font_size = self.configuration.features.markdown_font_size
  end
  if self.configuration.features and self.configuration.features.debug ~= nil then
    self.debug_mode = self.configuration.features.debug
  end

  if self.render_markdown then
    -- Convert Markdown to HTML and render in a ScrollHtmlWidget
    local html_body, err = MD(self.text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      -- Fallback to plain text if HTML generation fails
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = VIEWER_CSS,
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
    }
  else
    -- If not rendering Markdown, use the text as is
    self.scroll_text_w = ScrollTextWidget:new {
      text = self.text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
    }
  end
  self.textw = FrameContainer:new {
    padding = self.text_padding,
    margin = self.text_margin,
    bordersize = 0,
    self.scroll_text_w
  }

  self.frame = FrameContainer:new {
    radius = Size.radius.window,
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    VerticalGroup:new {
      titlebar,
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.textw:getSize().h,
        },
        self.textw,
      },
      CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = self.button_table:getSize().h,
        },
        self.button_table,
      }
    }
  }
  self.movable = MovableContainer:new {
    -- We'll handle these events ourselves, and call appropriate
    -- MovableContainer's methods when we didn't process the event
    ignore_events = {
      -- These have effects over the text widget, and may
      -- or may not be processed by it
      "swipe", "hold", "hold_release", "hold_pan",
      -- These do not have direct effect over the text widget,
      -- but may happen while selecting text: we need to check
      -- a few things before forwarding them
      "touch", "pan", "pan_release",
    },
    self.frame,
  }
  self[1] = WidgetContainer:new {
    align = self.align,
    dimen = self.region,
    self.movable,
  }
end

function ChatGPTViewer:askAnotherQuestion()
  -- Store reference to current instance to use in callbacks
  local current_instance = self
  
  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Reply"),
    input = "",
    input_type = "text",
    description = _("Enter your reply."),
    input_height = 6,
    allow_newline = true,
    input_multiline = true,
    text_height = 300,  -- Set explicit height for the text input widget
    width = Screen:getWidth() * 0.9,
    text_widget_width = Screen:getWidth() * 0.8,
    text_widget_height = Screen:getHeight() * 0.3,
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Send"),
          is_enter_default = true,
          callback = function()
            local input_text = input_dialog:getInputText()
            UIManager:close(input_dialog)
            
            if input_text and input_text ~= "" then
              -- Store reference to onAskQuestion before we potentially close this instance
              local onAskQuestionFn = current_instance.onAskQuestion
              
              -- Check if we have a valid callback
              if onAskQuestionFn then
                -- Properly pass self as first argument
                onAskQuestionFn(current_instance, input_text)
              end
            end
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function ChatGPTViewer:onCloseWidget()
  UIManager:setDirty(nil, function()
    return "partial", self.frame.dimen
  end)
end

function ChatGPTViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  
  -- Schedule scroll to bottom if requested
  if self.scroll_to_bottom then
    UIManager:scheduleIn(0.1, function()
      if self.scroll_text_w then
        if self.render_markdown then
          self.scroll_text_w:scrollToRatio(1)
        else
          self.scroll_text_w:scrollToBottom()
        end
      end
    end)
  end
  
  return true
end

function ChatGPTViewer:onTapClose(arg, ges_ev)
  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
  end
  return true
end

function ChatGPTViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function ChatGPTViewer:onClose()
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

function ChatGPTViewer:onSwipe(arg, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)
      return true
    else
      -- trigger a full-screen HQ flashing refresh
      UIManager:setDirty(nil, "full")
      -- a long diagonal swipe may also be used for taking a screenshot,
      -- so let it propagate
      return false
    end
  end
  -- Let our MovableContainer handle swipe outside of text
  return self.movable:onMovableSwipe(arg, ges)
end

-- The following handlers are similar to the ones in DictQuickLookup:
-- we just forward to our MoveableContainer the events that our
-- TextBoxWidget has not handled with text selection.
function ChatGPTViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHold(_, ges)
end

function ChatGPTViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function ChatGPTViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function ChatGPTViewer:onForwardingTouch(arg, ges)
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function ChatGPTViewer:onForwardingPan(arg, ges)
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function ChatGPTViewer:onForwardingPanRelease(arg, ges)
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

function ChatGPTViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  if Device:hasClipboard() then
    Device.input.setClipboardText(text)
    UIManager:show(Notification:new {
      text = start_idx == end_idx and _("Word copied to clipboard.")
          or _("Selection copied to clipboard."),
    })
  end
end

function ChatGPTViewer:update(new_text, scroll_to_bottom)
  self.text = new_text
  
  -- Default to true for backward compatibility
  if scroll_to_bottom == nil then
    scroll_to_bottom = true
  end
  
  if self.render_markdown then
    -- Convert Markdown to HTML and update the ScrollHtmlWidget
    local html_body, err = MD(new_text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (new_text or "Missing text.") .. "</pre>"
    end
    
    -- Recreate the ScrollHtmlWidget with new content
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = VIEWER_CSS,
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = self.textw:getSize().h - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
    }
    
    -- Update the frame container with the new scroll widget
    self.textw:clear()
    self.textw[1] = self.scroll_text_w
    
    -- Only scroll to bottom if requested
    if scroll_to_bottom then
      UIManager:scheduleIn(0.1, function()
        if self.scroll_text_w then
          self.scroll_text_w:scrollToRatio(1)
        end
      end)
    end
  else
    -- For plain text, recreate the widget with new text
    self.scroll_text_w = ScrollTextWidget:new {
      text = new_text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = self.textw:getSize().h - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
    }
    
    -- Update the frame container with the new scroll widget
    self.textw:clear()
    self.textw[1] = self.scroll_text_w
    
    -- Only scroll to bottom if requested
    if scroll_to_bottom then
      UIManager:scheduleIn(0.1, function()
        if self.scroll_text_w and type(self.scroll_text_w.scrollToBottom) == "function" then
          self.scroll_text_w:scrollToBottom()
        end
      end)
    end
  end
  
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

-- Add method to update the title
function ChatGPTViewer:setTitle(new_title)
  self.title = new_title
  -- Update the titlebar title - need to find it first
  if self.movable and self.movable.vertical_group then
    local vg = self.movable.vertical_group
    for _, widget in ipairs(vg) do
      if widget.title_bar and widget.title_bar.setTitle then
        widget.title_bar:setTitle(new_title)
        UIManager:setDirty(self, function()
          return "ui", widget.title_bar.dimen
        end)
        break
      end
    end
  end
  -- Call update_title_callback if provided
  if self.update_title_callback then
    self.update_title_callback(self)
  end
end

function ChatGPTViewer:resetLayout()
  -- Implementation of resetLayout method
end

function ChatGPTViewer:toggleMarkdown()
  -- Toggle markdown rendering
  self.render_markdown = not self.render_markdown
  
  -- Update configuration
  if self.configuration.features then
    self.configuration.features.render_markdown = self.render_markdown
  end
  
  -- Save to settings if available
  if self.settings_callback then
    self.settings_callback("features.render_markdown", self.render_markdown)
  end
  
  -- Rebuild the scroll widget with new rendering mode
  local textw_height = self.textw:getSize().h
  
  if self.render_markdown then
    -- Convert to markdown
    local html_body, err = MD(self.text, {})
    if err then
      logger.warn("ChatGPTViewer: could not generate HTML", err)
      html_body = "<pre>" .. (self.text or "Missing text.") .. "</pre>"
    end
    self.scroll_text_w = ScrollHtmlWidget:new {
      html_body = html_body,
      css = VIEWER_CSS,
      default_font_size = Screen:scaleBySize(self.markdown_font_size),
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
    }
  else
    -- Convert to plain text
    self.scroll_text_w = ScrollTextWidget:new {
      text = self.text,
      face = self.text_face,
      fgcolor = self.fgcolor,
      width = self.width - 2 * self.text_padding - 2 * self.text_margin,
      height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
      dialog = self,
      alignment = self.alignment,
      justified = self.justified,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
      scroll_callback = self._buttons_scroll_callback,
    }
  end
  
  -- Update the frame container
  self.textw:clear()
  self.textw[1] = self.scroll_text_w
  
  -- Update button text
  local button = self.button_table:getButtonById("toggle_markdown")
  if button then
    button:setText(self.render_markdown and "MD" or "Text", button.width)
  end
  
  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

function ChatGPTViewer:toggleDebugMode()
  -- Toggle debug mode
  self.debug_mode = not self.debug_mode
  
  -- Update configuration
  if self.configuration.features then
    self.configuration.features.debug = self.debug_mode
  end
  
  -- Save to settings if available
  if self.settings_callback then
    self.settings_callback("features.debug", self.debug_mode)
  end
  
  -- If debug mode was toggled and we have update_debug_callback, call it
  if self.update_debug_callback then
    self.update_debug_callback(self.debug_mode)
  end
  
  -- Rebuild the display with debug info shown/hidden
  if self.original_history then
    -- Create a temporary config with updated debug mode
    local temp_config = {
      features = {
        debug = self.debug_mode,
        hide_highlighted_text = self.configuration.features and self.configuration.features.hide_highlighted_text,
        hide_long_highlights = self.configuration.features and self.configuration.features.hide_long_highlights,
        long_highlight_threshold = self.configuration.features and self.configuration.features.long_highlight_threshold,
        is_file_browser_context = self.configuration.features and self.configuration.features.is_file_browser_context,
      }
    }
    
    -- Recreate the text with new debug setting
    local new_text = self.original_history:createResultText(self.original_highlighted_text or "", temp_config)
    self:update(new_text, false)  -- false = don't scroll to bottom
  end
  
  -- Update button text
  local button = self.button_table:getButtonById("toggle_debug")
  if button then
    button:setText(self.debug_mode and "Debug ON" or "Debug OFF", button.width)
  end
  
  -- Show notification
  UIManager:show(Notification:new{
    text = self.debug_mode and _("Debug mode enabled - showing message details") or _("Debug mode disabled"),
    timeout = 2,
  })
  
  -- Refresh display
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)
end

return ChatGPTViewer
