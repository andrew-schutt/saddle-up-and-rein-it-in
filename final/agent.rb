require "json"
require "time"

# Owns the inner agent loop: send the conversation to the model, print text,
# dispatch tool calls through the registry, feed results back, and repeat
# until the model stops requesting tools. Each turn is appended as one JSON
# line to final/agent.log.
#
# Context management: the harness never keeps a growing transcript. @messages
# holds only the current turn; everything before it is folded into a single
# running summary that rides along in the system prompt. At the end of each
# turn the harness makes one extra model call to refresh that summary.
class Agent
  LOG_PATH = File.expand_path("agent.log", __dir__)
  MEMORY_PATH = File.expand_path("memory.txt", __dir__)

  SUMMARIZE_PROMPT = <<~PROMPT
    You maintain a concise running summary of a conversation between a user
    and an assistant. Given the previous summary and the latest exchange,
    return an updated summary that preserves durable facts about the user,
    their stated preferences, decisions made, and any unresolved threads.
    Keep it tight — a few sentences at most. Return only the summary text,
    with no preamble.
  PROMPT

  def initialize(client:, model:, system_prompt:, registry:, max_iterations:)
    @client = client
    @model = model
    @system_prompt = system_prompt
    @registry = registry
    @max_iterations = max_iterations
    @messages = []
    # Resume from the last session's summary, if one was saved.
    @summary = File.exist?(MEMORY_PATH) ? File.read(MEMORY_PATH) : ""
  end

  # Persists the running summary so the next session can resume from it.
  def save_memory
    File.write(MEMORY_PATH, @summary)
  end

  # Runs one full agent turn for the given user input.
  def run(user_input)
    # The summary carries all prior context, so the turn starts fresh.
    @messages = [{ role: :user, content: user_input }]

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
        system: current_system,
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

    # Fold this turn into the running summary at the turn boundary, where
    # there are no dangling tool_use/tool_result pairs to break.
    compact!

    log_turn(
      user_input: user_input,
      iterations: iterations,
      tool_calls: tool_calls,
      final_text: final_text,
      exit_reason: exit_reason
    )
  end

  private

  # The system prompt for this turn: the base prompt, plus the running
  # summary when there is one.
  def current_system
    return @system_prompt if @summary.empty?

    "#{@system_prompt}\n\nConversation so far:\n#{@summary}"
  end

  # Refreshes @summary by asking the model to fold the latest turn into the
  # previous summary. One extra call per turn, deliberately not counted in
  # the loop's iterations.
  def compact!
    response = @client.messages.create(
      model: @model,
      max_tokens: 512,
      system: "#{SUMMARIZE_PROMPT}\nPrevious summary:\n#{@summary.empty? ? "(none yet)" : @summary}",
      messages: @messages + [{ role: :user, content: "Provide the updated running summary now." }]
    )
    text = response.content.select { |block| block.type == :text }.map(&:text).join("\n")
    @summary = text.strip
  end

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
