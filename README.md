# Yorishiro(依代)

A CLI-based LLM agent written in Ruby. Supports multiple LLM providers (Anthropic / OpenAI / Ollama), built-in tools for file operations and command execution, MCP server integration, and plan mode.

[Japanese documentation / 日本語ドキュメント](docs/ja/README.md)

## Installation

```bash
gem install yorishiro
```

Or add to your Gemfile:

```ruby
gem "yorishiro"
```

## Quick Start

### 1. Create a configuration file

```bash
# Global configuration
vi ~/.yorishirorc

# Or project-local configuration
vi .lyorishirorc
```

```ruby
# ~/.yorishirorc
use provider: :anthropic, api_key: ENV["ANTHROPIC_API_KEY"], model: "claude-sonnet-4-20250514"

allow_tool Yorishiro::Tools::ReadFile.new
allow_tool Yorishiro::Tools::WriteFile.new
allow_tool Yorishiro::Tools::EditFile.new
allow_tool Yorishiro::Tools::ListFiles.new
allow_tool Yorishiro::Tools::Grep.new
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *", "cat *"]

system_prompt "You are a helpful coding assistant."
```

### 2. Launch

```bash
yorishiro
```

```
Yorishiro v0.1.0 (anthropic:claude-sonnet-4-20250514)
Type your message (Enter twice to send, /help for commands)

you> Hello!

assistant> Hi! How can I help you today?
```

## Usage

### Basic Operations

- Type your message and press **Enter twice** to send
- Input is a single editable buffer: use the arrow keys to move back to earlier lines and edit them before sending
- Press **↑ / ↓** to recall previously sent prompts
- `Ctrl+C` or `/exit` to quit

### Input History

Sent prompts are saved to `.yorishiro/history.json` in the directory where you launched `yorishiro`, so each project keeps its own history. On the next launch from the same directory, press **↑** to recall past prompts (multi-line prompts are restored intact) and re-send them.

Add `.yorishiro/` to your `.gitignore` to keep the history out of version control:

```
.yorishiro/
```

If several sessions run in the same directory at once, the last one to exit wins when writing the file.

### Session Persistence & Resume

Conversations are saved automatically to `.yorishiro/sessions/` under the launch directory — after every turn, and progressively during long tool loops, so a crash loses at most the in-flight completion. Resume where you left off:

```bash
yorishiro --continue        # resume the most recent session
yorishiro --resume          # pick from a list of saved sessions
yorishiro --resume 2026070  # resume by id (prefixes work)
```

Inside the REPL, `/resume` shows the same picker and `/clear` starts a new session (the old one stays on disk and remains resumable). Sessions record which provider/model they were created with; resuming under a different one prints a notice and continues with the current configuration. The newest 50 sessions are kept per directory.

### Slash Commands

| Command | Description |
|---------|-------------|
| `/plan` | Toggle plan mode |
| `/clear` | Clear conversation history (starts a new session) |
| `/resume` | List saved sessions and resume one |
| `/tools` | List registered tools |
| `/skills` | List registered skills |
| `/exit` | Exit yorishiro |
| `/help` | Show help |

### CLI Options

```bash
yorishiro --provider anthropic   # Select provider
yorishiro --model gpt-4o         # Override model
yorishiro --plan                 # Start in plan mode
yorishiro --continue             # Resume the most recent session
yorishiro --resume [ID]          # Resume a saved session (picker when ID is omitted)
yorishiro --version              # Show version
yorishiro --help                 # Show help
```

## Configuration

Configuration files use a Ruby DSL. Loading order (later overrides earlier):

1. `~/.yorishirorc` (global)
2. `./.lyorishirorc` (project-local, overrides global)
3. CLI options (highest priority)

### Provider Settings

```ruby
# Anthropic (Claude)
use provider: :anthropic, api_key: ENV["ANTHROPIC_API_KEY"], model: "claude-sonnet-4-20250514"

# OpenAI (ChatGPT)
use provider: :open_ai, api_key: ENV["OPENAI_API_KEY"], model: "gpt-4o"

# Ollama (Local)
use provider: :ollama, model: "llama3.1"
```

