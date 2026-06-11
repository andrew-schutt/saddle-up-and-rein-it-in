require "anthropic"
require_relative "registry"
require_relative "tools/weather"

MODEL = :"claude-sonnet-4-5"
MAX_ITERATIONS = 25

SYSTEM_PROMPT = <<~PROMPT
  You are a helpful weather assistant. Always confirm the city before
  checking the weather if there's any ambiguity. If the user asks about
  anything other than weather, politely redirect them.
PROMPT

registry = Registry.new([Tools::Weather])
client = Anthropic::Client.new

messages = []

loop do
  print "> "

  user_input = gets&.chomp
  break if user_input.nil? || user_input.empty?

  messages << { role: :user, content: user_input }

  iterations = 0
  loop do
    iterations += 1
    raise "Agent exceeded #{MAX_ITERATIONS} iterations" if iterations > MAX_ITERATIONS

    response = client.messages.create(
      model: MODEL,
      max_tokens: 1024,
      system: SYSTEM_PROMPT,
      messages: messages,
      tools: registry.schemas
    )

    messages << { role: :assistant, content: response.content }

    tool_uses = []
    response.content.each do |block|
      case block.type
      when :text
        puts block.text
      when :tool_use
        tool_uses << block
      end
    end

    break if tool_uses.empty?

    tool_uses.each do |block|
      result = registry.dispatch(block.name, block.input)
      puts "[#{block.name}(#{block.input.inspect}) → #{result.inspect}]"
      messages << {
        role: :user,
        content: [{
          type: "tool_result",
          tool_use_id: block.id,
          content: result
        }]
      }
    end
  end
  puts
end
