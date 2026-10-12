require_relative "test_helper"

# Layer 10: every model call and tool call is logged as its own JSON line
# with tokens, latency, and depth, and each turn ends with a line that
# totals them. trace: true mirrors the same events live to stderr.
class ObservabilityTest < Minitest::Test
  include TestHelpers

  def setup
    [Agent::LOG_PATH, Agent::MEMORY_PATH].each { |path| File.delete(path) if File.exist?(path) }
    @real_stdout = $stdout
    @real_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
  end

  def teardown
    $stdout = @real_stdout
    $stderr = @real_stderr
  end

  # Every line written to the log this test, parsed.
  def events
    File.readlines(Agent::LOG_PATH).map { |line| JSON.parse(line, symbolize_names: true) }
  end

  # One tool call, one final answer, one compaction: three model calls.
  def run_echo_turn(**options)
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("echo", { msg: "hi" })],
      [FakeAnthropic.text("done")],
      [FakeAnthropic.text("summary")]
    ])
    build_agent(client, **options).run("please echo")
  end

  def test_every_model_call_is_logged_with_tokens_latency_and_stop_reason
    run_echo_turn

    calls = events.select { |e| e[:event] == "model_call" }
    assert_equal %w[loop loop compact], calls.map { |e| e[:purpose] }
    assert_equal %w[tool_use end_turn end_turn], calls.map { |e| e[:stop_reason] }
    calls.each do |e|
      assert_equal 100, e[:input_tokens]
      assert_equal 20, e[:output_tokens]
      assert_kind_of Integer, e[:latency_ms]
    end
  end

  def test_tool_calls_are_logged_with_latency
    run_echo_turn

    tool = events.find { |e| e[:event] == "tool_call" }
    assert_equal "echo", tool[:name]
    assert_equal "echoed: hi", tool[:result]
    assert_equal false, tool[:declined]
    assert_kind_of Integer, tool[:latency_ms]
  end

  def test_turn_line_totals_every_model_call_including_compaction
    run_echo_turn

    turn = events.last
    assert_equal "turn", turn[:event]
    assert_equal 3, turn[:model_calls]
    assert_equal 300, turn[:input_tokens]
    assert_equal 60, turn[:output_tokens]
    assert_equal "completed", turn[:exit_reason]
  end

  def test_declined_dangerous_tool_is_logged_but_never_timed
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("danger", {})],
      [FakeAnthropic.text("ok, skipping")],
      [FakeAnthropic.text("summary")]
    ])
    agent = build_agent(client)

    stubbing(agent, :gets, "n") { agent.run("do the dangerous thing") }

    tool = events.find { |e| e[:event] == "tool_call" }
    assert_equal true, tool[:declined]
    assert_equal 0, tool[:latency_ms]
    assert_equal "dangerous_declined", events.last[:exit_reason]
  end

  def test_every_line_carries_depth_and_turn
    run_echo_turn(depth: 1)

    assert events.all? { |e| e[:depth] == 1 && e[:turn] == 1 }
  end

  def test_top_level_agent_runs_at_depth_zero
    run_echo_turn

    assert events.all? { |e| e[:depth] == 0 }
  end

  def test_trace_prints_live_to_stderr_indented_by_depth
    run_echo_turn(depth: 1, trace: true)

    lines = $stderr.string.lines
    assert_equal 5, lines.size # 3 model calls, 1 tool call, 1 turn summary
    assert lines.all? { |line| line.start_with?("  · ") }
    assert lines.any? { |line| line.include?("in=100 out=20") }
  end

  def test_trace_is_off_by_default
    run_echo_turn

    assert_empty $stderr.string
  end
end
