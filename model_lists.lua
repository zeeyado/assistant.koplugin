-- Model lists for each provider
local ModelLists = {
    anthropic = {
        "claude-sonnet-4-20250514",
        "claude-3-7-sonnet-20250219",
        "claude-3-5-haiku-20241022",
        "claude-opus-4-20250514",
    },
    openai = {
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "o4-mini",
        "o1",
        "o3-mini",
        "gpt-4o",
        "gpt-40-mini",
    },
    deepseek = {
        "deepseek-chat",
        "deepseek-coder",
        "deepseek-lite",
    },
    gemini = {
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite-preview-06-17",
    },
    ollama = {
        "llama3",
        "llama3:8b",
        "llama3:70b",
        "mistral",
        "mixtral",
        "phi3",
        "phi3:mini",
        "phi3:medium",
        "phi3:small",
        "qwen",
        "qwen:14b",
        "qwen:72b",
        "codellama",
        "codellama:7b",
        "codellama:13b",
        "codellama:34b",
        "neural-chat",
        "vicuna",
        "orca-mini",
    }
}

return ModelLists 