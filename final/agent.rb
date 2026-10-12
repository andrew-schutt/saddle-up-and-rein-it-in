require "json"
require "time"

# Owns the inner agent loop: send the conversation to the model, print text,
# dispatch tool calls through the registry, feed results back, and repeat
# until the model stops requesting tools.
#
# Context management: the harness never keeps a growing transcript. @messages
# holds only the current turn; everything before it is folded into a single
# running summary that rides along in the system prompt. At the end of each
# turn the harness makes one extra model call to refresh that summary.
#
# Observability: every model call and every tool call is written to
# final/agent.log as its own JSON line — tokens in and out, latency, and
# depth — and each turn ends with one summary line that totals them. With
# trace: true, the same events also print live to stderr, indented by depth.
#
# Subagents: an Agent can be started by a tool (see tools/delegate.rb). It
# runs one level deeper, starts with memory: nil, and hands its final text
# back as the parent's tool_result. Console output is indented by depth so
# the helper's lines sit inside the parent's.
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

  # Tool results can be long (a raw forecast is kilobytes of JSON). The log
  # keeps every byte; the console echo is cut to this many characters.
  CONSOLE_RESULT_LIMIT = 120

  # memory: defaults to the last session's saved summary. Pass nil to start
  # with an empty summary and never read the file.
  def initialize(client:, model:, system_prompt:, registry:, max_iterations:, depth: 0, trace: false,
                 memory: File.exist?(MEMORY_PATH) ? File.read(MEMORY_PATH) : "")
    @client = client
    @model = model
    @system_prompt = system_prompt
    @registry = registry
    @max_iterations = max_iterations
    # 0 for the top-level agent. An agent started by another agent runs one
    # level deeper, which is how the log and the trace show who called whom.
    @depth = depth
    @trace = trace
    @turn = 0
    @messages = []
    @summary = memory || ""
  end

  # Persists the running summary so the next session can resume from it.
  def save_memory
    File.write(MEMORY_PATH, @summary)
  end

  # Runs one full agent turn for the given user input and returns the
  # model's final text, so a parent agent can use it as a tool_result.
  def run(user_input)
    # The summary carries all prior context, so the turn starts fresh.
    @messages = [{ role: :user, content: user_input }]
    @turn += 1
    @turn_usage = { model_calls: 0, input_tokens: 0, output_tokens: 0 }
    turn_started = now

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

      response = call_model(
        purpose: "loop",
        iteration: iterations,
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
          say block.text
          texts << block.text
        when :tool_use
          tool_uses << block
        end
      end
      final_text = texts.join("\n")

      break if tool_uses.empty?

      tool_uses.each do |block|
        declined = false
        latency_ms = 0
        result =
          if @registry.dangerous?(block.name) && !confirm?(block)
            # A decline doesn't end the turn — the model still gets to react —
            # but it's recorded as the exit_reason (the cap overrides it).
            exit_reason = "dangerous_declined"
            declined = true
            "The user declined to run #{block.name}."
          else
            # Time the tool itself, not the human deciding whether to allow it.
            started = now
            dispatched = @registry.dispatch(block.name, block.input)
            latency_ms = elapsed_ms(started)
            dispatched
          end
        tool_calls << { name: block.name, input: block.input, result: result }
        log_event(
          event: "tool_call",
          name: block.name,
          input: block.input,
          result: result,
          declined: declined,
          latency_ms: latency_ms
        )
        say "[#{block.name}(#{block.input.inspect}) → #{truncate(result).inspect}]"
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

    log_event(
      event: "turn",
      user_input: user_input,
      iterations: iterations,
      tool_calls: tool_calls,
      final_text: final_text,
      exit_reason: exit_reason,
      **@turn_usage,
      latency_ms: elapsed_ms(turn_started)
    )

    final_text
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
  # the loop's iterations — but it is logged, because it costs tokens.
  def compact!
    response = call_model(
      purpose: "compact",
      model: @model,
      max_tokens: 512,
      system: "#{SUMMARIZE_PROMPT}\nPrevious summary:\n#{@summary.empty? ? "(none yet)" : @summary}",
      messages: @messages + [{ role: :user, content: "Provide the updated running summary now." }]
    )
    text = response.content.select { |block| block.type == :text }.map(&:text).join("\n")
    @summary = text.strip
  end

  # Every model call goes through here, so every one gets measured: tokens
  # in and out, how long it took, and why the model stopped.
  def call_model(purpose:, iteration: nil, **params)
    started = now
    response = @client.messages.create(**params)
    usage = response.usage

    @turn_usage[:model_calls] += 1
    @turn_usage[:input_tokens] += usage.input_tokens
    @turn_usage[:output_tokens] += usage.output_tokens

    log_event({
      event: "model_call",
      purpose: purpose,
      iteration: iteration,
      model: params[:model],
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      stop_reason: response.stop_reason,
      latency_ms: elapsed_ms(started)
    }.compact)

    response
  end

  # Appends one JSON line to the log. Every line carries the same envelope —
  # when, what kind of event, how deep, which turn — so lines from nested
  # agents can be told apart and grouped.
  def log_event(fields)
    entry = { timestamp: Time.now.utc.iso8601, event: fields[:event], depth: @depth, turn: @turn }.merge(fields)
    File.open(LOG_PATH, "a") { |f| f.puts(JSON.generate(entry)) }
    print_trace(entry) if @trace
  end

  # The live view of the same events, on stderr so it never mixes with the
  # assistant's answer. Indented by depth so nested agents read as a tree.
  def print_trace(entry)
    line =
      case entry[:event]
      when "model_call"
        "model #{entry[:purpose]}  in=#{entry[:input_tokens]} out=#{entry[:output_tokens]}  " \
          "#{entry[:latency_ms]}ms  (#{entry[:stop_reason]})"
      when "tool_call"
        "tool  #{entry[:name]}  #{entry[:declined] ? "declined" : "#{entry[:latency_ms]}ms"}"
      when "turn"
        "turn #{entry[:turn]}  #{entry[:model_calls]} model calls  " \
          "in=#{entry[:input_tokens]} out=#{entry[:output_tokens]}  " \
          "#{entry[:latency_ms]}ms  #{entry[:exit_reason]}"
      end
    $stderr.puts "#{indent}· #{line}"
  end

  # Console output, indented two spaces per depth level.
  def say(text)
    puts text.to_s.gsub(/^/, indent)
  end

  def indent = "  " * @depth

  def truncate(text)
    return text if text.length <= CONSOLE_RESULT_LIMIT

    "#{text[0, CONSOLE_RESULT_LIMIT - 1]}…"
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def elapsed_ms(started) = ((now - started) * 1000).round

  # When the cap is hit mid-task, end the turn with a synthesized assistant
  # message instead of raising, so the outer REPL keeps going.
  def give_up
    text = "I had to stop after #{@max_iterations} iterations. " \
           "The task may be incomplete — feel free to ask a follow-up."
    say text
    @messages << { role: :assistant, content: text }
    text
  end

  # Shows the human what the model wants to run and asks for a y/n.
  def confirm?(block)
    say "Agent wants to run: #{block.name}(#{block.input.inspect})"
    print "#{indent}Allow? (y/n) "
    gets&.chomp&.downcase == "y"
  end
end
