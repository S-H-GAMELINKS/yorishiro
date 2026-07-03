## [Unreleased]

- Let skills inject a prompt into the LLM: when a skill's `execute` returns a `Yorishiro::Skill::Prompt` (built with the `prompt("...")` helper), its text is fed to the model as a user message and the agent/plan loop runs. Skills returning a String keep printing their output as before.
- Stream Ollama responses even when tools are provided, allowing text and tool calls to be handled from NDJSON chunks.
- Add `OLLAMA_KEEP_ALIVE` support for Ollama chat requests, defaulting to `10m`.
- Disable the read timeout for Ollama so large-prompt coding tasks no longer fail with `Net::ReadTimeout` while the local model evaluates the prompt before streaming the first token. Cloud providers keep the 120s default.
- Restore `Ollama request`/`Ollama response` debug logging (`YORISHIRO_DEBUG=1`) on the streaming path.
- Send an explicit `num_ctx` (context window) with every Ollama request so large-codebase sessions no longer overflow Ollama's small default context and get silently truncated (which dropped the system prompt/tools and caused the model to stop responding). Defaults to `8192`, overridable via the `OLLAMA_NUM_CTX` env var or `ollama_num_ctx` in `.yorishirorc`.
- Automatically compact conversation history (Claude Code style): when the conversation nears the context budget, older rounds are summarized by the model into a single summary message while the most recent rounds are kept verbatim. Enabled by default; disable with `auto_compact false` in `.yorishirorc`, or trigger manually with the `/compact` command.
- Trim the oldest conversation rounds to fit the provider's context budget before each request (Ollama only for now) as a fallback after compaction, keeping the system prompt and the latest round and never splitting a tool call from its result.
- Surface context-truncation and empty-response conditions in the CLI instead of silently going quiet, and keep the REPL alive when a single turn raises an error.
- Harden Ollama NDJSON stream parsing: skip malformed/partial lines instead of crashing, and raise a `ProviderError` when Ollama streams an `error` object.

## [0.1.0] - 2026-03-18

- Initial release
- CLI REPL with Reline (multi-line input, Enter twice to send)
- Multiple LLM provider support (Anthropic, OpenAI, Ollama)
- SSE/NDJSON streaming for real-time response display
- Tool execution loop (LLM requests tool -> execute -> return result -> continue)
- Built-in tools: read_file, write_file, list_files, execute_command
- Pattern-based command permission model (allow_commands glob patterns)
- 3-tier permission: pre-approved / allow once / always allow / deny
- MCP (Model Context Protocol) server integration via mcp gem
- Plan mode (plan -> approve -> execute)
- Ruby DSL configuration (.yorishirorc / .lyorishirorc)
- Custom skills (slash commands)
