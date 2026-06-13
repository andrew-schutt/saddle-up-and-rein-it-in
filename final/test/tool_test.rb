require_relative "test_helper"

# The contract from Layer 1 (SCHEMA + call) and the DANGEROUS flag from Layer 4.
class ToolContractTest < Minitest::Test
  def test_assert_passes_for_a_valid_tool
    Tool.assert!(EchoTool) # should not raise
  end

  def test_assert_requires_a_schema
    no_schema = Module.new { def self.call(_input); end }
    assert_raises(ArgumentError) { Tool.assert!(no_schema) }
  end

  def test_assert_requires_a_call_method
    no_call = Module.new { const_set(:SCHEMA, {}) }
    assert_raises(ArgumentError) { Tool.assert!(no_call) }
  end

  def test_dangerous_predicate
    assert Tool.dangerous?(DangerTool)
    refute Tool.dangerous?(EchoTool)
  end

  def test_real_tools_dangerous_flags
    assert Tool.dangerous?(Tools::FileDelete)
    refute Tool.dangerous?(Tools::Weather)
  end

  def test_file_delete_is_only_a_stub
    assert_equal "[stub] Would delete: /tmp/x", Tools::FileDelete.call(path: "/tmp/x")
  end
end
