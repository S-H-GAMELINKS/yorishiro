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

  def test_chat_with_tools_uses_no_stream
    tools = [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }]
    stub_ollama_no_stream_tool_call("read_file", { "path" => "/tmp/test" })

    result = @provider.chat(@conversation, tools: tools)

    assert_requested(:post, "http://localhost:11434/api/chat") do |req|
      body = JSON.parse(req.body)
      body["stream"] == false && body["tools"].is_a?(Array)
    end

    assert_equal 1, result[:tool_calls].length
    assert_equal "read_file", result[:tool_calls][0][:name]
    assert_equal({ "path" => "/tmp/test" }, result[:tool_calls][0][:arguments])
  end

  def test_chat_with_tools_returns_text_and_tool_calls
    tools = [{ name: "write_file", description: "Write a file", input_schema: { type: "object" } }]
    stub_ollama_no_stream_with_text("I'll write that file for you.", "write_file", { "path" => "/tmp/out", "content" => "hi" })

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
    stub_ollama_no_stream_tool_call("read_file", { "path" => "/tmp/test" })

    stderr_output = capture_io { @provider.chat(@conversation, tools: tools) }[1]

    assert_includes stderr_output, "[DEBUG] Ollama request"
    assert_includes stderr_output, "[DEBUG] Ollama response"
  ensure
    ENV.delete("YORISHIRO_DEBUG")
  end

  def test_debug_log_silent_when_disabled
    ENV.delete("YORISHIRO_DEBUG")
    tools = [{ name: "read_file", description: "Read a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }]
    stub_ollama_no_stream_tool_call("read_file", { "path" => "/tmp/test" })

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

  private

  def stub_ollama_stream(text)
    body = "#{[
      JSON.generate({ message: { role: "assistant", content: text }, done: false }),
      JSON.generate({ message: { role: "assistant", content: "" }, done: true })
    ].join("\n")}\n"

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/x-ndjson" })
  end

  def stub_ollama_no_stream_tool_call(name, arguments)
    body = JSON.generate({
                           message: {
                             role: "assistant",
                             content: "",
                             tool_calls: [{ function: { name: name, arguments: arguments } }]
                           },
                           done: true
                         })

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  def stub_ollama_no_stream_with_text(text, tool_name, tool_arguments)
    body = JSON.generate({
                           message: {
                             role: "assistant",
                             content: text,
                             tool_calls: [{ function: { name: tool_name, arguments: tool_arguments } }]
                           },
                           done: true
                         })

    stub_request(:post, "http://localhost:11434/api/chat")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end
end
