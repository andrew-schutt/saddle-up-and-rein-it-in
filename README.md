# Minimum-viable AI agent harness

A side-by-side teaching artifact for a conference talk: two Ruby
implementations of a minimum-viable AI agent harness, presented as a
"before and after."

- **`harness_simple.rb`** — the naive version. A single ~80-line file: one
  tool function, a `case` dispatcher, an inline REPL and agent loop. The
  baseline.
- **`final/`** — the polished version. The same agent (same model, same
  weather behavior) restructured into formalized abstractions and built up
  in nine small commits, each adding one capability. Read
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
its result, so you can see the agent loop working.

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
touches your real session files. One test is skipped by default — the live
weather lookup, which only runs when `LIVE_TESTS=1` is set.

## Files the polished version writes

Running `final/main.rb` creates two files inside `final/` (both gitignored):

| File | What it is | Reset |
|---|---|---|
| `agent.log` | One JSON line per turn — timestamp, user input, iterations, tool calls, final text, and exit reason. | Delete the file. |
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
    │                      #   logging, compaction, persistence
    ├── registry.rb        # tool registry: schemas + validated dispatch
    ├── tool.rb            # the contract every tool follows
    ├── tools/
    │   ├── weather.rb     # live Open-Meteo lookup
    │   └── file_delete.rb # stubbed dangerous tool for the demo
    ├── test/              # Minitest suite (offline, fake client)
    │   ├── test_helper.rb # fake Anthropic client, stub tools, file redirect
    │   ├── tool_test.rb
    │   ├── registry_test.rb
    │   ├── agent_test.rb
    │   └── weather_test.rb
    └── LAYERS.md          # layer-by-layer walkthrough of how final/ was built
```
