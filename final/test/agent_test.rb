require_relative "test_helper"

# The agent loop, driven by a fake client so it runs offline and
# deterministically. Covers the loop (Layer 2), the dangerous-tool gate
# (Layer 4), the soft cap (Layer 5), compaction (Layer 7), persistence
# (Layer 8), hallucinated-tool recovery seen through the loop (Layer 9), and
# the pieces subagents need (Layer 11): run's return value, memory: nil, and
# depth-indented, truncated console output.
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

  def test_run_returns_the_final_text
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: "hi" })],
      [FakeAnthropic.text("All done.")],
      [FakeAnthropic.text("summary")]
    ])

    assert_equal "All done.", build_agent(client).run("please echo")
  end

  def test_memory_nil_ignores_the_saved_summary
    File.write(Agent::MEMORY_PATH, "User lives in Denver.")

    agent = build_agent(FakeAnthropic.new([]), memory: nil)

    assert_equal "", agent.instance_variable_get(:@summary)
  end

  def test_console_echo_truncates_long_tool_results_but_the_log_keeps_them
    File.delete(Agent::LOG_PATH) if File.exist?(Agent::LOG_PATH)
    long = "x" * 200
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: long })],
      [FakeAnthropic.text("done")],
      [FakeAnthropic.text("summary")]
    ])

    build_agent(client).run("echo something long")

    echo = $stdout.string.lines.find { |line| line.start_with?("[echo(") }
    shown = echo[/→ "(.*)"\]$/, 1]
    assert_equal 120, shown.length
    assert shown.end_with?("…")
    logged = File.readlines(Agent::LOG_PATH).map { |line| JSON.parse(line, symbolize_names: true) }
    assert_equal "echoed: #{long}", logged.find { |e| e[:event] == "tool_call" }[:result]
  end

  def test_console_output_is_indented_two_spaces_per_depth
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: "hi" })],
      [FakeAnthropic.text("line one\nline two")],
      [FakeAnthropic.text("summary")]
    ])

    build_agent(client, depth: 2).run("please echo")

    lines = $stdout.string.lines
    assert_includes lines, "    [echo({msg: \"hi\"}) → \"echoed: hi\"]\n"
    assert_includes lines, "    line one\n"
    assert_includes lines, "    line two\n"
  end

  def test_top_level_console_output_is_not_indented
    client = FakeAnthropic.new([
      [FakeAnthropic.text("Hi there!")],
      [FakeAnthropic.text("summary")]
    ])

    build_agent(client).run("hello")

    assert_equal "Hi there!\n", $stdout.string
  end
end
