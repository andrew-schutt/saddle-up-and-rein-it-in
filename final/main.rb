require "anthropic"
require_relative "agent"
require_relative "registry"
require_relative "tools/weather"
require_relative "tools/file_delete"

SYSTEM_PROMPT = <<~PROMPT
  You are a helpful assistant. Use the tools available to you to fulfill
  the user's requests, and ask for clarification when a request is
  ambiguous. If a tool returns an error or the user declines a tool call,
  respect that and adjust rather than retrying the same call. If the user
  asks for something none of your tools can do, say so politely.
PROMPT

agent = Agent.new(
  client: Anthropic::Client.new,
  model: :"claude-sonnet-4-5",
  system_prompt: SYSTEM_PROMPT,
  registry: Registry.new([Tools::Weather, Tools::FileDelete]),
  max_iterations: 25
)

loop do
  print "> "

  user_input = gets&.chomp
  break if user_input.nil? || user_input.empty?

  agent.run(user_input)
  puts
end
