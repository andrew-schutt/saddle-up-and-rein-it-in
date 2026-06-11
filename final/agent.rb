require "json"
require "time"

# Owns the inner agent loop: send the conversation to the model, print text,
# dispatch tool calls through the registry, feed results back, and repeat
# until the model stops requesting tools. Each turn is appended as one JSON
# line to final/agent.log.
class Agent
  LOG_PATH = File.expand_path("agent.log", __dir__)

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
    tool_calls = []
    final_text = ""
    exit_reason = "completed"

    loop do
      if iterations == @max_iterations
        final_text = give_up
        exit_reason = "iteration_cap"
        break
      end
      iterations += 1

      response = @client.messages.create(
        model: @model,
        max_tokens: 1024,
        system: @system_prompt,
        messages: @messages,
        tools: @registry.schemas
      )

      @messages << { role: :assistant, content: response.content }

      texts = []
      tool_uses = []
      response.content.each do |block|
        case block.type
        when :text
          puts block.text
          texts << block.text
        when :tool_use
          tool_uses << block
        end
      end
      final_text = texts.join("\n")

      break if tool_uses.empty?

      tool_uses.each do |block|
        result =
          if @registry.dangerous?(block.name) && !confirm?(block)
            # A decline doesn't end the turn — the model still gets to react —
            # but it's recorded as the exit_reason (the cap overrides it).
            exit_reason = "dangerous_declined"
            "The user declined to run #{block.name}."
          else
            @registry.dispatch(block.name, block.input)
          end
        tool_calls << { name: block.name, input: block.input, result: result }
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

    log_turn(
      user_input: user_input,
      iterations: iterations,
      tool_calls: tool_calls,
      final_text: final_text,
      exit_reason: exit_reason
    )
  end

  private

  # Appends one JSON line describing the finished turn.
  def log_turn(record)
    entry = { timestamp: Time.now.utc.iso8601 }.merge(record)
    File.open(LOG_PATH, "a") { |f| f.puts(JSON.generate(entry)) }
  end

  # When the cap is hit mid-task, end the turn with a synthesized assistant
  # message instead of raising, so the outer REPL keeps going.
  def give_up
    text = "I had to stop after #{@max_iterations} iterations. " \
           "The task may be incomplete — feel free to ask a follow-up."
    puts text
    @messages << { role: :assistant, content: text }
    text
  end

  # Shows the human what the model wants to run and asks for a y/n.
  def confirm?(block)
    puts "Agent wants to run: #{block.name}(#{block.input.inspect})"
    print "Allow? (y/n) "
    gets&.chomp&.downcase == "y"
  end
end
