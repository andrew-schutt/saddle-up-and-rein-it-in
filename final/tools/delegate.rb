require_relative "../agent"

module Tools
  # Hands a task to a fresh helper Agent and returns its final text as the
  # tool_result. The helper's tool calls, raw results, and reasoning stay in
  # its own context; the parent only ever sees the answer.
  module Delegate
    SCHEMA = {
      name: "delegate",
      description: "Hand one self-contained weather task to a helper agent. " \
                   "The helper starts with no memory of this conversation, " \
                   "so include the city and exactly what you need back.",
      input_schema: {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "Complete instructions for the helper."
          }
        },
        required: ["task"]
      }
    }.freeze

    SUBAGENT_PROMPT = <<~PROMPT
      You are a forecast analyst working for another agent. Use your tools to
      answer the one task you're given. Reply in two sentences, max. Numbers
      over adjectives.
    PROMPT

    module_function

    # Wired once in main.rb. depth is the parent's depth; the helper runs
    # one level below it. trace should match the parent's, so TRACE=1 shows
    # the helper's calls too.
    def configure(client:, model:, registry:, max_iterations:, depth: 0, trace: false)
      @client = client
      @model = model
      @registry = registry
      @max_iterations = max_iterations
      @depth = depth
      @trace = trace
    end

    def call(input)
      child = Agent.new(
        client:         @client,
        model:          @model,
        registry:       @registry,       # weather + forecast. No delegate.
        system_prompt:  SUBAGENT_PROMPT,
        max_iterations: @max_iterations,
        depth:          @depth + 1,
        trace:          @trace,
        memory:         nil              # fresh means fresh
      )
      child.run(input[:task])            # => String → tool_result
    end
  end
end
