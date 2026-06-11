require_relative "tool"

# Holds the registered tool modules. Owns the two jobs the naive version
# scattered across a TOOLS constant and a `case` dispatcher:
#
#   #schemas  — the array passed to the API as `tools:`
#   #dispatch — routes a tool call to the right module by name
#
class Registry
  def initialize(tools = [])
    @tools = {}
    tools.each { |tool| register(tool) }
  end

  def register(tool)
    Tool.assert!(tool)
    @tools[tool::SCHEMA[:name]] = tool
  end

  def schemas
    @tools.values.map { |tool| tool::SCHEMA }
  end

  def dispatch(name, input)
    tool = @tools[name]
    raise "Unknown tool: #{name}" unless tool

    tool.call(input)
  end
end
