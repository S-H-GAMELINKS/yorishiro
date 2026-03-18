# frozen_string_literal: true

require_relative "lib/yorishiro/version"

Gem::Specification.new do |spec|
  spec.name = "yorishiro"
  spec.version = Yorishiro::VERSION
  spec.authors = ["S-H-GAMELINKS"]
  spec.email = ["gamelinks007@gmail.com"]

  spec.summary = "A Ruby CLI LLM agent with tool execution, MCP support, and multi-provider backends"
  spec.description = "Yorishiro is a CLI-based LLM agent that supports multiple providers (Anthropic, OpenAI, Ollama), " \
                     "built-in tools for file operations and command execution, MCP server integration, and plan mode."
  spec.homepage = "https://github.com/S-H-GAMELINKS/yorishiro"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/S-H-GAMELINKS/yorishiro"
  spec.metadata["changelog_uri"] = "https://github.com/S-H-GAMELINKS/yorishiro/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "json"
  spec.add_dependency "mcp"
  spec.add_dependency "net-http"
  spec.add_dependency "reline"
  spec.add_dependency "uri"
end
