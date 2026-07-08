# frozen_string_literal: true

require "test_helper"

class TestProviderOpenAI < Minitest::Test
  def setup
    @provider = Yorishiro::Provider::OpenAI.new(api_key: "sk-test")
    @conversation = Yorishiro::Conversation.new(system_prompt: "You are helpful.")
    @conversation.add_message(:user, "Hello")
  end

  def test_supported_models
    models = Yorishiro::Provider::OpenAI.supported_models
    assert_includes models, "gpt-4o"
    assert_includes models, "gpt-4o-mini"
    assert_includes models, "o3-mini"
  end

  def test_default_model
    assert_equal "gpt-4o", @provider.model_name
  end

  def test_chat_sends_correct_headers
    stub_openai_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "https://api.openai.com/v1/chat/completions") do |req|
      req.headers["Authorization"] == "Bearer sk-test" &&
        req.headers["Content-Type"] == "application/json"
    end
  end

  def test_chat_includes_system_prompt
    stub_openai_stream("Hello!")

    @provider.chat(@conversation)

    assert_requested(:post, "https://api.openai.com/v1/chat/completions") do |req|
      body = JSON.parse(req.body)
      body["messages"][0]["role"] == "system" &&
        body["messages"][0]["content"] == "You are helpful."
    end
  end

  def test_chat_returns_text
    stub_openai_stream("Hello there!")

    result = @provider.chat(@conversation)
    assert_equal "Hello there!", result[:content]
    assert_empty result[:tool_calls]
  end

  def test_chat_streams_text
    stub_openai_stream("Hello!")

    chunks = []
    @provider.chat(@conversation) { |text| chunks << text }
    assert_equal ["Hello!"], chunks
  end

  def test_chat_with_tool_calls
    stub_openai_tool_call("read_file", { "path" => "/tmp/test" })

    result = @provider.chat(@conversation)
    assert_equal 1, result[:tool_calls].length
    assert_equal "read_file", result[:tool_calls][0][:name]
    assert_equal({ "path" => "/tmp/test" }, result[:tool_calls][0][:arguments])
  end

  def test_chat_401_error
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 401, body: "Unauthorized")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_429_error
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 429, body: "Rate limited")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_500_error
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Yorishiro::ProviderError) { @provider.chat(@conversation) }
  end

  def test_chat_reports_usage
    body = [
      "data: #{JSON.generate({ choices: [{ delta: { content: "hi" }, index: 0 }] })}\n\n",
      "data: #{JSON.generate({ choices: [{ delta: {}, finish_reason: "stop", index: 0 }] })}\n\n",
      "data: #{JSON.generate({ choices: [], usage: { prompt_tokens: 30, completion_tokens: 12, total_tokens: 42 } })}\n\n",
      "data: [DONE]\n\n"
    ].join

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

    result = @provider.chat(@conversation)
    assert_equal({ input: 30, output: 12 }, result[:usage])
  end

  def test_chat_requests_usage_in_stream
    stub_openai_stream("hi")

    @provider.chat(@conversation)

    assert_requested(:post, "https://api.openai.com/v1/chat/completions") do |req|
      JSON.parse(req.body).dig("stream_options", "include_usage") == true
    end
  end

  private

  def stub_openai_stream(text)
    body = [
      "data: #{JSON.generate({ choices: [{ delta: { content: text }, index: 0 }] })}\n\n",
      "data: #{JSON.generate({ choices: [{ delta: {}, finish_reason: "stop", index: 0 }] })}\n\n",
      "data: [DONE]\n\n"
    ].join

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
  end

  def stub_openai_tool_call(name, arguments)
    body = [
      "data: #{JSON.generate({ choices: [{
                               delta: { tool_calls: [{ index: 0, id: "call_test",
                                                       function: { name: name, arguments: "" } }] }, index: 0
                             }] })}\n\n",
      "data: #{JSON.generate({ choices: [{
                               delta: { tool_calls: [{ index: 0,
                                                       function: { arguments: JSON.generate(arguments) } }] }, index: 0
                             }] })}\n\n",
      "data: #{JSON.generate({ choices: [{ delta: {}, finish_reason: "tool_calls", index: 0 }] })}\n\n",
      "data: [DONE]\n\n"
    ].join

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
  end
end
