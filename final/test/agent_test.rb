require_relative "test_helper"

# The agent loop, driven by a fake client so it runs offline and
# deterministically. Covers the loop (Layer 2), the dangerous-tool gate
# (Layer 4), the soft cap (Layer 5), compaction (Layer 7), persistence
# (Layer 8), and hallucinated-tool recovery seen through the loop (Layer 9).
class AgentTest < Minitest::Test
  include TestHelpers

  def setup
    File.delete(Agent::MEMORY_PATH) if File.exist?(Agent::MEMORY_PATH)
    # Silence the harness's own puts/print so the test output stays clean.
    @real_stdout = $stdout
    $stdout = StringIO.new
  end

  def teardown
    $stdout = @real_stdout
  end

  # The tool_result strings the harness fed back to the model this turn.
  def tool_results(agent)
    agent.instance_variable_get(:@messages).flat_map do |message|
      next [] unless message[:content].is_a?(Array)

      message[:content]
        .select { |block| block.is_a?(Hash) && block[:type] == "tool_result" }
        .map { |block| block[:content] }
    end
  end

  def test_text_only_turn_completes_and_compacts
    client = FakeAnthropic.new([
      [FakeAnthropic.text("Hi there!")],
      [FakeAnthropic.text("User said hello.")] # compaction summary
    ])
    agent = build_agent(client)

    agent.run("hello")

    assert_equal "User said hello.", agent.instance_variable_get(:@summary)
    assert_equal 2, client.calls.size # one loop call + one compaction call
  end

  def test_tool_call_is_dispatched_and_result_fed_back
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: "hi" })],
      [FakeAnthropic.text("done")],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client)

    agent.run("please echo")

    assert_includes tool_results(agent), "echoed: hi"
    assert_equal 3, client.calls.size
  end

  def test_hallucinated_tool_gets_a_recovery_message
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("lookup_forecast", {})],
      [FakeAnthropic.text("let me use the right tool")],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client)

    agent.run("forecast please")

    assert_includes tool_results(agent),
                    "Error: no tool named 'lookup_forecast'. Available tools: echo, danger."
  end

  def test_dangerous_tool_declined
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("danger", {})],
      [FakeAnthropic.text("ok, skipping")],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client)

    stubbing(agent, :gets, "n") { agent.run("do the dangerous thing") }

    assert_includes tool_results(agent), "The user declined to run danger."
  end

  def test_dangerous_tool_approved
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("danger", {})],
      [FakeAnthropic.text("done")],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client)

    stubbing(agent, :gets, "y") { agent.run("do the dangerous thing") }

    assert_includes tool_results(agent), "did the dangerous thing"
  end

  def test_soft_cap_stops_without_raising
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: "again" })],
      [FakeAnthropic.tool_use("echo", { msg: "again" })],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client, max_iterations: 2)

    agent.run("loop forever") # must not raise

    last = agent.instance_variable_get(:@messages).last
    assert_includes last[:content], "had to stop after 2 iterations"
    assert_equal 3, client.calls.size # two capped loop calls + one compaction
  end

  def test_summary_is_injected_into_the_next_turns_system_prompt
    client = FakeAnthropic.new([
      [FakeAnthropic.text("Noted.")],
      [FakeAnthropic.text("User lives in Denver.")], # summary after turn 1
      [FakeAnthropic.text("Sure.")],
      [FakeAnthropic.text("...")]
    ])
    agent = build_agent(client)

    agent.run("I live in Denver.")
    assert_equal "BASE", client.calls[0][:system] # no summary on the first turn

    agent.run("What's new?")
    assert_includes client.calls[2][:system], "Conversation so far:"
    assert_includes client.calls[2][:system], "User lives in Denver."
  end

  def test_no_memory_file_starts_with_an_empty_summary
    agent = build_agent(FakeAnthropic.new([]))
    assert_equal "", agent.instance_variable_get(:@summary)
  end

  def test_summary_persists_across_sessions
    first = build_agent(FakeAnthropic.new([]))
    first.instance_variable_set(:@summary, "User lives in Denver.")
    first.save_memory

    second = build_agent(FakeAnthropic.new([]))
    assert_equal "User lives in Denver.", second.instance_variable_get(:@summary)
  end
end
