# The polished harness, layer by layer

This folder is the "after" half of a side-by-side teaching artifact: a
minimum-viable AI agent harness, built up in small commits so the git log
reads as an ordered story. The "before" half is the naive single-file
`harness_simple.rb` at the project root.

Each layer is exactly one commit, and each was run end-to-end before being
committed. The model, the weather behavior, and the conventions
(`loop do…end`, symbol model id, heredocs, `case…when`, `module_function`,
stdlib + the `anthropic` gem only) match the naive version throughout.

## Commit sequence

| Commit | Layer | Teaches |
|---|---|---|
| `ce26242` | 1 | tool-as-module + registry (dispatch by lookup, not `case`) |
| `0e0ba43` | — | cleanup: remove `final/weather_tool.rb`, superseded by `tools/weather.rb` |
| `34630a2` | 2 | `Agent` class owns the loop |
| `6749731` | 3 | input validation → errors as tool_results, not exceptions |
| `5a418cc` | 4 | dangerous-tool human confirmation |
| `026f9ac` | 5 | soft iteration cap (graceful, not `raise`) |
| `14d255b` | 6 | structured JSON logging |
| `7d2a809` | 7 | in-session compaction (running summary in the system prompt) |
| `565e1e7` | 8 | persistent memory across runs |
| `aa90c46` | 9 | hallucinated-tool recovery |
| `82ffbb6` | — | cleanup: ignore vim swap files |

## Final file layout

```
final/
├── main.rb          # wiring + outer REPL (owns the human)
├── agent.rb         # inner loop, confirmation gate, soft cap, logging,
│                    #   compaction, persistence (owns the turn)
├── registry.rb      # name→module lookup, schema validation, dispatch (owns routing)
├── tool.rb          # the contract + conformance check (owns the convention)
└── tools/
    ├── weather.rb   # real Open-Meteo lookup
    └── file_delete.rb  # stubbed dangerous tool for the demo
```

---

## Layer 1: tool-as-module + registry (`ce26242`)

The big move: the naive version's three scattered pieces — a `get_weather`
function, a `TOOLS` constant with the schema, and a `case`-statement
dispatcher — get unified into one convention plus one object that exploits it.

**`final/tool.rb`** — the contract, written down. Every tool is a plain Ruby
module exposing two things:

```ruby
#   SCHEMA      — a frozen hash { name:, description:, input_schema: }
#                 passed straight to the API as `tools:`.
#   call(input) — executes the tool; returns the tool_result string.
module Tool
  def self.assert!(mod)
    raise ArgumentError, "#{mod} must define SCHEMA" unless mod.const_defined?(:SCHEMA)
    raise ArgumentError, "#{mod} must define call(input)" unless mod.respond_to?(:call)
  end
end
```

`Tool.assert!` makes the contract executable rather than just documentation —
a malformed tool fails loudly at registration time (startup), not at dispatch
time (mid-conversation).

**`final/tools/weather.rb`** — the WeatherTool re-ported into that convention.
Same Open-Meteo implementation (geocode → forecast → WMO-code lookup), but now
the schema lives *with* the implementation, and `call(input)` is the single
entry point that unpacks the model's arguments:

```ruby
module Tools
  module Weather
    SCHEMA = { name: "get_weather", ... }.freeze

    module_function

    def call(input)
      get_weather(input[:city])
    end

    def get_weather(city) ... end   # helpers stay private to the module
    def geocode(city) ... end
  end
end
```

**`final/registry.rb`** — the payoff. Because every tool has the same shape,
the registry can treat them uniformly:

```ruby
def register(tool)
  Tool.assert!(tool)
  @tools[tool::SCHEMA[:name]] = tool   # name → module
end

def schemas
  @tools.values.map { |tool| tool::SCHEMA }   # the API's `tools:` array
end

def dispatch(name, input)
  tool = @tools[name]
  raise "Unknown tool: #{name}" unless tool
  tool.call(input)
end
```

The naive `case ... when "get_weather"` dispatcher is gone — dispatch is a hash
lookup. Adding a tool no longer means editing the dispatcher; you write a
module and pass it to `Registry.new`.

**`final/main.rb`** — same REPL and inner loop as `harness_simple.rb`, with two
substitutions: `tools: registry.schemas` in the API call and
`registry.dispatch(block.name, block.input)` where the case statement was.

