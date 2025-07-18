# KOReader Assistant Plugin

A powerful AI assistant integrated into KOReader.

You can:

- Have general chats (no context)
- Select books and chat about them (using metadata lke title, author, etc)
- Use and create custom actions to compare books, find common themes, etc
- Hihglight text in a book and have it explained, or chat about it, etc
- Save and continue chats 
- Use different AI models (for speed/depth, etc)
- Map functions to gestures and pop up menus for quick actions
- Much more using custom prompts/actions

A wiki will be made for creating custom prompts and actions, and other advanced configuration and usage. 

Originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt). See Credits and history at the bottom of this readme

This plugin was made for personal use and made public in case it is useful. Many functions are still under development, and many are untested. More providers will be added shortly. feel free to open a feature request or issue, or start a discussion.

NB: Gemini and Deepseek have not been thorougly tested for response format. Anthropic and OpenAi have been tested well.

## Quick Minimal Setup

**Get started in 3 simple steps:**

1. **Install the plugin**

Download: (Code (at top right of this page) -> Download ZIP. 

or Clone: `git clone https://github.com/zeeyado/assistant.koplugin`

or Download latest release (not yet available)

Rename and place in your KOReader plugins directory:

   ```
   # Kobo/Kindle: /mnt/onboard/.adds/koreader/plugins/assistant.koplugin/
   # Android: /sdcard/koreader/plugins/assistant.koplugin/
   # macOS: ~/Library/Application Support/koreader/plugins/assistant.koplugin/
   ```


2. **Add your API key(s)**

Copy the sample file `apikeys.lua.sample` and rename to `apikeys.lua`

Add at least one API key  
 
3. **Restart KOReader** - You're ready to go! Set your desired provider and model in the settings UI (Tools -> page 2 -> Assistant (under "More tools")

### Minimum Requirements

- KOReader version 2023.04 or newer
- At least one API key from: [Anthropic](https://console.anthropic.com/), [OpenAI](https://platform.openai.com/), [DeepSeek](https://platform.deepseek.com/), [Google](https://aistudio.google.com/) (more providers are being added)

## HIGHLY Recommended Initial Setup

### 1. Configure Gestures for Quick Access

**Basic one time steps ease of use**

Examples (my usage preference; you can use whichever gestures you like):

**In Reader View (while reading) and in File browser:**

- Go to Settings → Gesture Manager → Tap corner → Bottom left
- General → (add all Assistant actions -- Chat history, Continue last chat, Chat about book, etc)
- Select "Show as QuickMenu"
-

You have to do this for both Reader view and File browser. This will give you an easy to access Assistant menu.

You can also assign any gesture to any action as you see fit.

### 2. Enable/disable prompts and create custom actions

- Go to Asstant settings -> Prompts & Responses -> Manage prompts
- Enable/disable the builtin prompts
- Create you own custom prompts in custom_prompts.lua


### 3. Getting Started Tips

- **Well-formatted metadata** enhances AI responses - use e.g Calibre or Zotero to ensure your books and papers have proper titles, authors, and ISBNs
- **Adjust highlight settings** - Set shorter tap duration for single words in Settings → Taps and Gestures
- **Choose your model wisely** - Fast models for quick queries, powerful models (e.g. Claude Sonnet 4) for complex analysis (you can create custom prompts using specific models to override the default for that prompt)


## Feature Overview

### Core Features

**In-Book Assistant**

- **Highlight & Ask**: Select any text and get instant explanations, translations, or summaries
- **Context-Aware**: AI understands what book you're reading and provides relevant responses
- **Quick Translate**: One-tap translation to your preferred language
- **Custom Prompts**: Create specialized prompts/actions for your reading needs

**File Browser Integration**

- **Book Analysis**: Long-press any book to get summaries, reviews, or reading time estimates
- **Multi-Book Comparison**: Select multiple books to compare themes, find reading order, or analyze your collection
- **Author Information**: Get background on authors and historical context
- **Custom Prompts**: Create specialized prompts/actions

**General Chat**

- **No Context Required**: Start AI conversations without selecting text or books -- just have a regular Chat with the model of your choice
- **Brainstorming Mode**: Creative writing assistance and idea generation
- **Code Help**: Programming assistance with syntax highlighting

**Advanced Features**

- **Chat History**: Save, continue, and export conversations (auto save available in settings)
- **Markdown Rendering**: Beautiful formatting with adjustable font sizes (planned)
- **Debug Mode**: See exactly what's sent to the AI to debug and improve your prompts
- **Auto-Update**: Keep the plugin current with built-in update checking (planned)
- **Multiple Providers**: Switch between AI providers on the fly (better UI implementation planned)
- **Prompt management**: enable/disable built in and custom prompts in the UI (so you dont have to delete them)
- **Profile for different tasks:** (planned feature). Have different sets of prompts/actions for different uses (e.g. Regular book reading vs Academic reading vs Specific case study, etc

### Unique Capabilities

- **4 Context Modes**: Different behaviors for highlights, single books, multiple books, and general chat, each with its own set of prompts/actions
- **Schema-Driven Settings**: All prompts and settings manageable through the UI
- **Gesture Support**: Assignable actions for quick access (Quick menu, Continue last chat, etc.)
- **Provider Flexibility**: Use different models for different tasks

## Configuration

### Basic Configuration (UI-Based)

Access all settings via **Tools → Assistant → Settings**:

1. **AI Provider & Model**

   - Select your provider (Anthropic, OpenAI, etc.)
   - Choose a model or enter custom model names
   - Test connection to verify setup
2. **Display Options**

   - Toggle markdown rendering
   - Adjust font size (14-30)
   - Configure highlight display
3. **Prompts Management**

   - Enable/disable built-in prompts
   - Create custom prompts
   - Import/export prompt collections

### Advanced Configuration

For power users, three configuration files offer deep customization:

#### 1. `apikeys.lua` (Required)

```lua
return {
    anthropic = "sk-ant-...",    -- Claude API
    openai = "sk-...",           -- GPT API
    deepseek = "sk-...",         -- DeepSeek API
    gemini = "...",              -- Gemini API
    ollama = "",                 -- Usually empty for local
}
```

#### 2. `custom_prompts.lua` (Optional)

Create specialized prompts for your workflow:

```lua
return {
    {
        text = "Grammar Check",
        context = "highlight",
        user_prompt = "Check grammar in: {highlighted_text}"
    },
    {
        text = "Book Club Questions",
        context = "book",
        user_prompt = "Generate discussion questions for {title}"
    }
}
```

#### 3. `configuration.lua` (Optional)

Override defaults and fine-tune behavior:

```lua
return {
    provider = "anthropic",
    model = "claude-3-5-sonnet-20241022",
    features = {
        render_markdown = true,
        auto_save_chats = true,
        debug = false
    }
}
```

### Built-in Prompts by Context

**Highlight Context:**

- Explain, ELI5, Summarize

**Book Context:**

- Book Info, Find Similar, Author Background, Historical Context

**Multi-Book Context:**

- Compare Books, Common Themes, Collection Analysis

**General Context:**

- Ask

## Planned Features

- **Web Search Integration**: AI-powered web search through API
- **Profiles/Projects**: Switch between different prompt sets for academic reading, leisure, research
- **Specialized Profiles**: Pre-configured setups for Medicine, Geopolitics, Language Learning, etc.
- **Enhanced Context**: Add reading progress, notes, and annotations to AI context
- **Content vs Metadata**: Choose whether AI sees book content or just metadata
- **Voice Integration**: Text-to-speech for AI responses
- **Batch Operations**: Process multiple highlights or books in one go
- **Export Formats**: Save conversations as markdown, PDF, or EPUB
- and more

## Current State

**Version**: 0.1.0-beta (July 2025)

The Assistant plugin is under active development with a strong foundation:

- ✅ Core functionality stable and well-tested
- ✅ Multiple AI provider support fully implemented
- ✅ Context-aware system working across all KOReader interfaces
- ✅ Chat history and conversation management complete
- 🚧 Profile system in design phase
- 🚧 Enhanced context features planned

## Contributing

Contributions are welcome! Feel free to:

- Submit patches and pull requests
- Report issues and bugs
- Share feature ideas in discussions
- Improve documentation

Note: The codebase is transitioning to a more unified message and prompt building system, and work is being done on unifying window and menu systems, and defragmentation of the code base.

## Credits & History

### Fork History

Originally forked from [ASKGPT by Drew Baumann](https://github.com/drewbaumann/askgpt) in February 2025, expanded with some features (prompts customization and multiple providers, etc) and renamed to Assistant, at which point it was forked by others, and these forks are still in development. It was then taken private (and thus out of the fork network) for focused development and re-released publicly in July 2025, in a much expanded state. 

### Acknowledgments

- Original ASKGPT plugin by Drew Baumann
- Inspiration from features in Omer's fork (gestures, shortcuts)
- KOReader community for the excellent plugin framework
- All contributors and testers

### License

GNU General Public License v3.0 - See [LICENSE](LICENSE) file for details

---

**Need Help?**

- Check [KOReader Docs](https://koreader.rocks/doc/)
- Visit [User Patches Wiki](https://github.com/koreader/koreader/wiki/User-patches)
- Report issues on [GitHub](https://github.com/yourusername/koreader-assistant/issues)
