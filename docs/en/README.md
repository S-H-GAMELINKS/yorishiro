# Yorishiro(依代)

A CLI-based LLM agent written in Ruby. Supports multiple LLM providers (Anthropic / OpenAI / Ollama), built-in tools for file operations and command execution, MCP server integration, and plan mode.

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
allow_tool Yorishiro::Tools::ListFiles.new
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
- `Ctrl+C` or `/exit` to quit

### Slash Commands

| Command | Description |
|---------|-------------|
| `/plan` | Toggle plan mode |
| `/clear` | Clear conversation history |
| `/tools` | List registered tools |
| `/skills` | List registered skills |
| `/exit` | Exit yorishiro |
| `/help` | Show help |

### CLI Options

```bash
yorishiro --provider anthropic   # Select provider
yorishiro --model gpt-4o         # Override model
yorishiro --plan                 # Start in plan mode
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

# Write tool (permission required every time)
allow_tool Yorishiro::Tools::WriteFile.new

# Command execution (pattern-based permission)
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *"]
```

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
allow_tool Yorishiro::Tools::ListFiles.new
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: [
    "ls *",
    "cat *",
    "git *",
    "bundle exec *",
    "ruby *"
  ]

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
| `list_files` | `Yorishiro::Tools::ListFiles` | List directory / glob search | Not required |
| `execute_command` | `Yorishiro::Tools::ExecuteCommand` | Execute shell commands | Pattern-based |

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
