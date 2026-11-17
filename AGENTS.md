# agent.sh — working instructions

A single-file `ash` LLM agent. One executable, **only busybox applets**
(no jq, python, curl) — the harness must run on a read-only root and
embedded targets.

## Hard constraints

- **busybox ash only.** No bashisms: no arrays, no `[[`, no here-strings.
  busybox-ash extensions (`local`, `${s//a/b}`, `$'\n'`, `${s:0:4}`) are
  used on purpose; the script is not dash-compatible. Verify with `busybox ash -n agent.sh` and by running under
  busybox (not the host's bash/dash).
- **Busybox applets only** in the harness. `busybox wget --post-file` (the HTTP
  client for both the model endpoint and MCP, run via `$BB`), `sed`, `grep`, `head`,
  `printf`, `wc`, `timeout`, `env`.
- **One file.** Everything lives in `agent.sh`; the vendored `json.sh`
  functions stay inlined.
- **In-memory request/response.** No `mktemp`, no temp files, nothing
  sensitive on disk — the agent must work on a read-only root.
- **No sandbox in the harness.** The user wraps `agent.sh` in whatever
  sandbox they want; the harness runs each command as a plain child
  (env scrub + timeout + output truncation).
- Every CLI option has an `AGENT_*` env default; the script must run with
  **no arguments** (`curl | ash -s -`). Keep the two in sync.

## Working rules

- **Keep the code simple and concise.** Prefer the smallest change that
  works; avoid extra abstractions, options, and defensive code the task
  doesn't need. Every line ships in one file that targets embedded
  systems, so less is better.
- **Mind performance.** Targets are slow, low-memory CPUs. Prefer shell
  builtins and parameter expansion over forking `sed`/`grep`/`printf` in
  loops or per character, and avoid re-scanning large strings (payloads,
  model output) repeatedly.
- `SPEC.md` is the source of truth for the wire protocol, CLI, and env
  vars — update it in the same commit as the code it describes.
- `README.md` is the user-facing doc — update it when user-visible behavior changes.
- **Conventional commits** (`fix:`, `feat:`, `test:`, `docs:`); body
  explains *why*, and notes what was verified.
- Test suite: `busybox ash tests/run_tests.sh` (425 tests). The mocks are
  pure busybox applets — they double as proof of the embedded constraint.
  New behavior gets tests; unit tests extract the *real* functions from
  `agent.sh` by name.
- The model's shell commands may run anything on the target — the
  busybox-only rule applies to the harness, not to what the model does.
- `AGENTS.md` in the workdir and skills in `.agents/skills/<name>/SKILL.md`
  are loaded into the agent's context at runtime — this file is an example
  of the convention this repo follows.
