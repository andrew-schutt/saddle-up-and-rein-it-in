require "minitest/autorun"
require "tmpdir"
require "stringio"

require_relative "../registry"
require_relative "../agent"
require_relative "../tools/weather"
require_relative "../tools/file_delete"

# Redirect the harness's output files to a throwaway temp dir so the suite
# never touches the real final/agent.log or final/memory.txt. The methods
# read these constants at call time, so reassigning them here is enough.
TEST_TMP = Dir.mktmpdir("harness-test")
[:LOG_PATH, :MEMORY_PATH].each { |const| Agent.send(:remove_const, const) }
Agent.const_set(:LOG_PATH, File.join(TEST_TMP, "agent.log"))
Agent.const_set(:MEMORY_PATH, File.join(TEST_TMP, "memory.txt"))

# A stand-in for Anthropic::Client. Programmed with a queue of response
# contents (one array of blocks per API call) and records every create
# call's keyword args, so tests can assert on what the harness sent.
class FakeAnthropic
  Response = Struct.new(:content)
  Block = Struct.new(:type, :text, :name, :input, :id, keyword_init: true)

  attr_reader :calls

  def initialize(responses)
    @responses = responses.dup
    @calls = []
  end

  # client.messages.create(...) — messages returns the client itself.
  def messages = self

  def create(**kwargs)
    @calls << kwargs
    Response.new(@responses.shift || [])
  end

  def self.text(str)
    Block.new(type: :text, text: str)
  end

  def self.tool_use(name, input, id: "tu_#{name}")
    Block.new(type: :tool_use, name: name, input: input, id: id)
  end
end

# Deterministic stub tools for the registry/agent tests — no network.
module EchoTool
  SCHEMA = {
    name: "echo",
    description: "Echo a message back.",
    input_schema: {
      type: "object",
      properties: { msg: { type: "string", description: "text to echo" } },
      required: ["msg"]
    }
  }.freeze

  module_function

  def call(input)
    "echoed: #{input[:msg]}"
  end
end

module DangerTool
  DANGEROUS = true

  SCHEMA = {
    name: "danger",
    description: "A pretend dangerous action.",
    input_schema: { type: "object", properties: {}, required: [] }
  }.freeze

  module_function

  def call(_input)
    "did the dangerous thing"
  end
end

# A minimal, self-restoring stub (minitest 6 dropped minitest/mock). Replaces
# receiver.name with one that returns value for the duration of the block.
module Stubbing
  def stubbing(receiver, name, value)
    original = receiver.method(name)
    receiver.define_singleton_method(name) { |*_args| value }
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end
end

class Minitest::Test
  include Stubbing
end

# Shared builders for the agent tests.
module TestHelpers
  def build_agent(client, tools: [EchoTool, DangerTool], max_iterations: 5)
    Agent.new(
      client: client,
      model: :"claude-sonnet-4-5",
      system_prompt: "BASE",
      registry: Registry.new(tools),
      max_iterations: max_iterations
    )
  end
end