---

## Layer 2: agent class (`34630a2`)

A pure extraction — no behavior change. The inner loop moves from `main.rb`
into `final/agent.rb`:

```ruby
class Agent
  def initialize(client:, model:, system_prompt:, registry:, max_iterations:)
    @client, @model, @system_prompt = client, model, system_prompt
    @registry, @max_iterations = registry, max_iterations
    @messages = []
  end

  def run(user_input)
    @messages << { role: :user, content: user_input }
    loop do
      # API call → print text / collect tool_uses → dispatch → append results
      # breaks when the model returns no tool_use blocks
    end
  end
end
```

The meaningful design point: **conversation memory moves into the object.** In
the naive version, `messages` was a top-level local that the inner loop closed
over; now `@messages` is agent state, accumulating across calls to `run`. Each
`run(user_input)` is one full agent turn — it returns when the model stops
requesting tools.

`main.rb` drops to ~28 lines: requires, system prompt heredoc, one
`Agent.new(...)`, and the outer REPL:

```ruby
loop do
  print "> "
  user_input = gets&.chomp
  break if user_input.nil? || user_input.empty?
  agent.run(user_input)
  puts
end
```

The slide-friendly separation: *main.rb owns the human, Agent owns the loop,
Registry owns the tools.*

---

## Layer 3: input validation guardrail (`6749731`)

Only `registry.rb` changes. The premise: the model's tool arguments are
untrusted input — it can omit fields or send the wrong types. The fix is a
check between lookup and execution:

```ruby
def dispatch(name, input)
  tool = @tools[name]
  return "Error: unknown tool '#{name}'." unless tool

  error = validate(tool::SCHEMA[:input_schema], input)
  return error if error

  tool.call(input)
end
```

The private `validate` checks exactly two things against the schema the tool
already declares:

```ruby
def validate(schema, input)
  # 1. every `required` field is present
  schema.fetch(:required, []).each do |field|
    return "Error: missing required field '#{field}'." unless input.key?(field.to_sym)
  end

  # 2. every provided field matches its declared JSON Schema type
  schema.fetch(:properties, {}).each do |field, spec|
    next unless input.key?(field)
    expected = JSON_TYPES.fetch(spec[:type], [Object])
    unless expected.any? { |klass| input[field].is_a?(klass) }
      return "Error: field '#{field}' should be a #{spec[:type]}, got #{input[field].inspect}."
    end
  end

  nil  # valid
end
```

`JSON_TYPES` maps schema type names to Ruby classes — the two non-obvious rows
are `"number" => [Numeric]` (Integer and Float) and
`"boolean" => [TrueClass, FalseClass]` (Ruby has no Boolean class).

The key principle: **nothing raises.** Errors return as strings, which the
agent sends back as the tool_result — so a malformed call becomes feedback the
model can self-correct from on its next iteration, instead of a crash. The
unknown-tool `raise` also became an error string in this layer, since it's the
same category of model mistake.

---

## Layer 4: dangerous tool guardrail (`5a418cc`)

Touches all five files, but each piece is small. The flow: a tool *opts in* to
being dangerous → the registry *exposes* that fact → the agent *acts* on it by
asking the human.

**`tools/file_delete.rb`** (new) — the demo tool. One constant is the whole
opt-in:

```ruby
module Tools
  module FileDelete
    DANGEROUS = true
    SCHEMA = { name: "delete_file", ... }.freeze

    module_function

    def call(input)
      "[stub] Would delete: #{input[:path]}"   # never touches the filesystem
    end
  end
end
```

**`tool.rb`** — the contract gains the optional constant and a helper, so "what
makes a tool dangerous" is defined next to the contract:

```ruby
def self.dangerous?(mod)
  mod.const_defined?(:DANGEROUS) && mod::DANGEROUS
end
```

**`registry.rb`** — one-line passthrough: `dangerous?(name)` looks up the module
and delegates to `Tool.dangerous?`.

**`agent.rb`** — the human-in-the-loop gate, deliberately placed in the Agent
(the layer that already talks to the human) rather than the Registry (which
stays pure lookup + validation):

```ruby
result =
  if @registry.dangerous?(block.name) && !confirm?(block)
    "The user declined to run #{block.name}."
  else
    @registry.dispatch(block.name, block.input)
  end
```

