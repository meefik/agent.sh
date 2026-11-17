# agent.sh — spec

A single-file LLM agent written in `ash` (busybox POSIX shell), using **only
busybox applets** — no jq, no python, no curl. One executable,
cross-platform, runs on embedded systems.

## Goals

- Single file `agent.sh`, no external dependencies beyond the busybox binary.
- **Native tool calling** (OpenAI `tools` protocol): `shell(command)` is always
  present — commands run under `$SHELL` (default `sh` if unset) — plus
  `skill`, `delegate` and `mcp_*` tools when configured (see below). No
  text-protocol fallback (simplicity first).
- Streaming is optional (`-S`, off by default): plain request/response per turn
  unless the user asks for SSE.
- Works against any OpenAI-compatible `/v1/chat/completions` endpoint
  (default target: a local Ollama on `:11434`, no key).
- **No sandbox of its own:** the user wraps `agent.sh` in whatever sandbox
  they want (podman, bwrap, unshare, firejail, …). `agent.sh` runs each
  command as a plain child, with the defense-in-depth layers that don't
  depend on a sandbox (env scrubbing, timeout, truncation).

## Non-goals

- Multi-tool catalogues, sessions/memory, history persistence.
- GUI, watch mode, multi-user.
- Sandboxing (the user wraps the script; see *Command execution*).
- Security against a *malicious* model (the env scrubbing stops accidental
  damage, not deliberate exfiltration).

## CLI & config

```
agent.sh [-e endpoint] [-m model] [-k key] [-p system-prompt]
         [-s shell] [-t max-turns] [-T cmd-timeout] [-O max-output]
         [-H http-timeout]
         [-a|--ask] [-S|--stream] [-w workdir] [-d depth]
         [-P key=value] [-M name=url] <task...>
```

- `endpoint` default `http://localhost:11434/v1`; `model` default `qwen3`
  (both overridable via env `AGENT_ENDPOINT`, `AGENT_MODEL`, `AGENT_KEY`).
- `max-turns`, `cmd-timeout`, `max-output`, `http-timeout` and `depth` must be non-negative
  integers (else exit 2 with a message; leading zeros are stripped, so `08`
  is 8, not a bad octal); an option with no value is exit 2.
- `max-turns` default 0 — unlimited. A positive value caps the tool loop
  (the loop stops after that many turns without a final answer).
- `cmd-timeout` default 300; 0 = unlimited. A positive value is the per-command
  timeout in seconds (wraps the command in `timeout N`; 0 omits the wrapper,
  since `timeout 0` kills the command immediately).
- `http-timeout` default 300; 0 = busybox's wget default. Seconds of silence
  tolerated on a model request (`wget --timeout`). MCP requests use a fixed
  120 s and the `delegate` URL fetch a fixed 60 s; neither follows `-H`.
- `max-output` default 16384; 0 = unlimited. A positive value caps each tool result
  (shell command output, `delegate` answer, MCP tool result) in bytes. It does
  **not** apply to the user's own files loaded into the prompt (skills,
  `AGENTS.md`) — those are loaded in full.
- `--ask` (`-a`): confirm each command before running (y/n/q). **Off by
  default** — commands run without confirmation unless this is set.
  Answers are read from stdin (from `/dev/tty` when the script itself is piped in via
  `ash -s -`, i.e. `$0` is not a file). Model commands run with stdin redirected from `/dev/null`.
- `--stream` (`-S`): stream the model's output live to stderr while it works
  (SSE, `stream: true`). **Off by default.** See *Streaming*.
- `-w workdir`: the directory the model is told it can write (default: the
  current directory). It is created if missing and the harness `cd`s into it
  (exit 1 if that fails), so model commands start there; a relative
  `AGENT_SELF` is made absolute first. Not an enforcement — the sandbox, if
  any, is the user's.
- **Execution shell:** `-s shell` overrides; otherwise taken from `$SHELL` at
  startup, default `sh` if unset — the harness itself stays pure ash; only
  the model's commands run under it.
