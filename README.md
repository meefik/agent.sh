# agent.sh

Copyright (C) 2026 Anton Skshidlevsky (meefik), MIT

A very small LLM agent written in `ash` (busybox's POSIX shell). One
executable, **only busybox applets** — no jq, no python, no curl. It works on
embedded systems, runs on a read-only root, and speaks the OpenAI
`tools` protocol natively: the model asks for a tool, the harness runs it,
feeds the result back, and loops until the model answers in plain text.

## Install busybox

First you need the [busybox binary](https://busybox.net/downloads/binaries/):

```sh
wget -O /bin/busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x /bin/busybox
```

## Usage

Point it at any OpenAI-compatible `/v1/chat/completions` endpoint and give it a
task:

Start with a local model (e.g. [Ollama](https://ollama.com)). No key is needed,
and nothing leaves your machine. These are the defaults, so the endpoint and
model can be omitted:

```sh
export AGENT_ENDPOINT="http://localhost:11434/v1"
export AGENT_MODEL="qwen3"

busybox ash agent.sh "What is today's date?"
```

The agent runs `date`, reads the output, writes the answer, and stops when
done. Add `-a` to approve each command before it runs, and `-S` to stream the
model's output:

```sh
busybox ash agent.sh -a -S "What is today's date? Use the 'date' command to find out."
```

A hosted OpenAI-compatible endpoint works the same way; set the key too:

```sh
export AGENT_ENDPOINT="https://api.openai.com/v1"
export AGENT_KEY="sk-..."
export AGENT_MODEL="gpt-4o-mini"

busybox ash agent.sh "show disk usage per top-level directory in /home and name the biggest one"
```

The agent runs the model's commands as plain children of the harness and prints
the final answer to stdout. Diagnostics go to stderr.

## Options

```
agent.sh [-e endpoint] [-m model] [-k key] [-p system-prompt]
         [-s shell] [-t max-turns] [-T cmd-timeout] [-O max-output]
         [-H http-timeout]
         [-a|--ask] [-S|--stream] [-w workdir] [-d depth]
         [-P key=value] [-M name=url] <task...>
```

| option | env var | default |
|---|---|---|
| `-e` endpoint | `AGENT_ENDPOINT` | `http://localhost:11434/v1` |
| `-m` model | `AGENT_MODEL` | `qwen3` |
| `-k` key | `AGENT_KEY` | *(empty)* |
| `-p` system prompt | `AGENT_SYSTEM_PROMPT` | *(built-in)* |
| `-s` execution shell | `AGENT_SHELL` | `$SHELL`, else `sh` |
| `-t` max tool-loop turns | `AGENT_MAX_TURNS` | `0` (unlimited; a positive value caps the loop) |
| `-O` per-command output cap (bytes) | `AGENT_MAX_OUTPUT` | `16384` (`0` = unlimited; a positive value caps each tool result) |
| `-T` per-command timeout (s) | `AGENT_TIMEOUT` | `300` (`0` = unlimited; a positive value is the per-command timeout) |
| `-H` model-request timeout (seconds) | `AGENT_HTTP_TIMEOUT` | `300` (per-read wget timeout; `0` = busybox default) |
| `-a` / `--ask` | `AGENT_ASK` | `0` (off; `-a` or any other non-empty, non-`0` value confirms each command) |
| `-S` / `--stream` | `AGENT_STREAM` | `0` (off; `-S` or any other non-empty, non-`0` value streams the model's output live) |
| `-w` workdir | `AGENT_WORKDIR` | the current directory (where skills and `AGENTS.md` are loaded from, and the place the model is told to write; the agent `cd`s into it, so commands start there) |
| `-d` delegation depth | `AGENT_DEPTH` | `1` |
| *(none)* | `AGENT_SELF` | *(empty; path or URL to `agent.sh`; enables `delegate`)* |
| `-P` key=value (repeatable) | `AGENT_PARAMS` (semicolon-separated) | *(empty)* |
| `-M` name=url (repeatable) | `AGENT_MCP` (semicolon-separated) | *(empty)* |
| `<task...>` | `AGENT_TASK` | *(empty; required, or piped on stdin)* |

`-t`, `-T`, `-O`, `-H` and `-d` must be non-negative integers. `-P` sets a
model parameter (e.g. `-P temperature=0.7 -P enable_thinking=true`; the value is
a number, `true`/`false`/`null`, or raw JSON). `-h`/`--help` prints the usage.

Every option also has an `AGENT_*` env default, so the script runs with **no
arguments at all** — the intended `wget | ash -s -` usage:

```sh
AGENT_TASK="..." AGENT_KEY="..." busybox wget -qO - https://github.com/meefik/agent.sh/raw/main/agent.sh | busybox ash -s -
```

With no task given, the task is read from stdin when it is piped:

```sh
cat task.md | busybox ash agent.sh
```

(`--ask` answers are then read from `/dev/tty`.)

## Tools

The model gets a small set of native tools:

- **`shell(command)`** — always present. Runs a command under the execution
  shell (`-s`/`$SHELL`/`sh`) and returns combined stdout/stderr, truncated.
- **`skill(name)`** — present when `$WORKDIR/.agents/skills/<name>/SKILL.md` files
  exist. Loads the skill's text (the Agent Skills convention); the skill list
  goes into the system prompt.
- **`delegate(task, timeout?)`** — present when `AGENT_SELF` is set (a path or
  URL to `agent.sh`) and depth > 0. Spawns a nested `agent.sh` for a sub-task;
  the child's final answer is the tool result.
- **`mcp_<server>_<tool>`** — present when MCP servers are configured (`-M` /
  `AGENT_MCP`). Each tool a server advertises is exposed as one tool.

## MCP servers

`-M name=url` connects a [Model Context Protocol](https://modelcontextprotocol.io)
server over **Streamable HTTP** and exposes its tools to the model as
`mcp_<name>_<tool>`.

### 1. Start an MCP server

The harness only speaks HTTP, so run the server on a machine that has Node (or
Python), not necessarily the target. Most public servers use stdio, so wrap one
with a stdio-to-HTTP bridge such as
[supergateway](https://github.com/supercorp-ai/supergateway):

```sh
npx -y supergateway \
    --stdio "npx -y @modelcontextprotocol/server-filesystem /tmp" \
    --outputTransport streamableHttp --port 8081
```

The endpoint is now `http://localhost:8081/mcp`. If your server already
speaks Streamable HTTP, skip the bridge and use its URL directly.

### 2. Connect the agent

```sh
busybox ash agent.sh -M "fs=http://localhost:8081/mcp" \
    "list the files in /tmp and tell me which is the largest"
```

The model now sees tools like `mcp_fs_list_directory` and
`mcp_fs_read_file`. Add `-a` to approve each MCP call before it runs.

### 3. Several servers

Repeat `-M`, or set `AGENT_MCP` (semicolon-separated):

```sh
export AGENT_MCP="fs=http://localhost:8081/mcp;git=http://localhost:8082/mcp"
busybox ash agent.sh "summarize the last 5 commits and save it to /tmp/summary.txt"
```

The transport uses `busybox wget` as the HTTP client (no `curl`), so the
target itself needs no `npx`, `python`, or `node`. The `Mcp-Session-Id` header
is read via `wget -S` and sent back, so stateful servers work. A broken server
warns and is skipped; it never breaks the agent.

## Streaming

`-S` / `--stream` streams the model's output live to stderr as it works
(SSE `stream: true`), then reassembles the turn into a normal response. The
final answer is still on stdout. Thinking models' reasoning is shown live
prefixed with `[thinking]` (once per reasoning block).

## Safety

There is no sandbox of its own — wrap the script in whatever sandbox you want
(podman, bwrap, unshare, firejail, …). The harness adds the layers that don't
depend on a sandbox:

- **Env scrubbing** — every model command runs with the full `AGENT_*` set
  removed (key, task, workdir, …) so a prompt-injected command cannot read them
  casually. This is not a security boundary: a same-user process can still read
  `/proc/$PPID/environ` (and `cmdline`, e.g. with `-k`), so use a sandbox.
- **Per-command timeout** (`-T`, default 300 s; the whole process group is killed, 
  not just the shell) and **output truncation** (`-O`; the `[exit status: N]` line is kept).
- **`--ask`** — confirm each command before it runs (y/n/q); off by default.
  Answers are read from stdin (or `/dev/tty` when the script is piped in via `ash -s -`).
  Model commands run with stdin on `/dev/null`.

## Tests

A self-contained test suite lives in [`tests/`](./tests) — unit tests on the
real functions and integration tests that run the whole agent against pure-
busybox mock endpoints (no python). Run it:

```sh
busybox ash tests/run_tests.sh
```
