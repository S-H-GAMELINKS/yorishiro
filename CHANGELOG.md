## [Unreleased]

- Stop a single task from exhausting small context windows (e.g. Ollama with `num_ctx 8192`), where reading the files needed for one request used up the whole budget and neither compaction (needs older rounds) nor trimming (keeps the latest round) could free anything:
  - `read_file` now returns at most 200 lines per call (long lines truncated at 500 characters) with a paging notice telling the model to continue via `offset`/`limit`.
  - Every tool result is capped before entering the conversation — at a quarter of the context budget when the provider reports one, 30k characters otherwise — with a notice asking the model to narrow the request.
  - When the conversation still exceeds the budget, the oldest tool results are now blanked out in place (keeping the two most recent and the message structure intact) before whole rounds are dropped, so a long tool loop inside one request degrades gracefully instead of producing empty responses.

- Add lifecycle hooks configurable from `.yorishirorc` with the `on` DSL: `:before_tool_use` (fires before the permission prompt and can veto the call by returning `deny("reason")` — the denial is fed back to the LLM as the tool result), `:after_tool_use` (observes tool results; failures only warn), and `:user_prompt_submit` (can block a message before it reaches the LLM). Only an explicit `deny(...)`/`:deny` return vetoes, so logging-only hooks are safe; a `before_tool_use` hook that raises denies the call (fail closed). Hooks apply to MCP tools and plan mode too.
- Auto-load custom skills (slash commands) from skill directories: any `Yorishiro::Skill` subclass defined in `~/.yorishiro/skills/*.rb` (global) or `./.yorishiro/skills/*.rb` (project-local) is registered at startup without a `skill ...` call. Project-local skills override same-name global ones, abstract intermediate base classes are skipped, and a broken skill file fails startup with the offending path in the error.
- Add a built-in `edit_file` tool that replaces an exact string in a file (`path`, `old_string`, `new_string`, optional `replace_all`), instead of rewriting the whole file with `write_file`. The string must match uniquely; ambiguity and misses return actionable errors so the LLM can retry.
- Show a unified diff preview in the permission prompt for `edit_file` and `write_file` (colored when the output is a TTY), so you can see the actual change before approving instead of a raw argument dump. Tools can opt in by overriding `Tool#preview`; everything else keeps the argument dump.
- Add a built-in `grep` tool that searches file contents recursively with a Ruby regular expression (`pattern`, optional `path` and `glob` filter). Matches are returned as `file:line:content`, capped at 100 results; binary files, hidden/dot directories, and dependency directories (`.git`, `node_modules`, `vendor`, `tmp`) are skipped. Read-only, so it needs no permission prompt and is available in plan mode.
- Stop plan mode from looping forever: add an `exit_plan_mode` tool the model calls to signal its plan is ready. Previously the plan loop could only end when the model returned no tool calls, so a model that kept reading files (only read-only tools are exposed in plan mode) never reached the `Execute this plan? [y/n]` prompt. When `exit_plan_mode` is called the plan is presented and the loop exits.
- Persist conversations to `.yorishiro/sessions/<id>.json` under the launch directory (saved after every turn and progressively during long tool loops, via an atomic tmp-file rename so a crash never corrupts the previous state). Resume with `--continue` (most recent session), `--resume [ID]` (ID prefixes work; interactive picker when omitted), or the `/resume` command. `/clear` starts a new session while keeping the old file resumable. Sessions record the provider/model and warn when resuming under a different one; the newest 50 sessions are kept.
- Persist input history to `.yorishiro/history.json` in the directory where `yorishiro` was launched, so past prompts (including multi-line ones) can be recalled with the up arrow across sessions. Each project keeps its own history; add `.yorishiro/` to `.gitignore` to keep it out of version control.
- Edit multi-line prompts as a single buffer: input now uses `Reline.readmultiline`, so the cursor can move back to earlier lines to edit them before sending. The "Enter on a blank line sends" gesture is unchanged.
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
