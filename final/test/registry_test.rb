require_relative "test_helper"

# The registry: schemas (Layer 1), input validation (Layer 3), dangerous
# lookup (Layer 4), and recovery-oriented unknown-tool errors (Layer 9).
class RegistryTest < Minitest::Test
  def setup
    @registry = Registry.new([EchoTool, DangerTool])
  end

  def test_schemas_are_returned_in_registration_order
    assert_equal ["echo", "danger"], @registry.schemas.map { |s| s[:name] }
  end

  def test_dispatch_runs_a_tool_with_valid_input
    assert_equal "echoed: hi", @registry.dispatch("echo", { msg: "hi" })
  end

  def test_dispatch_reports_a_missing_required_field
    assert_equal "Error: missing required field 'msg'.",
                 @registry.dispatch("echo", {})
  end

  def test_dispatch_reports_a_type_mismatch
    assert_equal "Error: field 'msg' should be a string, got 42.",
                 @registry.dispatch("echo", { msg: 42 })
  end

  def test_dispatch_lists_available_tools_for_an_unknown_name
    assert_equal "Error: no tool named 'ghost'. Available tools: echo, danger.",
                 @registry.dispatch("ghost", {})
  end

  def test_dangerous_predicate
    assert @registry.dangerous?("danger")
    refute @registry.dangerous?("echo")
    refute @registry.dangerous?("ghost")
  end

  def test_register_rejects_a_tool_that_breaks_the_contract
    no_schema = Module.new { def self.call(_input); end }
    assert_raises(ArgumentError) { Registry.new([no_schema]) }
  end
end