- **Model parameters:** `-P key=value` (repeatable) sets an extra top-level
  field in the request body — `temperature`, `top_p`, `max_tokens`,
  `enable_thinking`, `reasoning_effort`, … — without hard-coding any
  provider's schema. Value classification: a value starting with `{` or `[`
  is emitted as raw JSON (covers Anthropic-style `thinking:{"type":"enabled"}`),
  `true`/`false`/`null` and numbers are emitted as-is, anything else is a
  JSON string. Env form: `AGENT_PARAMS="temperature=0.7;top_p=0.9"`
  (semicolon-separated; CLI entries are appended after. A repeated key is
  emitted twice, in order, so the last one wins in JSON parsers that
  accept duplicate keys). Limitation: `;` is the entry separator, so it may not appear
  inside a value (notably in raw-JSON values).

### Env-var arguments (portability / `curl | ash -s -`)

Every CLI option also has an `AGENT_*` env default, so the script can run
with **no arguments at all** — set the env vars and pipe the script in.
This is the intended `curl | ash -s -` usage.

| option | env var | default |
|---|---|---|
| `-e endpoint` | `AGENT_ENDPOINT` | `http://localhost:11434/v1` |
| `-m model` | `AGENT_MODEL` | `qwen3` |
| `-k key` | `AGENT_KEY` | *(empty)* |
| `-p system-prompt` | `AGENT_SYSTEM_PROMPT` | *(built-in)* |
| `-s shell` | `AGENT_SHELL` | `$SHELL`, else `sh` |
| `-t max-turns` | `AGENT_MAX_TURNS` | `0` (unlimited; a positive value caps the loop) |
| `-O max-output` | `AGENT_MAX_OUTPUT` | `16384` (`0` = unlimited; a positive value caps each tool result in bytes) |
| `-T cmd-timeout` | `AGENT_TIMEOUT` | `300` (`0` = unlimited; a positive value is the per-command timeout in seconds) |
| `-H http-timeout` | `AGENT_HTTP_TIMEOUT` | `300` (seconds of silence tolerated on a model request, passed as `wget --timeout`; `0` = busybox default) |
| `-a` / `--ask` | `AGENT_ASK` | `0` (empty/`0` = off, any other value = on) |
| `-S` / `--stream` | `AGENT_STREAM` | `0` (empty/`0` = off, any other value = on) |
| `-w workdir` | `AGENT_WORKDIR` | current directory |
| `-d depth` | `AGENT_DEPTH` | `1` (remaining delegation depth) |
| *(none)* | `AGENT_SELF` | *(empty; path or URL to agent.sh; enables the `delegate` tool)* |
| `-P key=value` | `AGENT_PARAMS` | *(empty; semicolon-separated)* |
| `-M name=url` | `AGENT_MCP` | *(empty; semicolon-separated; MCP servers)* |
| `<task...>` | `AGENT_TASK` | *(empty; required, or piped on stdin)* |

Task from stdin: if neither a CLI task nor `AGENT_TASK` is set, `$0` is a file
(the script is not itself on stdin) and stdin is not a tty, the whole of stdin is
the task (`cat task.md | busybox ash agent.sh`). In that case `--ask` answers
are read from `/dev/tty`.

Command-line args override the env vars. The harness requires `busybox ash`
(it uses ash extensions such as `local` and `${s//a/b}`) and calls the
applets by bare name (`sed`, `grep`, …), which `busybox ash` resolves to its
internal applets first. Two things must be busybox's own and are run through
`$BB` (`command -v busybox`, else `readlink /proc/self/exe`): `wget` (GNU wget cannot
read a request body from a pipe) and the child `ash` of `delegate`.

Run via pipe: `busybox wget -qO - https://…/agent.sh | ash -s -` (busybox ash needs
`-s -` to take the script from stdin; `ash -` alone treats the next arg as
a filename).

## Agent loop

