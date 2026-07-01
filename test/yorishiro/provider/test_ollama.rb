# frozen_string_literal: true

require "test_helper"

class TestProviderOllama < Minitest::Test
  def setup
    @provider = Yorishiro::Provider::Ollama.new(model: "llama3.1")
    @conversation = Yorishiro::Conversation.new(system_prompt: "You are helpful.")
    @conversation.add_message(:user, "Hello")
  end

  def test_default_model
    assert_equal "llama3.1", @provider.model_name
  end

  def test_read_timeout_is_unlimited
    # Local inference (prompt eval on large inputs) can take arbitrarily long,
    # so Ollama disables the read timeout rather than inheriting the 120s default.
    assert_nil @provider.send(:read_timeout)
  end

  def test_supported_models_from_api
    stub_request(:get, "http://localhost:11434/api/tags")
      .to_return(status: 200, body: '{"models":[{"name":"gemma3:4b"},{"name":"llama3.2:3b"}]}')

    models = Yorishiro::Provider::Ollama.supported_models
    assert_includes models, "gemma3:4b"
    assert_includes models, "llama3.2:3b"
  end

  def test_supported_models_connection_error
    stub_request(:get, "http://localhost:11434/api/tags").to_raise(Errno::ECONNREFUSED)

    models = Yorishiro::Provider::Ollama.supported_models
    assert_empty models
  end

  def test_chat_sends_correct_body
    stub_ollama_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      body = JSON.parse(req.body)
      body["model"] == "llama3.1" &&
        body["messages"][0]["role"] == "system"
    end
  end

  def test_chat_returns_text
    stub_ollama_stream("Hello there!")

    result = @provider.chat(@conversation)
    assert_equal "Hello there!", result[:content]
    assert_empty result[:tool_calls]
  end

  def test_chat_streams_text
    stub_ollama_stream("Hello!")

    chunks = []
    @provider.chat(@conversation) { |text| chunks << text }
    assert_equal ["Hello!"], chunks
  end

  def test_chat_with_tools_uses_stream
    tools = [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }]
    stub_ollama_stream_tool_call("read_file", { "path" => "/tmp/test" })

    result = @provider.chat(@conversation, tools: tools)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      body = JSON.parse(req.body)
      body["stream"] == true && body["tools"].is_a?(Array)
    end

    assert_equal 1, result[:tool_calls].length
    assert_equal "read_file", result[:tool_calls][0][:name]
    assert_equal({ "path" => "/tmp/test" }, result[:tool_calls][0][:arguments])
  end

  def test_chat_with_tools_returns_text_and_tool_calls
    tools = [{ name: "write_file", description: "Write a file", input_schema: { type: "object" } }]
    stub_ollama_stream_with_text_and_tool_call("I'll write that file for you.", "write_file", { "path" => "/tmp/out", "content" => "hi" })

    chunks = []
    result = @provider.chat(@conversation, tools: tools) { |text| chunks << text }

    assert_equal "I'll write that file for you.", result[:content]
    assert_equal ["I'll write that file for you."], chunks
    assert_equal 1, result[:tool_calls].length
    assert_equal "write_file", result[:tool_calls][0][:name]
  end

  def test_chat_without_tools_uses_stream
    stub_ollama_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      body = JSON.parse(req.body)
      body["stream"] == true && !body.key?("tools")
    end
  end

  def test_chat_401_error
    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 401, body: "Unauthorized")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_500_error
    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_debug_log_outputs_to_stderr
    ENV["YORISHIRO_DEBUG"] = "1"
    tools = [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }]
    stub_ollama_stream_tool_call("read_file", { "path" => "/tmp/test" })

    stderr_output = capture_io { @provider.chat(@conversation, tools: tools) }[1]

    assert_includes stderr_output, "[DEBUG] Ollama request"
  ensure
    ENV.delete("YORISHIRO_DEBUG")
  end

  def test_debug_log_silent_when_disabled
    ENV.delete("YORISHIRO_DEBUG")
    tools = [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }]
    stub_ollama_stream_tool_call("read_file", { "path" => "/tmp/test" })

    stderr_output = capture_io { @provider.chat(@conversation, tools: tools) }[1]

    refute_includes stderr_output, "[DEBUG]"
  end

  def test_debug_predicate
    ENV["YORISHIRO_DEBUG"] = "1"
    assert @provider.debug?
  ensure
    ENV.delete("YORISHIRO_DEBUG")
  end

  def test_debug_predicate_false
    ENV.delete("YORISHIRO_DEBUG")
    refute @provider.debug?
  end

  def test_chat_sends_default_num_ctx
    ENV.delete("OLLAMA_NUM_CTX")
    stub_ollama_stream("Hi")

    @provider.chat(@conversation)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      JSON.parse(req.body).dig("options", "num_ctx") == 8192
    end
  end

  def test_chat_num_ctx_from_env
    ENV["OLLAMA_NUM_CTX"] = "16384"
    stub_ollama_stream("Hi")

    @provider.chat(@conversation)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      JSON.parse(req.body).dig("options", "num_ctx") == 16_384
    end
  ensure
    ENV.delete("OLLAMA_NUM_CTX")
  end

  def test_chat_num_ctx_constructor_overrides_env
    ENV["OLLAMA_NUM_CTX"] = "16384"
    provider = Yorishiro::Provider::Ollama.new(model: "llama3.1", num_ctx: 4096)
    stub_ollama_stream("Hi")

    provider.chat(@conversation)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      JSON.parse(req.body).dig("options", "num_ctx") == 4096
    end
  ensure
    ENV.delete("OLLAMA_NUM_CTX")
  end

  def test_context_budget_tokens
    ENV.delete("OLLAMA_NUM_CTX")
    # 8192 (default) - 2048 (output reserve) = 6144
    assert_equal 6144, @provider.context_budget_tokens
  end

  def test_context_budget_tokens_floor
    provider = Yorishiro::Provider::Ollama.new(model: "llama3.1", num_ctx: 512)
    # 512 - 2048 would be negative, floored at MIN_CONTEXT_BUDGET (1024)
    assert_equal 1024, provider.context_budget_tokens
  end

  def test_parse_stream_skips_malformed_lines
    body = "#{[
      "this is not json",
      JSON.generate({ message: { role: "assistant", content: "recovered" }, done: false }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })

    result = @provider.chat(@conversation)
    assert_equal "recovered", result[:content]
  end

  def test_chat_raises_on_stream_error
    body = "#{JSON.generate({ error: "model requires more system memory" })}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })

    error = assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
    assert_includes error.message, "model requires more system memory"
  end

  def test_chat_captures_meta_stats
    body = "#{[
      JSON.generate({ message: { role: "assistant", content: "Hi" }, done: false }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true, done_reason: "stop", prompt_eval_count: 42, eval_count: 7 })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })

    result = @provider.chat(@conversation)
    assert_equal 42, result[:meta][:prompt_eval_count]
    assert_equal 7, result[:meta][:eval_count]
    assert_equal "stop", result[:meta][:done_reason]
  end

  private

  def stub_ollama_stream(text)
    body = "#{[
      JSON.generate({ message: { role: "assistant", content: text }, done: false }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })
  end

  def stub_ollama_stream_tool_call(name, arguments)
    body = "#{[
      JSON.generate({
                      message: {
                        role: "assistant",
                        content: "",
                        tool_calls: [{ function: { name: name, arguments: arguments } }]
                      },
                      done: false
                    }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })
  end

  def stub_ollama_stream_with_text_and_tool_call(text, tool_name, tool_arguments)
    body = "#{[
      JSON.generate({ message: { role: "assistant", content: text }, done: false }),
      JSON.generate({
                      message: {
                        role: "assistant",
                        content: "",
                        tool_calls: [{ function: { name: tool_name, arguments: tool_arguments } }]
                      },
                      done: false
                    }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })
  end
end
