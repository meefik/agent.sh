# agent.sh — tests

Tests for `agent.sh` (the single-file busybox-ash LLM agent).

## Run

```sh
busybox ash tests/run_tests.sh
```

Each `test_*.sh` is self-contained and exits non-zero on failure. The runner
prints a per-file summary and a final total.

## What the tests are

**The tests run the real code from `agent.sh`, not a copy.** `lib.sh`'s
`extract_fn` slices each top-level function out of `agent.sh` by name and
`eval`s it into the test shell, so a change in `agent.sh` is what the tests
actually exercise. `load_json` loads the vendored json.sh parser (needed by
any function that flattens a JSON document).

Two layers:

- **Unit tests** — the pure functions, in isolation:
  - `test_json.sh` — `json_escape` / `json_unescape`: every control-char
    escape, the `\uXXXX` decode (NUL/LF/CR, UTF-8 of 1–4 bytes, surrogate
    pairs, lone surrogates → U+FFFD), and escape→unescape round-trips.
  - `test_params.sh` — `is_json_number` / `param_value_json` / `build_params`:
    number classification (no invalid JSON), value typing, `;`/`=` splitting,
    empty-key guards.
  - `test_mcp.sh` — `mcp_sanitize`, `flat_parse`, `json_from_flat` (schema
    reconstruction), `mcp_parse_result` (content[]/isError/plain/RPC-error),
    `mcp_dedup`.
  - `test_command.sh` — `run_command` (env scrub, timeout, truncation),
    `load_skill` (name validation + traversal rejection), `ask_prompt` (y/n/q),
    `extract_command`, `parse_response`, `build_tools`, `build_request`.

- **Integration tests** — the full `agent.sh` against mock endpoints:
  - `test_integration.sh` — the multi-turn tool loop, history round-trip, the
    wire protocol (roles, tool results, advertised tools), the final answer.
  - `test_ask.sh` — `--ask`: `n` denies a command (not run, "DENIED by user"
    fed back), `y` confirms.
  - `test_mcp_integration.sh` — MCP discovery + a real `tools/call` round-trip
    against a **pure-ash mock MCP Streamable HTTP server** (`mock/mock_mcp_http_server.sh`, busybox applets only —
    also proves the embedded-target constraint).
  - `test_features.sh` — skills (advertised + loaded + list in the prompt),
    AGENTS.md (appended to the system prompt), output truncation (`-O`).
  - `test_delegate.sh` — sub-agents: the `delegate` tool spawns a nested
    `agent.sh`, the child's answer is the tool result, and the depth guard
    (a depth-0 child cannot delegate) holds.
  - `test_streaming.sh` — `-S`/SSE: live content to stderr, tool-call fragment
    reassembly (arguments split across two SSE chunks), the final answer.
  - `test_max_turns.sh` — `-t`/`AGENT_MAX_TURNS`: default 0 (unlimited — the
    loop runs to the final answer, turns logged without a denominator) and a
    positive cap (the loop stops after that many turns without a final answer,
    error + non-zero exit).
  - `test_streaming_thinking.sh` — SSE with `reasoning` / `reasoning_content`
    deltas (`[thinking]` prefix, echoed back in history).
  - `test_mcp_sse.sh` — MCP over an SSE (`text/event-stream`) response.
  - `test_robustness.sh` — CLI validation, unknown tools, delegate path with a
    space and `timeout:0`, tool calls without an `id`, API error reporting,
    `-H` timeout on a silent server.
  - `test_delegate_timeout.sh` — a `delegate` timeout kills the whole
    sub-agent process group (fake `agent.sh` with a background grandchild).
  - `test_mcp_session.sh` — MCP `Mcp-Session-Id` is kept and echoed; header
    lines never leak into the body (fake busybox `wget` as the server).
  - `test_stream_noindex.sh` — streamed parallel tool calls from a server that
    omits `index` (fake busybox `wget` emitting SSE).

The integration tests use `mock/mock_server.sh` (a stateful mock OpenAI
endpoint that records every request to a log) and `mock/mock_sse_server.sh`
(a streaming SSE endpoint). Both are pure busybox applets — no `python3` —
so the whole suite runs on the target shell with no external dependencies.

## Target shell

The tests run under **`busybox ash`** — `agent.sh`'s target shell (shebang
`#!/bin/busybox ash`). They must not run under the host shell (bash): some of
`agent.sh`'s POSIX-ash constructs behave differently in bash, so only the
target shell proves the code works where it will actually run. The runner
selects `busybox ash` via a local `TEST_SHELL` variable and deliberately does
**not** set the `SHELL` env var — `agent.sh` reads `$SHELL` to pick the
execution shell for the model's commands, so leaking it would break every
model command.

## Layout

| file | what |
|---|---|
| `run_tests.sh` | runs the whole suite |
| `lib.sh` | shared: function extractor, assertions, counters |
| `test_json.sh` | json_escape / json_unescape |
| `test_params.sh` | model-parameter building |
| `test_mcp.sh` | MCP helper functions |
| `test_command.sh` | command exec / skills / ask / response parsing |
| `test_integration.sh` | the multi-turn loop + wire protocol |
| `test_ask.sh` | --ask confirm/deny |
| `test_mcp_integration.sh` | MCP discovery + tools/call |
| `test_features.sh` | skills / AGENTS.md / truncation |
| `test_delegate.sh` | sub-agents |
| `test_streaming.sh` | SSE streaming |
| `test_max_turns.sh` | max-turns: unlimited default + cap |
| `test_streaming_thinking.sh` | SSE reasoning deltas |
| `test_mcp_sse.sh` | MCP SSE responses |
| `test_robustness.sh` | CLI validation, unknown tool, delegate edge cases, API errors, `-H` |
| `test_delegate_timeout.sh` | delegate timeout kills the process group |
| `test_mcp_session.sh` | MCP session id handling |
| `test_stream_noindex.sh` | streamed tool calls without `index` |
| `mock/` | the fake endpoints (see below) |
| `mock/mock_server.sh` | stateful mock OpenAI endpoint |
| `mock/mock_handler.sh` | per-request handler for mock_server.sh |
| `mock/mock_sse_server.sh` | mock streaming (SSE) endpoint |
| `mock/mock_sse_handler.sh` | per-request handler for mock_sse_server.sh |
| `mock/mock_mcp_http_server.sh` | pure-ash mock MCP Streamable HTTP server |
| `mock/mock_sse_thinking_*.sh` | mock SSE endpoint with reasoning deltas |
| `mock/mock_mcp_http_handler.sh`, `mock/mock_mcp_sse_*.sh` | MCP mock handler / SSE-response server |
| `mock/mock_common.sh` | shared helpers (HTTP request reader, server loop) |
