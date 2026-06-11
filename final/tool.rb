# The contract every tool follows. A tool is a plain Ruby module that exposes:
#
#   SCHEMA      — a frozen hash describing the tool to the model:
#                 { name:, description:, input_schema: }. The registry passes
#                 these straight to the API as `tools:`.
#
#   call(input) — executes the tool. `input` is the arguments hash the model
#                 chose (symbol keys). Returns a string, which becomes the
#                 content of the tool_result sent back to the model.
#
#   DANGEROUS   — optional, defaults to false. When true, the agent asks the
#                 human for confirmation before every call to this tool.
#
module Tool
  def self.assert!(mod)
    raise ArgumentError, "#{mod} must define SCHEMA" unless mod.const_defined?(:SCHEMA)
    raise ArgumentError, "#{mod} must define call(input)" unless mod.respond_to?(:call)
  end

  def self.dangerous?(mod)
    mod.const_defined?(:DANGEROUS) && mod::DANGEROUS
  end
end
