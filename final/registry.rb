require_relative "tool"

# Holds the registered tool modules. Owns the two jobs the naive version
# scattered across a TOOLS constant and a `case` dispatcher:
#
#   #schemas  — the array passed to the API as `tools:`
#   #dispatch — routes a tool call to the right module by name
#
# Before dispatching, the model's input is validated against the tool's
# SCHEMA. Bad input never raises — it returns an error string that goes
# back to the model as the tool_result, so the model can correct itself.
class Registry
  # Maps JSON Schema type names to the Ruby classes that satisfy them.
  JSON_TYPES = {
    "string" => [String],
    "integer" => [Integer],
    "number" => [Numeric],
    "boolean" => [TrueClass, FalseClass],
    "array" => [Array],
    "object" => [Hash]
  }.freeze

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

  def dangerous?(name)
    tool = @tools[name]
    !tool.nil? && Tool.dangerous?(tool)
  end

  def dispatch(name, input)
    tool = @tools[name]
    # Recovery-oriented: name the valid tools so the model can self-correct.
    unless tool
      return "Error: no tool named '#{name}'. Available tools: #{@tools.keys.join(", ")}."
    end

    error = validate(tool::SCHEMA[:input_schema], input)
    return error if error

    tool.call(input)
  end

  private

  # Returns an error string if the input is missing a required field or a
  # field's type doesn't match the schema; returns nil if the input is valid.
  def validate(schema, input)
    schema.fetch(:required, []).each do |field|
      unless input.key?(field.to_sym)
        return "Error: missing required field '#{field}'."
      end
    end

    schema.fetch(:properties, {}).each do |field, spec|
      next unless input.key?(field)

      expected = JSON_TYPES.fetch(spec[:type], [Object])
      unless expected.any? { |klass| input[field].is_a?(klass) }
        return "Error: field '#{field}' should be a #{spec[:type]}, " \
               "got #{input[field].inspect}."
      end
    end

    nil
  end
end
