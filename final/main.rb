require "anthropic"
require_relative "agent"
require_relative "registry"
require_relative "tools/weather"
require_relative "tools/forecast"
require_relative "tools/file_delete"
require_relative "tools/delegate"

SYSTEM_PROMPT = <<~PROMPT
  You are a helpful assistant. Use the tools available to you to fulfill
  the user's requests, and ask for clarification when a request is
  ambiguous. If a tool returns an error or the user declines a tool call,
  respect that and adjust rather than retrying the same call. If the user
  asks for something none of your tools can do, say so politely.
PROMPT

client = Anthropic::Client.new

# TRACE=1 ruby final/main.rb prints every model and tool call live to
# stderr. Everything is logged to final/agent.log either way.
trace = ENV["TRACE"] == "1"

# SUBAGENTS=1 ruby final/main.rb hands weather work to a helper agent, so the
# raw forecast JSON never enters this agent's context. An env var rather than
# an ARGV flag, because Kernel#gets would read ARGV as a file to open.
tools =
  if ENV["SUBAGENTS"] == "1"
    # The helper gets the weather tools and nothing else: no delegate (no
    # recursion) and no delete_file (dangerous calls stay with the agent the
    # human is talking to).
    Tools::Delegate.configure(
      client: client,
      model: :"claude-sonnet-4-5",
      registry: Registry.new([Tools::Weather, Tools::Forecast]),
      max_iterations: 25,
      depth: 0,
      trace: trace
    )
    [Tools::Delegate, Tools::FileDelete]
  else
    [Tools::Weather, Tools::Forecast, Tools::FileDelete]
  end

agent = Agent.new(
  client: client,
  model: :"claude-sonnet-4-5",
  system_prompt: SYSTEM_PROMPT,
  registry: Registry.new(tools),
  max_iterations: 25,
  trace: trace
)

loop do
  print "> "

  user_input = gets&.chomp
  break if user_input.nil? || user_input.empty?

  agent.run(user_input)
  puts
end

# Save on clean exit only. A Ctrl-C mid-session won't reach here.
agent.save_memory