```
msgs = [system, user(task)]
turn = 0
loop:
    turn += 1
    # max-turns 0 = unlimited; a positive value caps the tool loop.
    if max-turns > 0 and turn > max-turns:
        error "reached max-turns (max-turns) without a final answer" ; exit 1
    resp = POST $endpoint/chat/completions {model, messages: msgs, tools: [shell, skill?, delegate?, mcp_*?]}
    m = resp.choices[0].message
    if m.tool_calls:
        msgs += [m]                          # assistant message with tool_calls
                                              # (+ m.reasoning[_content] if present)
        for tc in m.tool_calls:              # one at a time, in order
            if tc.function.name == "skill":
                result = load_skill(tc.function.arguments.name)
                    # SKILL.md content (in full), or error + available list
            elif tc.function.name == "delegate":
                task = tc.function.arguments.task
                if ask: prompt "delegate: $task ? [y/n/q]"
                result = spawn_subagent(task, tc.function.arguments.timeout)
                    # the child's final answer (truncated), or an error
            elif tc.function.name startswith "mcp_":
                if ask: prompt "mcp <name>: <args> ? [y/n/q]"
                result = mcp_call(name, arguments) | truncate_output
            elif tc.function.name != "shell":
                result = "unknown tool: <name>"   # never run as a command
            else:  # "shell"
                cmd = tc.function.arguments.command   # JSON-escaped string
                if ask: prompt "run: $cmd ? [y/n/q]"
                result = run_command(cmd)   # output through truncate_output, then "[exit status: N]" if N != 0
                    # truncate_output = head -c $MAX_OUTPUT if > 0 (a UTF-8 character cut
                    # by the cap is dropped whole), else cat
            msgs += [ {role:"tool", tool_call_id: tc.id, content: result} ]
    else:
        echo m.content; break
```

- Multiple `tool_calls` in one response: execute in order, one `role:tool`
  message per call (required by the protocol).
- `finish_reason: length` or a turn cap without plain content: print a
  one-line note and exit non-zero. A response carrying an `error.message`
  prints `API error: <message>` instead.
- Tool calls are counted by distinct index from `id` or `function.name`
  lines, so servers that omit the `id` still work.
- **Reasoning echo:** thinking models (Qwen3, DeepSeek, …) return a
  `reasoning` (or `reasoning_content`, as DeepSeek/vLLM/llama.cpp send) field
  on the assistant message. The harness carries it back under the same name in
  the assistant message it appends to the history (when non-null) so the
  chain of thought survives across turns; the final answer is `content`
  only.

## Wire protocol

Request body:

```json
{
  "model": "<model>",
  "messages": [ ... ],
  "tools": [ {
    "type": "function",
    "function": {
      "name": "shell",
      "description": "Run a shell command. Returns combined stdout/stderr, truncated.",
      "parameters": {
        "type": "object",
        "properties": { "command": { "type": "string", "description": "The shell command to run." } },
        "required": ["command"]
      }
    }
  }, {
    "type": "function",
    "function": {
      "name": "skill",
      "description": "Load the full text of a skill by name (see the skill list in the system prompt).",
      "parameters": {
        "type": "object",
        "properties": { "name": { "type": "string", "description": "The skill name to load." } },
        "required": ["name"]
      }
    }
  }, {
    "type": "function",
    "function": {
      "name": "delegate",
      "description": "Spawn a sub-agent (a nested agent.sh run) to work a sub-task. It blocks until the sub-agent finishes and returns its final answer. Use it for self-contained sub-tasks that would take several shell commands.",
      "parameters": {
        "type": "object",
        "properties": {
          "task": { "type": "string", "description": "The sub-task for the sub-agent." },
          "timeout": { "type": "number", "description": "Optional total timeout for the sub-agent, in seconds." }
        },
        "required": ["task"]
      }
    }
  } ],
  "tool_choice": "auto"
}
```

`skill` is present only when skills are present; `delegate` only when
`AGENT_SELF` is set and `AGENT_DEPTH > 0`.

Message shapes we must handle in responses: `system`, `user`, `assistant`
(with optional `tool_calls[]` and `content`), `tool` (`tool_call_id` +
`content`). `content` may be `null` — treat as empty.

## JSON handling

**Parse:** vendor **json.sh** (rcrowley, pure POSIX shell, BSD-licensed)
inline in `agent.sh` as a function block (attribution + license note kept).
It flattens JSON to `/key/path type value` lines, so extraction is a one-line
`sed` (`flat_val PATH [TYPE]`):

- `choices/0/message/tool_calls/0/function/arguments` → parse again (nested)
  for `.command`.
- `choices/0/message/content`, `choices/0/finish_reason`.

Empty containers carry no leaf, so the flattener emits a marker line for them
(`/path array` / `/path object`); `json_from_flat` turns it back into `[]` / `{}`.

**Decode:** `json_unescape` turns a JSON string body into bytes, including
`\uXXXX` → UTF-8 (1–4 bytes; surrogate pairs combined; a lone surrogate →
U+FFFD; `\u0000` dropped, a shell string cannot hold a NUL).

