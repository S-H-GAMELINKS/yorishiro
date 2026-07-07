# Yorishiro(依代)

Ruby製のCLI LLMエージェント。複数のLLMプロバイダ（Anthropic / OpenAI / Ollama）に対応し、ファイル操作・コマンド実行などの組み込みツール、MCPサーバ連携、Planモードを備えています。

[English documentation](../../README.md)

## インストール

```bash
gem install yorishiro
```

または Gemfile に追加:

```ruby
gem "yorishiro"
```

## クイックスタート

### 1. 設定ファイルを作成

```bash
# グローバル設定
vi ~/.yorishirorc

# または プロジェクトローカル設定
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

### 2. 起動

```bash
yorishiro
```

```
Yorishiro v0.1.0 (anthropic:claude-sonnet-4-20250514)
Type your message (Enter twice to send, /help for commands)

you> Hello!

assistant> Hi! How can I help you today?
```

## 使い方

### 基本操作

- メッセージを入力し、**Enterを2回**押して送信
- `Ctrl+C` または `/exit` で終了

### セッションの永続化と再開

会話は起動ディレクトリ配下の `.yorishiro/sessions/` に自動保存されます（毎ターン後と、長いツールループの途中でも逐次保存）。`yorishiro --continue`（直近）、`yorishiro --resume [ID]`（IDは前方一致可、省略時は選択画面）、または REPL 内の `/resume` で再開できます。`/clear` は新しいセッションを開始しますが、以前のセッションはディスクに残り再開可能です。セッションには作成時のプロバイダ/モデルが記録され、異なる構成で再開すると通知した上で現在の設定で続行します。ディレクトリごとに新しい50セッションが保持されます。

### スラッシュコマンド

| コマンド | 説明 |
|---------|------|
| `/plan` | Planモードの切り替え |
| `/clear` | 会話履歴をクリア（新しいセッションを開始） |
| `/resume` | 保存済みセッションの一覧から再開 |
| `/tools` | 登録済みツール一覧 |
| `/skills` | 登録済みスキル一覧 |
| `/exit` | 終了 |
| `/help` | ヘルプ表示 |

### CLIオプション

```bash
yorishiro --provider anthropic   # プロバイダ指定
yorishiro --model gpt-4o         # モデル指定
yorishiro --plan                 # Planモードで起動
yorishiro --continue             # 直近のセッションを再開
yorishiro --resume [ID]          # 保存済みセッションを再開（ID省略時は選択画面）
yorishiro --version              # バージョン表示
yorishiro --help                 # ヘルプ表示
```

## 設定

設定ファイルはRuby DSLで記述します。読み込み順序（後勝ち）:

1. `~/.yorishirorc`（グローバル設定）
2. `./.lyorishirorc`（プロジェクトローカル設定、グローバルを上書き）
3. CLIオプション（最優先）

### プロバイダ設定

```ruby
# Anthropic (Claude)
use provider: :anthropic, api_key: ENV["ANTHROPIC_API_KEY"], model: "claude-sonnet-4-20250514"

# OpenAI (ChatGPT)
use provider: :open_ai, api_key: ENV["OPENAI_API_KEY"], model: "gpt-4o"

# Ollama (ローカル)
use provider: :ollama, model: "llama3.1"
```

### 対応モデル

| プロバイダ | モデル |
|-----------|--------|
| Anthropic | claude-opus-4-20250514, claude-sonnet-4-20250514, claude-haiku-4-20250414, claude-3-5-sonnet-20241022, claude-3-5-haiku-20241022 |
| OpenAI | gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-4, gpt-3.5-turbo, o1, o1-mini, o3-mini |
| Ollama | Ollamaインスタンスで利用可能なモデル（動的取得） |

### ツール設定

```ruby
# 基本ツール（許可不要）
allow_tool Yorishiro::Tools::ReadFile.new
allow_tool Yorishiro::Tools::ListFiles.new
allow_tool Yorishiro::Tools::Grep.new

# 書き込み・編集ツール（毎回許可確認、diffプレビュー付き）
allow_tool Yorishiro::Tools::WriteFile.new
allow_tool Yorishiro::Tools::EditFile.new

# コマンド実行ツール（パターンベース許可）
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *"]
```

### コマンド実行の許可モデル

`execute_command` ツールは3段階の許可モデルを持ちます:

**1. 設定ファイルで事前許可** — `allow_commands` のglobパターンにマッチするコマンドは自動実行

```ruby
allow_tool Yorishiro::Tools::ExecuteCommand.new,
  allow_commands: ["ls", "git *", "bundle exec *"]
