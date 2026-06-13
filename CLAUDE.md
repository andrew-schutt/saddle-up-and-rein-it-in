# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A side-by-side **teaching artifact** for a conference talk: two Ruby
implementations of a minimum-viable AI agent harness, presented as "before and
after." Both are weather assistants backed by the live Open-Meteo API and the
Anthropic API.

- `harness_simple.rb` — the naive "before": one ~80-line file with a single
  tool function, a `case` dispatcher, and an inline REPL + agent loop.
- `final/` — the polished "after": the same agent restructured into formal
  abstractions, built up in **nine commits, each adding one capability.**

Because the audience reads the git log as a story, the commit history *is* part
of the artifact. `final/LAYERS.md` is the canonical layer-by-layer walkthrough
(commit → capability). Keep these in sync when changing `final/`, and prefer
small, single-purpose commits that match the existing layered narrative.

## Commands

```sh
# Run the harnesses (interactive REPLs; empty line or Ctrl-D exits)
ruby harness_simple.rb          # naive version
ruby final/main.rb              # polished version

# Tests (Minitest, ships with Ruby; runs offline against a fake client)
rake test                       # run everything
ruby final/test/registry_test.rb   # a single test file
LIVE_TESTS=1 rake test          # also hit the real Open-Meteo API (1 skipped test)
```

Requires Ruby 3.2+ and a globally installed `anthropic` gem (`gem install
anthropic` — there is no Gemfile). Set `ANTHROPIC_API_KEY` to run the harnesses;
the test suite needs neither key nor network unless `LIVE_TESTS=1`.

## Architecture (the `final/` harness)

The slide-friendly separation of concerns — **main owns the human, Agent owns
the turn, Registry owns the tools, Tool owns the convention:**

- `main.rb` — wiring + the outer REPL. Constructs the `Agent` (model, system
  prompt, registry of tool modules, iteration cap) and reads user input.
- `agent.rb` — the `Agent` class owns one turn: the inner model loop, the
  dangerous-tool confirmation gate, the soft iteration cap, JSON logging,
  compaction, and persistence.
- `registry.rb` — name→module lookup, schema validation, and dispatch. Pure
  routing; it never talks to the human.
- `tool.rb` — the `Tool` contract every tool module follows, plus
  `assert!`/`dangerous?` conformance checks.
- `tools/*.rb` — individual tools. `weather.rb` is a real Open-Meteo lookup;
  `file_delete.rb` is a **stubbed** dangerous tool (`DANGEROUS = true`) used to
  demo the confirmation gate — it never touches the filesystem.

### Two load-bearing design principles

These are the talk's punchlines; preserve them in any change:

1. **Model mistakes become `tool_result` strings, not exceptions.** Bad tool
   input, an invented tool name, a human declining a dangerous call, and hitting
   the iteration cap all return strings the model sees and recovers from on its
   next iteration. Nothing the model does crashes the harness. (If you add
   validation or error paths, return a string — don't `raise`.)

2. **The harness keeps a running summary, not a growing transcript.**
   `@messages` holds only the *current* turn; everything earlier is folded into
   `@summary`, which rides along in the *system* prompt (not as a message — that
   would break user/assistant alternation). `compact!` makes one extra,
   uncounted model call at each **turn boundary** to refresh the summary.
   Compaction must never run mid-loop: a `tool_use` block must be immediately
   followed by its matching `tool_result`, so collapsing history mid-exchange
   would make the next API call invalid.

### A tool is a plain module

To add a tool: define a module with a frozen `SCHEMA` hash
(`{ name:, description:, input_schema: }`) and a `call(input)` method returning a
string, then pass it to `Registry.new([...])` in `main.rb`. Optional
`DANGEROUS = true` opts the tool into the human-confirmation gate. The registry
validates the model's input against `input_schema` before dispatch.

### Session files (gitignored, written to `final/`)

`final/main.rb` writes `agent.log` (one JSON line per turn) and `memory.txt`
(the running summary, saved on **clean exit only** and reloaded at startup so
memory survives across runs). Delete either file to reset it; a Ctrl-C mid-
session won't persist memory. Paths are anchored with `__dir__`, so they always
land in `final/` regardless of launch directory.

## Conventions

`final/` deliberately matches the naive version's Ruby style throughout:
`loop do…end`, symbol model ids (`:"claude-sonnet-4-5"`), heredocs for prompts,
`module_function` tools, and **stdlib + the `anthropic` gem only** — no other
gems. Match this when extending the code.

Tests inject a `FakeAnthropic` client (a programmed queue of responses) and
redirect `LOG_PATH`/`MEMORY_PATH` to a temp dir, so the suite is deterministic
and offline. Follow that pattern rather than reaching for a mocking library
(`test_helper.rb` even ships its own tiny `stubbing` helper, since minitest 6
dropped `minitest/mock`).