```ruby
def confirm?(block)
  puts "Agent wants to run: #{block.name}(#{block.input.inspect})"
  print "Allow? (y/n) "
  gets&.chomp&.downcase == "y"
end
```

A decline doesn't end the turn — the declined message goes back as the
tool_result, and the model gets to react gracefully.

**`main.rb`** — registers both tools, and the system prompt becomes
tool-agnostic (use your tools, respect declines/errors, admit when nothing
fits) now that there's more than one tool.

---

## Layer 5: soft iteration cap (`026f9ac`)

Only `agent.rb`. The naive version's `raise "Agent exceeded 25 iterations"`
killed the whole process. Now the cap is checked at the top of the loop and
exits cleanly:

```ruby
loop do
  if iterations == @max_iterations
    give_up
    break
  end
  iterations += 1
  ...
end
```

```ruby
def give_up
  text = "I had to stop after #{@max_iterations} iterations. " \
         "The task may be incomplete — feel free to ask a follow-up."
  puts text
  @messages << { role: :assistant, content: text }
end
```

The subtle-but-load-bearing detail is that last line: the synthesized message
is **appended to history**, not just printed. The cap always fires right after
tool_results were appended (a user-role message), so the conversation would
otherwise end on a user turn — appending an assistant message keeps the
user/assistant alternation valid, which is what lets the *next* `agent.run`
call succeed. That's why the REPL survives: the turn ends, the human asks a
follow-up, and the model picks up with full history.

---

## Layer 6: structured logging (`14d255b`)

`agent.rb` plus a new `.gitignore`. `run` now records the turn as it executes —
four locals track what the JSON line needs:

```ruby
iterations = 0
tool_calls = []          # accumulates {name, input, result} per dispatch
final_text = ""          # last assistant text (or the give-up message)
exit_reason = "completed"
```

The instrumentation points: text blocks get collected into `final_text` each
iteration; each tool dispatch pushes `{name:, input:, result:}` into
`tool_calls`; a decline flips `exit_reason` to `"dangerous_declined"`; hitting
the cap sets it to `"iteration_cap"` (overriding a decline, since the cap is
what actually ended the turn). At the end of `run`:

```ruby
def log_turn(record)
  entry = { timestamp: Time.now.utc.iso8601 }.merge(record)
  File.open(LOG_PATH, "a") { |f| f.puts(JSON.generate(entry)) }
end
```

One line per turn, append-only, stdlib `JSON` only. A logged turn:

```json
{"timestamp":"2026-06-11T17:27:23Z","user_input":"delete the file /tmp/x.txt","iterations":2,
 "tool_calls":[{"name":"delete_file","input":{"path":"/tmp/x.txt"},"result":"The user declined to run delete_file."}],
 "final_text":"I understand. The file deletion ... has been cancelled. ...",
 "exit_reason":"dangerous_declined"}
```

`LOG_PATH = File.expand_path("agent.log", __dir__)` anchors the log to `final/`
regardless of where you launch from, and `.gitignore` keeps it out of the repo.

---

## Layer 7: in-session compaction (`7d2a809`)

The conceptual turning point: the harness stops keeping a verbatim transcript
and starts keeping a **running summary** instead. Only `final/agent.rb`
changed.

**The state change.** A new `@summary` string (starts empty) carries everything
before the current turn. The matching change is that `@messages` becomes
*per-turn* — `run` resets it instead of appending:

```ruby
def run(user_input)
  # The summary carries all prior context, so the turn starts fresh.
  @messages = [{ role: :user, content: user_input }]
  ...
```

Through Layer 6, `@messages` grew without bound. Here it never holds more than
one turn.

**Surfacing the summary.** The history that's no longer in `@messages` rides
along in the system prompt, composed fresh on each API call:

```ruby
def current_system
  return @system_prompt if @summary.empty?
  "#{@system_prompt}\n\nConversation so far:\n#{@summary}"
end
```

The model still "remembers" earlier turns — it just reads them as a compact
summary block rather than a full replay.

**Refreshing the summary.** After the inner loop ends (both the normal break
and the `give_up` path), the harness makes one extra model call to fold the
just-finished turn into the summary:

```ruby
def compact!
  response = @client.messages.create(
    model: @model,
    max_tokens: 512,
    system: "#{SUMMARIZE_PROMPT}\nPrevious summary:\n#{@summary.empty? ? "(none yet)" : @summary}",
    messages: @messages + [{ role: :user, content: "Provide the updated running summary now." }]
  )
  text = response.content.select { |block| block.type == :text }.map(&:text).join("\n")
  @summary = text.strip
end
```

Three details that matter:

- **It runs at the turn boundary, never mid-loop.** Inside the inner loop, an
  assistant `tool_use` block must be immediately followed by its matching
  `tool_result`; collapsing history mid-exchange would make the next API call
  invalid. By the time `compact!` runs, `@messages` always ends on a clean
  assistant message.
- **The previous summary goes in the *system* prompt, not as a message.**
  Prepending it as a user message would put two user turns in a row, which the
  API rejects. Putting it in `system:` keeps alternation valid and lets the
  harness reuse the real `@messages` as the summarizer's input (it literally
  asks the model to compress its own transcript).
- **`max_tokens: 512` bounds the summary.** That cap is the mechanism that
  keeps context from overflowing.

The Layer 6 log schema is unchanged, and `compact!`'s call is deliberately
*not* counted in `iterations`.

The naive-vs-final contrast is sharpest here: the naive harness sends an
ever-growing `messages` array; the final one sends a fixed-size system summary
plus the current turn.

---

## Layer 8: persistent memory between sessions (`565e1e7`)

Because Layer 7 already distilled everything into one string, persistence is
tiny: write that string on the way out, read it on the way in. Touches
`agent.rb`, `main.rb`, and `.gitignore`.

**Load on startup.** A `MEMORY_PATH` constant (anchored to `final/` via
`__dir__`), and `initialize` seeds the summary from disk if a prior session
left one:

```ruby
MEMORY_PATH = File.expand_path("memory.txt", __dir__)

# in initialize:
@summary = File.exist?(MEMORY_PATH) ? File.read(MEMORY_PATH) : ""
```

A freshly-constructed Agent already "remembers" the last session.

**Save on exit.** A one-line public method, called once from `main.rb` after
the REPL loop breaks:

```ruby
# agent.rb
def save_memory
  File.write(MEMORY_PATH, @summary)
end
```
```ruby
# main.rb, after the loop
# Save on clean exit only. A Ctrl-C mid-session won't reach here.
agent.save_memory
```

**`.gitignore`** gains `final/memory.txt` — session state, not source.

**Two deliberate properties of this design** (chosen for simplicity):

- **Only clean exit persists.** The save runs after the loop breaks (empty
  input or EOF). A Ctrl-C skips it — that session's memory is lost. The
  alternative (writing every turn) was rejected in favor of a single write.
- **Deleting `final/memory.txt` resets memory.** There's no "forget" command;
  removing the file is the reset.

The demo payoff: run once ("I live in Denver…"), exit, re-run in a fresh
process, ask "what's the weather at home?" — and it still knows Denver, purely
from the file.

---

## Layer 9: hallucinated tool calls (`aa90c46`)

The coda — a one-branch change in `final/registry.rb`. When the model invents a
tool name, the old behavior handed back a dead-end string; now it hands back
something the model can recover from:

```ruby
def dispatch(name, input)
  tool = @tools[name]
  # Recovery-oriented: name the valid tools so the model can self-correct.
  unless tool
    return "Error: no tool named '#{name}'. Available tools: #{@tools.keys.join(", ")}."
  end
  ...
```

No agent change was needed. `dispatch`'s return already flows back as the
`tool_result`, and the inner loop already continues, so the model receives the
list of valid tools and retries on the next pass. It's list-only — no
string-distance "did you mean."

---

## The through-line

Two themes worth pointing at on a slide:

1. **Model mistakes become tool_results, not exceptions.** Bad input (Layer 3),
   human declines (Layer 4), the iteration cap (Layer 5), and invented tools
   (Layer 9) all turn into strings the model can see and recover from. Nothing
   the model does crashes the harness.

2. **The harness stops keeping a transcript and keeps a summary instead.**
   Layers 7→8 are the context-management arc: compaction bounds the context so
   it can't overflow (7), and persistence makes that compact memory survive a
   restart (8).