# ls           → 自動実行
# git status   → 自動実行
# rm -rf /     → 許可確認プロンプト
```

**2. 実行時の個別承認** — パターンにマッチしないコマンドは許可確認プロンプトが表示されます

```
[Permission] execute_command: command: rm -rf /tmp/cache
[y] Allow once  [a] Always allow  [n] Deny:
```

- `y` — 今回だけ許可
- `a` — このコマンドをセッション中ずっと自動許可
- `n` — 拒否

**3. デフォルト拒否** — `allow_tool` で登録されていないツールはLLMから利用できません

### MCPサーバ連携

[MCP (Model Context Protocol)](https://modelcontextprotocol.io/) サーバと連携して、外部ツールを利用できます。

```ruby
# MCPサーバの定義
mcp_server "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]

mcp_server "github",
  command: "gh",
  args: ["mcp"],
  env: { "GITHUB_TOKEN" => ENV["GITHUB_TOKEN"] }
```

MCPサーバのツールはyorishiro起動時に自動的に検出・登録されます。

### システムプロンプト

```ruby
system_prompt "You are a helpful coding assistant. Always explain your reasoning."
```

### Planモード

```ruby
# デフォルトでPlanモードを有効にする
plan_mode true
```

Planモードでは:
1. LLMがまず計画を立てる（ツール実行なし）
2. 計画を表示してユーザに確認
3. 承認後、ツールを使って計画を実行

### スキル（カスタムスラッシュコマンド）

```ruby
class GitStatusSkill < Yorishiro::Skill
  def name = "git_status"
  def description = "Show git status"

  def execute(_context)
    `git status`
  end
end

skill GitStatusSkill.new
# => /git_status で利用可能
```

文字列を返すスキルはその出力を表示するだけです。代わりに `prompt(...)` を返すと、
そのテキストがユーザメッセージとしてLLMに注入され（Planモードも尊重して）実行されます。
スキルからアシスタントにタスクを渡せます。

```ruby
class ReviewSkill < Yorishiro::Skill
  def name = "review"
  def description = "現在の git diff をレビュー"

  def execute(_context)
    prompt("あなたはコードレビュアーです。次のdiffをレビューして問題点を挙げてください:\n#{`git diff`}")
  end
end

skill ReviewSkill.new
# => /review で diff がLLMに渡り、エージェントループが実行される
```

スキルはファイル配置による自動読み込みもできます。`~/.yorishiro/skills/*.rb`（グローバル）
または `./.yorishiro/skills/*.rb`（プロジェクトローカル）に `Yorishiro::Skill` の
サブクラスを定義するだけで、起動時に自動登録されます（`skill ...` の呼び出しは不要）。
同名のスキルが両方にある場合はプロジェクトローカル側が優先されます。

```ruby
# .yorishiro/skills/changelog.rb
class ChangelogSkill < Yorishiro::Skill
  def name = "changelog"
  def description = "直近のコミットを要約"

  def execute(_context)
    prompt("次のコミットをチェンジログ向けに要約してください:\n#{`git log --oneline -20`}")
  end
end
# => /changelog が自動で使えるようになる
```

### 設定例（フル）

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

# 組み込みツール
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

# MCPサーバ
mcp_server "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", Dir.pwd]
```

## 組み込みツール

| ツール | クラス | 説明 | 許可 |
|-------|--------|------|------|
| `read_file` | `Yorishiro::Tools::ReadFile` | ファイル内容を読み込む | 不要 |
| `write_file` | `Yorishiro::Tools::WriteFile` | ファイルに書き込む | 毎回確認 |
| `edit_file` | `Yorishiro::Tools::EditFile` | ファイル内の文字列を正確一致で置換 | 毎回確認 |
| `list_files` | `Yorishiro::Tools::ListFiles` | ディレクトリ一覧・glob検索 | 不要 |
| `grep` | `Yorishiro::Tools::Grep` | ファイル内容をRuby正規表現で検索 | 不要 |
| `execute_command` | `Yorishiro::Tools::ExecuteCommand` | シェルコマンドを実行 | パターンベース |

## 開発

```bash
git clone https://github.com/S-H-GAMELINKS/yorishiro.git
cd yorishiro
bin/setup
bundle exec rake test      # テスト実行
bundle exec rubocop        # コードスタイルチェック
bin/console                # IRBで動作確認
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/S-H-GAMELINKS/yorishiro.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
