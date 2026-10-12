require_relative "test_helper"

# Layer 11: the delegate tool starts a fresh helper Agent one level down and
# hands its final text back to the parent as the tool_result.
class DelegateTest < Minitest::Test
  include TestHelpers

  def setup
    [Agent::LOG_PATH, Agent::MEMORY_PATH].each { |path| File.delete(path) if File.exist?(path) }
    @real_stdout = $stdout
    $stdout = StringIO.new
  end

  def teardown
    $stdout = @real_stdout
  end

  def test_schema_shape
    schema = Tools::Delegate::SCHEMA
    assert_equal "delegate", schema[:name]
    assert_equal ["task"], schema[:input_schema][:required]
    assert_equal "string", schema[:input_schema][:properties][:task][:type]
  end

  # One shared fake client serves both agents, in the order the calls happen:
  # the parent's tool_use, the whole child turn, then the rest of the parent's.
  def run_delegated_turn(trace: false)
    client = FakeAnthropic.new([
      [FakeAnthropic.tool_use("delegate", { task: "Denver, next 3 days: high temps and rain odds." })], # parent
      [FakeAnthropic.text("Denver highs 58/61/49°F; rain odds peak at 70% Thursday.")],              # child
      [FakeAnthropic.text("child summary")],                                                         # child compact
      [FakeAnthropic.text("Pack an umbrella for Thursday.")],                                        # parent
      [FakeAnthropic.text("parent summary")]                                                         # parent compact
    ])
    Tools::Delegate.configure(
      client: client,
      model: :"claude-sonnet-4-5",
      registry: Registry.new([Tools::Weather, Tools::Forecast]),
      max_iterations: 5,
      trace: trace
    )
    parent = build_agent(client, tools: [Tools::Delegate, Tools::FileDelete], trace: trace)
    answer = parent.run("Should I pack an umbrella for Denver?")
    [client, parent, answer]
  end

  def test_the_childs_final_text_becomes_the_parents_tool_result
    client, parent, answer = run_delegated_turn

    tool_result = parent.instance_variable_get(:@messages)
      .find { |m| m[:content].is_a?(Array) && m[:content].first[:type] == "tool_result" }
    assert_equal "Denver highs 58/61/49°F; rain odds peak at 70% Thursday.",
                 tool_result[:content].first[:content]
    assert_equal "Pack an umbrella for Thursday.", answer
    assert_equal 5, client.calls.size
  end

  def test_the_child_gets_only_the_task_and_its_own_prompt
    client, = run_delegated_turn

    child_call = client.calls[1]
    assert_equal Tools::Delegate::SUBAGENT_PROMPT, child_call[:system]
    # The fake records messages by reference, so check the first entry: the
    # child's turn opens with the task and nothing from the parent.
    assert_equal({ role: :user, content: "Denver, next 3 days: high temps and rain odds." },
                 child_call[:messages].first)
  end

  def test_the_childs_registry_has_no_delegate_and_no_delete
    client, = run_delegated_turn

    child_tools = client.calls[1][:tools].map { |schema| schema[:name] }
    assert_equal %w[get_weather get_forecast], child_tools
  end

  def test_the_child_starts_fresh_even_when_memory_is_saved
    File.write(Agent::MEMORY_PATH, "User lives in Denver.")

    client, = run_delegated_turn

    refute_includes client.calls[1][:system], "User lives in Denver."
    assert_includes client.calls[0][:system], "User lives in Denver." # the parent did load it
  end

  def test_log_lines_exist_at_both_depths
    run_delegated_turn

    events = File.readlines(Agent::LOG_PATH).map { |line| JSON.parse(line, symbolize_names: true) }
    child = events.select { |e| e[:depth] == 1 }
    parent = events.select { |e| e[:depth] == 0 }
    assert_equal %w[model_call model_call turn], child.map { |e| e[:event] }
    assert_equal %w[model_call tool_call model_call model_call turn], parent.map { |e| e[:event] }
    # The child's turn is logged before the parent's tool_call that waited on it.
    assert_operator events.index(child.last), :<, events.index(parent.find { |e| e[:event] == "tool_call" })
  end

  def test_the_childs_console_output_is_indented_inside_the_parents
    run_delegated_turn

    lines = $stdout.string.lines
    assert_includes lines, "  Denver highs 58/61/49°F; rain odds peak at 70% Thursday.\n"
    assert_includes lines, "Pack an umbrella for Thursday.\n"
  end

  def test_trace_reaches_the_child
    real_stderr = $stderr
    $stderr = StringIO.new
    run_delegated_turn(trace: true)

    lines = $stderr.string.lines
    assert lines.any? { |l| l.start_with?("  · model ") }, "expected an indented child trace line"
    assert lines.any? { |l| l.start_with?("· tool  delegate") }
  ensure
    $stderr = real_stderr
  end
end