### Supported Models

| Provider | Models |
|----------|--------|
| Anthropic | claude-opus-4-20250514, claude-sonnet-4-20250514, claude-haiku-4-20250414, claude-3-5-sonnet-20241022, claude-3-5-haiku-20241022 |
| OpenAI | gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-4, gpt-3.5-turbo, o1, o1-mini, o3-mini |
| Ollama | Any model available on your Ollama instance (dynamically fetched) |

### Tool Settings

```ruby
# Read-only tools (no permission required)
allow_tool Yorishiro::Tools::ReadFile.new
allow_tool Yorishiro::Tools::ListFiles.new
allow_tool Yorishiro::Tools::Grep.new

# Write / edit tools (permission required every time, with a diff preview)
allow_tool Yorishiro::Tools::WriteFile.new
allow_tool Yorishiro::Tools::EditFile.new

# Command execution (pattern-based permission)
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *"]

# Subagent (delegates read-only research to a fresh context window)
allow_tool Yorishiro::Tools::Task.new
```

### Subagent (`task` tool)

The `task` tool lets the LLM delegate a read-only research task (finding where something is defined, summarizing several files) to a subagent that runs its own agent loop in a fresh context window. The subagent can use the registered read-only tools (`read_file`, `list_files`, `grep` — never `task` itself, so subagents cannot nest), and only its final text summary enters the parent conversation.

This keeps exploratory tool output out of the parent's context — especially valuable on small local context windows (e.g. Ollama with `num_ctx 8192`), where reading a handful of files can otherwise use up the whole budget. Each subagent tool call is shown as an indented progress line:

```
[Tool] Executing: task(prompt: Find where sessions are persisted...)
  [task] grep(pattern: def save)
  [task] read_file(path: lib/yorishiro/session_store.rb)
[Tool] Result: Sessions are saved to .yorishiro/sessions/<id>.json by...
```

Lifecycle hooks (`before_tool_use` / `after_tool_use`) fire for the subagent's tool calls too, and the loop is bounded at 15 iterations. Because the tool is read-only, it needs no permission prompt and is also available in plan mode.

### Command Execution Permission Model

The `execute_command` tool uses a 3-tier permission model:

**Tier 1: Pre-approved via config** — Commands matching `allow_commands` glob patterns run automatically

```ruby
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *"]
# ls           → auto-approved
# git status   → auto-approved
# rm -rf /     → permission prompt
```

**Tier 2: Runtime approval** — Commands not matching any pattern trigger a permission prompt

```
[Permission] execute_command: command: rm -rf /tmp/cache
[y] Allow once  [a] Always allow  [n] Deny:
```

- `y` — Allow this execution only
- `a` — Add to session allow list (auto-approved for the rest of the session)
- `n` — Deny

**Tier 3: Default deny** — Tools not registered with `allow_tool` are unavailable to the LLM

### MCP Server Integration

Connect to [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) servers to use external tools.

```ruby
mcp_server "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]

mcp_server "github",
  command: "gh",
  args: ["mcp"],
  env: { "GITHUB_TOKEN" => ENV["GITHUB_TOKEN"] }
```

MCP server tools are automatically discovered and registered on startup.

### System Prompt

```ruby
system_prompt "You are a helpful coding assistant. Always explain your reasoning."
```

### Plan Mode

```ruby
# Enable plan mode by default
plan_mode true
```

In plan mode:
1. The LLM creates a plan first (no tool execution)
2. The plan is displayed for user approval
3. After approval, the plan is executed with tools enabled

### Skills (Custom Slash Commands)

```ruby
class GitStatusSkill < Yorishiro::Skill
  def name = "git_status"
  def description = "Show git status"

  def execute(_context)
    `git status`
  end
end

skill GitStatusSkill.new
# => Available as /git_status
```

A skill that returns a String just prints its output. To drive the assistant
instead, return `prompt(...)`: the text is injected as a user message and the
LLM runs (respecting plan mode), so the skill can hand a task to the model.

