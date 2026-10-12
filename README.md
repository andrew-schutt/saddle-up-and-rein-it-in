# Minimum-viable AI agent harness

A side-by-side teaching artifact for a conference talk: two Ruby
implementations of a minimum-viable AI agent harness, presented as a
"before and after."

- **`harness_simple.rb`** — the naive version. A single ~80-line file: one
  tool function, a `case` dispatcher, an inline REPL and agent loop. The
  baseline.
- **`final/`** — the polished version. The same agent (same model, same
  weather behavior) restructured into formalized abstractions and built up
  in eleven layers, each adding one capability. Read
  [`final/LAYERS.md`](final/LAYERS.md) for the layer-by-layer walkthrough.

Both are weather assistants backed by the live [Open-Meteo](https://open-meteo.com/)
API (no key required for the weather itself).

## Prerequisites

- **Ruby 3.2 or newer** (developed on Ruby 4.0).
- **The `anthropic` gem.** There is no `Gemfile` — the project runs against a
  globally installed gem:

  ```sh
  gem install anthropic
  ```

- **An Anthropic API key**, exported in your shell:

  ```sh
  export ANTHROPIC_API_KEY="sk-ant-..."
  ```

  The client (`Anthropic::Client.new`) reads this from the environment. Get a
  key from the [Anthropic Console](https://console.anthropic.com/).

The only dependencies are the Ruby standard library and the `anthropic` gem;
no other gems are used.

## Running it

Both harnesses are interactive REPLs. Type a request at the `> ` prompt; submit
an empty line (or Ctrl-D) to exit.

**Naive version:**

```sh
ruby harness_simple.rb
```

**Polished version:**

```sh
ruby final/main.rb
```

Example session:

```
> what's the weather in Denver?
[get_weather({city: "Denver"}) → "Denver, United States: clear sky, 58.9°F, wind 3.0 mph."]
The weather in Denver is currently clear with a temperature of 58.9°F and
light winds at 3.0 mph.

>
```

The `[get_weather(...) → ...]` line is the harness echoing each tool call and
its result, so you can see the agent loop working. Results longer than 120
characters are cut off in the echo (`agent.log` keeps them whole).

The polished version has two tools for weather: `get_weather` for current
conditions and `get_forecast`, which returns Open-Meteo's raw hourly forecast
JSON (several kilobytes for a week).

### Watching every call (polished version)

```sh
TRACE=1 ruby final/main.rb
```

prints each model call and tool call live to stderr as it happens: tokens in
and out, latency, and why the model stopped, then a total for the turn. The
same events are always written to `final/agent.log`, with or without `TRACE`.

### Subagents (polished version)

```sh
SUBAGENTS=1 ruby final/main.rb
```

swaps the agent's weather tools for a single `delegate` tool. To answer a
weather question, the agent hands a task to a fresh helper agent that has
`get_weather` and `get_forecast`, no memory of the conversation, and
instructions to answer in two sentences. The helper's output is indented
under the parent's:

```
> should I bring an umbrella in Denver this week?
  [get_forecast({city: "Denver", days: 7}) → "{\"latitude\":39.73915,\"longitude\":-104.9847,\"generationtime_ms\":0.0549,\"utc_offset_seconds\":0,\"timezone\":\"GMT\",\"timezone…"]
  Thursday has a 70% chance of rain in Denver (high 49°F); the other days stay under 15%.
[delegate({task: "Denver, next 7 days: daily rain probability and highs."}) → "Thursday has a 70% chance of rain in Denver (high 49°F); the other days stay under 15%."]
Bring one for Thursday. The rest of the week looks dry.
```

(Output illustrative.) The console still echoes the helper's `get_forecast`
call, cut to 120 characters like every echo, but the raw forecast JSON stays
in the helper's context: the parent model only ever sees the two sentences. To see the difference, ask the
same question with and without `SUBAGENTS=1` and compare `input_tokens` on the
`"depth":0` lines in `final/agent.log`.

It's an environment variable rather than a command-line flag because the REPL
reads input with `Kernel#gets`, which would treat a command-line argument as a
file to read.

### Trying the guardrails (polished version)

The `final/` harness registers a second, deliberately **dangerous** tool —
`delete_file` — to demonstrate the human-in-the-loop confirmation gate. It is
stubbed and never touches your filesystem.

```
> delete the file /tmp/notes.txt
Agent wants to run: delete_file({path: "/tmp/notes.txt"})
Allow? (y/n) n
[delete_file({path: "/tmp/notes.txt"}) → "The user declined to run delete_file."]
I won't delete that file. Anything else?
```

Answer `y` and the stub returns `[stub] Would delete: /tmp/notes.txt` instead.

## Running the tests

The polished version has a [Minitest](https://github.com/minitest/minitest)
suite under `final/test/` (Minitest ships with Ruby, so no extra gem is
needed). The agent loop is exercised with a fake Anthropic client injected in
place of the real one, so the tests run **offline and deterministically** — no
API key or network required.

```sh
rake test                          # run everything
ruby final/test/registry_test.rb   # or a single file
LIVE_TESTS=1 rake test             # also hit the real Open-Meteo API
```

The suite redirects `agent.log` / `memory.txt` to a temp directory, so it never
touches your real session files. Two tests are skipped by default — the live
weather and forecast lookups, which only run when `LIVE_TESTS=1` is set.

## Files the polished version writes

Running `final/main.rb` creates two files inside `final/` (both gitignored):

| File | What it is | Reset |
|---|---|---|
| `agent.log` | One JSON line per event. Each model call (`model_call`: tokens in/out, latency, stop reason) and each tool call (`tool_call`: input, full result, latency) gets a line, then a `turn` line with the user input, final text, exit reason, and the turn's token and latency totals. Every line carries a `depth` (0 for the main agent, 1 for a subagent). | Delete the file. |
| `memory.txt` | A running summary of the conversation, written on clean exit and reloaded on the next run so memory carries across sessions. | Delete the file. |

Because `memory.txt` is reloaded at startup, a fresh `ruby final/main.rb`
resumes with what the previous session learned. To start from a blank slate:

```sh
rm -f final/memory.txt final/agent.log
```

Note: `memory.txt` is saved only on a **clean exit** (empty line or EOF). A
Ctrl-C mid-session won't persist that session's memory.

## Project layout

```
.
├── harness_simple.rb      # the naive single-file harness (the "before")
├── Rakefile               # `rake test` runs the suite
└── final/                 # the polished, layered harness (the "after")
    ├── main.rb            # entry point: builds the agent, runs the REPL
    ├── agent.rb           # Agent class: inner loop, confirmation, cap,
    │                      #   logging, compaction, persistence, observability
    ├── registry.rb        # tool registry: schemas + validated dispatch
    ├── tool.rb            # the contract every tool follows
    ├── tools/
    │   ├── weather.rb     # live Open-Meteo lookup (current conditions)
    │   ├── forecast.rb    # live Open-Meteo hourly forecast, raw JSON
    │   ├── delegate.rb    # hands a task to a fresh helper agent (subagents)
    │   └── file_delete.rb # stubbed dangerous tool for the demo
    ├── test/              # Minitest suite (offline, fake client)
    │   ├── test_helper.rb # fake Anthropic client, stub tools, file redirect
    │   ├── tool_test.rb
    │   ├── registry_test.rb
    │   ├── agent_test.rb
    │   ├── observability_test.rb
    │   ├── delegate_test.rb
    │   ├── weather_test.rb
    │   └── forecast_test.rb
    └── LAYERS.md          # layer-by-layer walkthrough of how final/ was built
```
