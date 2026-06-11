# Owns the inner agent loop: send the conversation to the model, print text,
# dispatch tool calls through the registry, feed results back, and repeat
# until the model stops requesting tools.
class Agent
  def initialize(client:, model:, system_prompt:, registry:, max_iterations:)
    @client = client
    @model = model
    @system_prompt = system_prompt
    @registry = registry
    @max_iterations = max_iterations
    @messages = []
  end

  # Runs one full agent turn for the given user input.
  def run(user_input)
    @messages << { role: :user, content: user_input }

    iterations = 0
    loop do
      iterations += 1
      raise "Agent exceeded #{@max_iterations} iterations" if iterations > @max_iterations

      response = @client.messages.create(
        model: @model,
        max_tokens: 1024,
        system: @system_prompt,
        messages: @messages,
        tools: @registry.schemas
      )

      @messages << { role: :assistant, content: response.content }

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
        result =
          if @registry.dangerous?(block.name) && !confirm?(block)
            "The user declined to run #{block.name}."
          else
            @registry.dispatch(block.name, block.input)
          end
        puts "[#{block.name}(#{block.input.inspect}) → #{result.inspect}]"
        @messages << {
          role: :user,
          content: [{
            type: "tool_result",
            tool_use_id: block.id,
            content: result
          }]
        }
      end
    end
  end

  private

  # Shows the human what the model wants to run and asks for a y/n.
  def confirm?(block)
    puts "Agent wants to run: #{block.name}(#{block.input.inspect})"
    print "Allow? (y/n) "
    gets&.chomp&.downcase == "y"
  end
end