```ruby
class ReviewSkill < Yorishiro::Skill
  def name = "review"
  def description = "Review the current git diff"

  def execute(_context)
    prompt("You are a code reviewer. Review this diff and list issues:\n#{`git diff`}")
  end
end

skill ReviewSkill.new
# => /review feeds the diff to the LLM and runs the agent loop
```

Skill files can also be auto-loaded: any `Yorishiro::Skill` subclass defined in
`~/.yorishiro/skills/*.rb` (global) or `./.yorishiro/skills/*.rb` (project-local)
is registered automatically at startup — no `skill ...` call needed. When both
directories define a skill with the same name, the project-local one wins.

```ruby
# .yorishiro/skills/changelog.rb
class ChangelogSkill < Yorishiro::Skill
  def name = "changelog"
  def description = "Summarize recent commits"

  def execute(_context)
    prompt("Summarize these commits for a changelog:\n#{`git log --oneline -20`}")
  end
end
# => /changelog is available automatically
```

### Hooks

Run Ruby blocks on lifecycle events from `.yorishirorc`:

```ruby
# Veto a tool call before the permission prompt (the denial is returned
# to the LLM as the tool result so it can change course)
on :before_tool_use do |tool_name, args|
  deny("rm is not allowed") if tool_name == "execute_command" && args["command"].to_s.include?("rm ")
end

# Observe tool results (a failing hook only prints a warning)
on :after_tool_use do |tool_name, _args, result|
  File.open(".yorishiro/audit.log", "a") { |f| f.puts "#{tool_name}: #{result.to_s[0, 100]}" }
end

# Block a message before it reaches the LLM
on :user_prompt_submit do |input|
  deny("do not paste secrets") if input.include?("BEGIN PRIVATE KEY")
end
```

Only an explicit `deny("reason")` (or `:deny`) return value vetoes the action — anything else proceeds, so logging-only hooks are safe. A `before_tool_use` hook that raises an exception denies the call (fail closed). Hooks also apply to MCP tools and plan mode.

### Full Configuration Example

```ruby
# ~/.yorishirorc

use provider: :anthropic,
    api_key: ENV["ANTHROPIC_API_KEY"],
    model: "claude-sonnet-4-20250514"

system_prompt <<~PROMPT
  You are a helpful coding assistant.
  When modifying files, always explain what you're changing and why.
PROMPT

plan_mode false

# Built-in tools
allow_tool Yorishiro::Tools::ReadFile.new
allow_tool Yorishiro::Tools::WriteFile.new
allow_tool Yorishiro::Tools::EditFile.new
allow_tool Yorishiro::Tools::ListFiles.new
allow_tool Yorishiro::Tools::Grep.new
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: [
    "ls *",
    "cat *",
    "git *",
    "bundle exec *",
    "ruby *"
  ]
allow_tool Yorishiro::Tools::Task.new

# MCP servers
mcp_server "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.pwd]
```

## Built-in Tools

| Tool | Class | Description | Permission |
|------|-------|-------------|------------|
| `read_file` | `Yorishiro::Tools::ReadFile` | Read file contents | Not required |
| `write_file` | `Yorishiro::Tools::WriteFile` | Write to a file | Required every time |
| `edit_file` | `Yorishiro::Tools::EditFile` | Replace an exact string in a file | Required every time |
| `list_files` | `Yorishiro::Tools::ListFiles` | List directory / glob search | Not required |
| `grep` | `Yorishiro::Tools::Grep` | Search file contents with a Ruby regexp | Not required |
| `execute_command` | `Yorishiro::Tools::ExecuteCommand` | Execute shell commands | Pattern-based |
| `task` | `Yorishiro::Tools::Task` | Delegate read-only research to a subagent with a fresh context window | Not required |

## Development

```bash
git clone https://github.com/S-H-GAMELINKS/yorishiro.git
cd yorishiro
bin/setup
bundle exec rake test      # Run tests
bundle exec rubocop        # Code style check
bin/console                # Interactive console
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/S-H-GAMELINKS/yorishiro.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
