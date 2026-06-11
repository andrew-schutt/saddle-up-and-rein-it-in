require "anthropic"
require_relative "agent"
require_relative "registry"
require_relative "tools/weather"

SYSTEM_PROMPT = <<~PROMPT
  You are a helpful weather assistant. Always confirm the city before
  checking the weather if there's any ambiguity. If the user asks about
  anything other than weather, politely redirect them.
PROMPT

agent = Agent.new(
  client: Anthropic::Client.new,
  model: :"claude-sonnet-4-5",
  system_prompt: SYSTEM_PROMPT,
  registry: Registry.new([Tools::Weather]),
  max_iterations: 25
)

loop do
  print "> "

  user_input = gets&.chomp
  break if user_input.nil? || user_input.empty?

  agent.run(user_input)
  puts
end
