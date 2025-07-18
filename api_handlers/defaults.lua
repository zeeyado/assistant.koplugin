local ProviderDefaults = {
    anthropic = {
        provider = "anthropic",
        model = "claude-sonnet-4-20250514",
        base_url = "https://api.anthropic.com/v1/messages",
        additional_parameters = {
            anthropic_version = "2023-06-01",
            max_tokens = 4096
        }
    },
    openai = {
        provider = "openai",
        model = "gpt-4.1",
        base_url = "https://api.openai.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    deepseek = {
        provider = "deepseek",
        model = "deepseek-chat",
        base_url = "https://api.deepseek.com/v1/chat/completions",
        additional_parameters = {
            temperature = 0.7,
            max_tokens = 4096
        }
    },
    ollama = {
        provider = "ollama",
        model = "deepseek-r1:14b",
        base_url = "http://localhost:11434/api/chat",
        additional_parameters = {
            temperature = 0.7
        }
    },
    gemini = {
        provider = "gemini",
        model = "gemini-1.5-flash",
        base_url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent",
        additional_parameters = {
            temperature = 0.7
        }
    }
}

return {
    ProviderDefaults = ProviderDefaults,
    ParameterDocs = ParameterDocs
} 