**Build:** the request is built with `printf` + a `json_escape()` function
that escapes `\`, `"`, newline, tab, and control chars. This is the main
correctness risk — the command and the tool result may contain any bytes.
Test with quotes, backslashes, newlines, and non-UTF8 bytes.

## HTTP transport

busybox `wget --post-file=/dev/stdin` for the model endpoint (the body is piped
in, not passed as an argument: argv strings are capped at 128 KiB and visible
in `ps`; invoked as `busybox wget`, since GNU wget cannot read a pipe). MCP
uses `busybox wget --post-file=/dev/stdin` too (same reasons). Verify POST support
on the target busybox build. No expect-100;
wget's stderr is left visible, so an HTTP error (`server returned error:
HTTP/1.1 401 …`) is shown to the user;
`wget -O -` writes the response body to stdout, which is captured into a
shell variable — **nothing is written to disk** (no temp files, no
`mktemp`), so the script runs on a read-only root or a target without
`/tmp`.

Limitation: the API key travels in argv (`--header="Authorization: …"`),
because busybox wget cannot read headers from stdin. It is visible in `ps`
to other local users while a request is in flight; model commands run
sequentially, never concurrently with it.

There is no `nc`-based fallback: the harness requires `wget` (every
reasonable busybox build ships it). This keeps the transport single-path
and is what makes streaming possible (see *Streaming*).

## Streaming

`-S` / `--stream` / `AGENT_STREAM` (off by default) switches a turn to
server-sent events. The request body gains `"stream": true`, and
`http_post_stream` (instead of `http_post`) pipes the `wget` SSE response
into a subshell that reads it line by line:

- Each `data: {...}` chunk is flattened with the vendored `json`; its flat
  lines are walked with shell builtins (`case` on the path), so a chunk costs
  no extra process beyond the parser.
- `delta.content` is **printed live to stderr** as it arrives (the model's
  visible output); `delta.reasoning` / `delta.reasoning_content` is printed live prefixed with
  `[thinking]` (thinking models) — the prefix marks the start of a
  contiguous run of reasoning chunks (one per block, not per chunk); a
  content chunk ends the run, so reasoning resuming after content is
  re-prefixed.
- Tool-call fragments are accumulated per `index`. A server that omits
  `index` is handled too: a fragment carrying a new `id` opens the next slot,
  and id-less fragments continue the latest slot. The `id` and
  `function.name` normally arrive in the first fragment (the name may also
  come in its own chunk without an `id`); `function.arguments` stream
  in pieces and are concatenated (the raw, still-JSON-escaped fragments are
  joined, then decoded once — matching the non-streamed path).
- Each content/reasoning chunk is decoded without `$(...)` stripping (a
  sentinel is appended and removed), so chunks that are only newlines
  (`"\n\n"`) survive reassembly.
- The last `choices/0/finish_reason` is kept.

When the stream ends (`data: [DONE]` or EOF), the subshell **synthesizes a
non-streamed chat-completion response** — `{"choices":[{"message":{"role":
"assistant","content":…,"reasoning":…,"tool_calls":[…]},"finish_reason":
…}]}` — and writes it to stdout, which `$(…)` captures into `HTTP_BODY`.
From there the existing `FLAT=$(…|json)` + `parse_response` + main loop run
**completely unchanged**. The live output goes to stderr (not captured), so
it does not pollute the tool results or the final answer.

The `AGENT_STREAM` setting is passed to `delegate` children (scrubbed from
the command environment like the rest of the `AGENT_*` set), so sub-agents
stream too.

## Command execution

**No sandbox of its own.** `agent.sh` runs each model command as a plain
child of the harness:

```sh
env -u AGENT_KEY -u AGENT_ENDPOINT ... setsid "$EXEC_SHELL" -c "$cmd" </dev/null
```

Sandboxing is the user's responsibility: wrap the script in whatever
sandbox they want (podman, bwrap, unshare, firejail, …) —
`bwrap --ro-bind / / --bind $WORKDIR /work -- agent.sh "$@"`,
`podman run --rm -v $PWD:/work ... agent.sh`, etc. The `-w` workdir is a
directory the model's commands start in (the system prompt tells it the
place to write files), not an enforcement.

A non-zero exit status is appended to the output as `[exit status: N]` so the
model can see the failure.

**Defense-in-depth (built into the harness, independent of any sandbox):**
- **Environment scrubbing:** each model command runs with the full
  `AGENT_*` set removed (key, task, workdir, …) so a prompt-injected
  command cannot read the API key or the task text.
- **Nothing on disk:** the request and response live in shell variables
  (see *HTTP transport*), so there is no request file holding the
  `Authorization` header to clean up.
- **Per-command timeout:** (`$CMD_TIMEOUT`, default 300; 0 = unlimited) the command runs in
  its own session (`setsid`); a watchdog SIGKILLs the whole process group on expiry (children and
  background jobs holding the output pipe included), reported as exit status 124. A background
  job with its output redirected survives the command.
- **Output truncation:** `head -c "$MAX_OUTPUT"` (default 16384, 0 = unlimited; a
  positive value caps each tool result in bytes). A cut result ends with a
  `[output truncated]` line (before any `[exit status: N]` line).
- **UTF-8 sanitising:** bytes of a tool result that are not valid UTF-8 are
  replaced with `?` (`utf8_clean`, C-locale `sed`) before the result goes
  into the request body — most servers reject invalid UTF-8 outright, which
  would abort the run. Valid multibyte text is untouched.

## Skills

A **skill** is `$WORKDIR/.agents/skills/<name>/SKILL.md` (the Agent Skills
convention): markdown with a `name:`/`description:` frontmatter, optionally
with bundled files (`references/`, `scripts/`) that the model reads through
the `shell` tool.

At startup the harness scans `$WORKDIR/.agents/skills/*/SKILL.md` and builds
the **`SKILL_LIST`** variable: one line per skill, `- <name> — <description>`
(description = the `description:` frontmatter line, or `(no description)`
when absent). `.agents/skills/` absent or empty → `SKILL_LIST` empty,
behavior identical to a skills-less target.

**System prompt:**
- The **default** prompt advertises the `skill(name)` tool and interpolates
  `SKILL_LIST` as an "Available skills:" section.
- A **custom** prompt (`-p` / `AGENT_SYSTEM_PROMPT`) may contain the literal
  token `$SKILL_LIST`; the harness replaces it with the list (empty when
  there are no skills). A custom prompt is used as given: the skills section
  (and the delegate / MCP sections) is added to the built-in prompt only, so no
  token → no list; the user can place the list
  anywhere or drop it entirely. Caveat: when the prompt comes from the
  environment, the user must quote it (e.g.
  `AGENT_SYSTEM_PROMPT='... $SKILL_LIST ...'`) so their own shell does not
  expand the token first.

**Tool:** the `skill` tool is added to the request's `tools` array only when
skills are present. `skill(name)`:
- name validated against `[A-Za-z0-9_-]+` (rejects `/`, `..`, empty — no
  traversal out of `.agents/skills/`);
- on success: the `SKILL.md` content (in full — skills are the user's own
  files, not model output, so no `max-output` cap) is the tool result;
- on failure: an error message listing the available skills (so the model
  can self-correct), returned as the tool result.

The main loop dispatches on `tool_calls[i].function.name` (`shell` →
`run_command`, `skill` → `load_skill`, `delegate` → `spawn_subagent`,
`mcp_*` → `mcp_call`; anything else → `unknown tool: <name>`); the assistant
message echoes the name the model sent. Each call's gate is `confirm` (always
yes unless `--ask`).

## Sub-agents (delegate)

A **sub-agent** is a nested `agent.sh` run that works a sub-task; its final
answer is the tool result. Enabled by `AGENT_SELF` — a path to `agent.sh`
or a URL (`http://` / `https://`) — and by `AGENT_DEPTH > 0` (CLI `-d` /
env, default `1`). `AGENT_SELF` unset or depth 0 → no `delegate` tool,
behavior unchanged.

**Spawn:** `delegate(task, timeout?)`:
- The child is a nested `agent.sh` with `AGENT_TASK` = `task`. Path form
  runs `busybox ash <path>` (paths with spaces are fine); URL form fetches it with `wget -q -O -` and
  pipes it into `busybox ash -s -` (no temp file).
- The child gets the parent's **resolved** settings (incl. `AGENT_MCP`) via explicit `AGENT_*`
  assignments (endpoint, model, key, params, shell, workdir, cmd-timeout,
  http-timeout, max-output, max-turns, stream) and `AGENT_DEPTH` = parent's depth − 1, so a
  default-depth child cannot delegate further.
- **Base prompt, not resolved:** with a custom `-p` the child gets the parent's system prompt
  *before* the skills-section / AGENTS.md additions; it re-derives those
  itself from the same workdir, so nothing is duplicated.
- The full `AGENT_*` set is scrubbed from the inherited environment (the
  same `env -u` list as `run_command`) — no parent task/key leak.
- `AGENT_ASK=0`: the child never prompts. In the parent's ask mode, the
  spawn itself is confirmed (`ask_prompt "delegate: <task>"`).
- **Blocking:** tool calls execute one at a time in order; a `delegate`
  call waits for the child's final answer before the next turn. No
  parallel sub-agents.
- **No total timeout by default** — the main agent has none either; the
  child runs until it finishes (each of its commands still has the
  per-command `CMD_TIMEOUT`). The optional `timeout` tool parameter
  (seconds) arms a watchdog; `0` (or a non-integer) means no timeout. The
  child runs in its own session (`setsid`) and on expiry the whole process
  group is SIGKILLed (like `run_command`), so the sub-agent's own commands
  die with it; the result reports exit status 124.
- Tool result = the child's final answer (stdout, truncated to
  `max-output`); on a non-zero exit the result is
  `delegate: sub-agent failed (exit N)` plus the child's output, and the
  parent loop continues (the model can retry or answer).

## Workspace instructions (AGENTS.md)

If `AGENTS.md` exists in the workdir (`-w` / `AGENT_WORKDIR`, default: the
launch directory), its content is appended to the system prompt under a
`Workspace instructions (AGENTS.md in the workdir):` header, before the
first request. The file is loaded in full (it is the user's own instructions,
not model output, so no `max-output` cap). A `-p`/`AGENT_SYSTEM_PROMPT`
override still gets the AGENTS.md appended (the file is the workspace's own
instructions, so it applies to any prompt). If the file is absent, nothing
changes.

## MCP (Model Context Protocol)

`agent.sh` can connect MCP servers and expose their tools to the model.
Configured with `-M name=url` / `AGENT_MCP` (see *CLI & config*): `name`
is a server label (validated `[A-Za-z0-9_-]+`), `value` is a `http://` or
`https://` URL of the server's Streamable HTTP endpoint.

**Transport: Streamable HTTP (MCP spec 2025-06-18).** MCP speaks JSON-RPC
2.0 over HTTP POST. Each request is one `busybox wget --post-file=/dev/stdin`
to the server URL (the same client the agent uses for the model endpoint),
with `MCP-Protocol-Version: 2025-06-18` set. The
body is read in-memory via `wget -O -` (headers stripped). The response is
either `application/json` (body is the JSON-RPC response) or
`text/event-stream` (SSE; the JSON-RPC response is the first `data:`
line carrying a `result` or `error`, else the first `data:` line, so
leading notifications are skipped). A broken server (bad URL, timeout, non-2xx status, parse error, a
JSON-RPC `error` reply to `initialize` or the first `tools/list`)
warns to stderr and is **skipped** — it never breaks the agent.

**Sessions:** `wget -S` prints the response headers on stderr; the
`Mcp-Session-Id` returned by `initialize` is kept per server and sent on
every later request (`notifications/initialized`, `tools/list`,
`tools/call`), so stateful servers work. Header lines are stripped from the
body before parsing.

**Limitations:** No
`Authorization` (or other custom) header is sent to MCP servers, so
servers that require authentication are not supported.

**Discovery (startup):** for each configured server, the harness runs the
MCP handshake: `initialize` (id 1) → `notifications/initialized`
(notification) → `tools/list` (id 1). The `tools/list` response's
`result.tools[]` is read;
each tool's `name`, `description`, and `inputSchema` are extracted;
`inputSchema` is **reconstructed verbatim** from the vendored json.sh flat
output (see *Schema reconstruction*). Advertised tool name =
`mcp_<name>_<tool>`, sanitized to the OpenAI name charset `[a-zA-Z0-9_-]`
(every other char → `_`), with collisions suffixed `_2`, `_3`, … (capped at
64 chars).

**Tool schemas:** the server's `inputSchema` (a JSON Schema) is passed
verbatim into the OpenAI tool definition's `parameters`. Missing/absent
`inputSchema` (or an empty `{}`) → `{"type":"object"}`.

**Tool calls:** the model's `arguments` (the tool-call arguments string, a
JSON object) is embedded directly as `tools/call` `params.arguments`
(empty → `{}`). `tools/list` follows `nextCursor` (up to 20 pages). Result handling: JSON-RPC `error` → `mcp error: <msg>`;
`result.content[]` → concatenate all `type:text` blocks (a non-text block becomes `[<type> content omitted]`);
`result.isError: true` → prefix `mcp tool error:` (`false` → no prefix); plain-string result → as-is.
Truncated to `max-output` like every other tool result. Ask mode (`-a`)
confirms each call (`ask_prompt "mcp <name>: <args>"`), same y/n/q
semantics as `shell`/`delegate`.

**System prompt:** when MCP tools are present, the default prompt advertises
them in a "You also have MCP tools…" section (like the `skill` and `delegate`
tool sections). Custom prompts simply don't mention them (the tools are still
present).

**Schema reconstruction (`json_from_flat`).** The vendored json.sh flattens
a JSON object to `/path type value` lines (leaves, plus a `/path array` /
`/path object` marker for empty containers). To emit a raw `inputSchema` object, `json_from_flat <flat>
<prefix>` reconstructs the node at `prefix`: a node whose children are
integer-indexed (0,1,2,…) is an array, otherwise an object; leaf strings
are double-decoded (flat body carries the JSON-escaped body, like
`get_tc_args` → `extract_command`). Limitation: object keys containing `/`
are ambiguous in the flat encoding and are unsupported.

**Environment scrubbing:** `AGENT_MCP` is passed to `delegate` children
(the child re-discovers its servers at startup). The MCP server is a remote
HTTP endpoint (not a spawned process), so there is no per-server env
scrub — the harness's own env is scrubbed before the `wget` call.

**Transport constraint:** `busybox wget` is the HTTP client
(no `curl`). This works on minimal embedded targets where `npx`,
`python`, and `node` are absent — the MCP server is a remote HTTP
endpoint, not a local process to spawn.

## Safety

- **No deny-list** (dropped): the harness does not pattern-match commands;
  the user's sandbox (if any) is the guard against destructive commands.
- **Output truncation:** `head -c "$MAX_OUTPUT"` (default 16384, 0 = unlimited; `-O` /
  `AGENT_MAX_OUTPUT`) on every tool result.
- **Timeout:** per-command watchdog kill of the process group (default 300; 0 = unlimited; `-T` /
  `AGENT_TIMEOUT`); model requests are cut off after `-H` / `AGENT_HTTP_TIMEOUT`
  seconds of silence (default 300).
- **`--ask` (`-a`):** confirm each command before running (y/n/q). Off by
  default — commands run without confirmation unless set.

## Test plan

1. **Podman busybox container** (rootless, `podman run --rm`): the proving
   ground for the applet-only constraint — the container has only busybox
   applets, so if `agent.sh` works there, the constraint holds. Run against
   a local Ollama on `:11434`.
2. **Real embedded target** (the user's, when picked up) — same smoke test.
3. Acceptance criteria:
   - Multi-turn task succeeds, e.g. *"create a file, list it, read it back"*
     (3+ tool calls, plain-text final answer).
   - `--ask` prompts per command; `n` feeds DENIED back; without it,
     commands run without confirmation.
   - JSON escaping round-trips a command with quotes, backslashes, newlines.
   - `SHELL=/bin/bash` on the dev host; unset `SHELL` in the container
     falls back to `sh`; `-s /bin/ash` overrides both.
    - Skills: with a `.agents/skills/` dir present, the model loads a skill via the
      `skill` tool and follows its instructions; unknown skill name → error
      listing available skills; `../` and names with `/` are rejected; no
      `.agents/skills/` dir → no `skill` tool in the request, behavior unchanged.
    - MCP: with `-M name=url`, the model calls an MCP tool by its advertised
      name (`mcp_<name>_<tool>`) and gets the server's result; no `-M` → no
      MCP tools, behavior unchanged; bad server URL → warning + agent
      continues without it; `AGENT_MCP` env form; `--ask` confirms/denies an
      MCP call; `delegate` child inherits `AGENT_MCP`.
   - Single file runs unmodified on bare busybox (no host tools).

## Deliverables

- `agent.sh` — the agent (single file).
- `README.md` — what it is, how to run it, options, tools, safety, tests.
- `SPEC.md` — this document (wire protocol, CLI, env vars).
- `tests/` — the test suite (`busybox ash tests/run_tests.sh`).
