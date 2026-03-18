## [Unreleased]

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
