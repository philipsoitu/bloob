# Security

bloob executes user configuration as Lua code inside the agent process. The
current security boundary is:

- **Zig owns permissions and workspace checks.**
- **Lua configuration is trusted code.** LuaJIT is not sandboxed.

This document describes what is actually enforced in this checkpoint, including
known gaps. Do not treat the design notes as a promise that every protection is
implemented.

## Trust model

bloob opens the LuaJIT standard libraries and exposes LuaJIT FFI. A config can:

- read environment variables and files;
- run processes (`os.execute`, `io.popen`);
- call into native libraries with `ffi`;
- register tools and event handlers;
- mutate UI state and send commands.

There is no capability sandbox around the Lua state. A malicious `init.lua` is
equivalent to running a program with the user's privileges. Only run configs you
trust.

What limits accidental exposure:

- Project-local `.bloob/init.lua` is **not** loaded automatically.
- The default config path is the user's own `$XDG_CONFIG_HOME/bloob/init.lua`.
- `--config PATH` loads exactly the path you pass.
- `--no-config` skips user configuration entirely.
- Bundled defaults are embedded in the binary and are always loaded.

What is missing:

- `--safe-mode` is parsed but currently has no effect.
- There is no project-config trust prompt or allow-list.
- There are no third-party plugins yet (`bloob.features.plugins = false`).
- There is no signature verification, audit trail or Lua sandbox.
- Config-local module loading is not actually available during the initial load
  because `package.path` is extended after execution; do not rely on it.

If you open an untrusted repository, prefer:

```sh
bloob --no-config --model mock/fixture
```

## Tool permission engine

Native tools are evaluated in Zig before execution. The default policy is:

| Capability | Default |
| --- | --- |
| workspace read | allow |
| workspace write | ask |
| shell | ask |
| network | ask |
| git read | allow |
| git write | ask |
| custom | ask |

Evaluation also applies hard denials:

- every target path is checked against the workspace root;
- symlinks are resolved and must stay inside the workspace;
- writes to `.git` internals are refused;
- sensitive names are denied, including `.env*`, `.npmrc`, `.pypirc`,
  `.netrc`, `.git-credentials`, `credentials`, `credentials.json`, `id_rsa`,
  `id_ed25519`, `id_ecdsa`, `known_hosts`, and paths under `/.ssh/`, `/.aws/`
  or `/.gnupg/`.

Write and edit requests still require approval even if the policy is set to
allow. The interactive approval modal offers deny/allow once/allow session.
Denying adds a tool error to the conversation and the agent continues without
executing it.

The permission policy is not configurable through Lua yet. `bloob.setup({ permissions = ... })` is accepted and ignored.

### Built-in tool bounds

The native tools are bounded:

- `read_file`: 256 KiB, binary/NUL detection, workspace-confined;
- `write_file`/`edit_file`: 2 MiB content limit, atomic writes, workspace
  confinement, `.git` refusal;
- `shell`: 30 s default timeout, 120 s maximum, 256 KiB output capture, optional
  workspace-relative cwd;
- `list_files`: bounded entry count (default 500, maximum 2000);
- `search`: ripgrep, bounded result count (default 200, maximum 1000);
- git tools: bounded output and workspace cwd.

These bounds reduce accidental resource use; they are not a sandbox against a
malicious config or a compromised native dependency.

## Events and hook authority

`tool.before_execute` runs after the Zig decision and before approval/execution.
A Lua hook may:

- return `nil`/pass;
- deny (`false`, `"deny"`, `{ action = "deny" }`);
- escalate an allow to ask (`"ask"`, `{ action = "ask" }`).

It cannot turn a Zig denial into an allow. See [events.md](events.md).

Hooks run synchronously with traceback protection. A handler error is shown as a
notification and does not crash the app, but a handler can still perform
arbitrary Lua/FFI work because config code is trusted.

## Lua tools

`tools.register` is available, but custom tools are **not** sandboxed:

- The Zig engine treats a Lua tool as the `custom` capability, which asks by
  default.
- The `permissions = { ... }` field is serialized as metadata only; no Zig code
  currently enforces it.
- `run(ctx, args)` executes in-process Lua with full standard-library and FFI
  access.
- Arguments come from the model and are untrusted data. Do not treat them as
  code, file paths to trust, or shell fragments without your own validation.
- There is no public `ctx:read_file`/`ctx:write_file` API yet. Do not use the
  private `bloob._read_file`: its host implementation reads from the process
  working directory without the workspace/sensitive-path checks used by the
  native `read_file` tool. It is an internal bridge, not a security boundary.
- Tool results are inserted into the conversation as text and should be treated
  as untrusted by the model and UI.

Only register tools you are prepared to have an LLM invoke with arbitrary
arguments. If a tool needs filesystem or network access, validate inputs and
prefer native tools once a checked Lua API exists.

## Untrusted content and rendering

Model output, tool output and repository text are untrusted. The UI sanitizes
terminal escape sequences before drawing text and truncates very large tool
output. The conversation is presented as text/markdown-like content, not as
executable markup. Do not assume that sanitization is a complete content-security
policy.

Avoid printing secrets in notifications, logs or tool results. Configuration has
access to the process environment, including provider API keys; a config that
logs them leaks them.

## Secrets and providers

Provider credentials come from environment variables:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- optional `OPENAI_BASE_URL` / `BLOOB_OPENAI_BASE_URL`
- optional `BLOOB_ANTHROPIC_BASE_URL`
- optional `BLOOB_COMPAT_BASE_URL`, `BLOOB_COMPAT_API_KEY`

They are read by the Zig provider resolver. Lua config can also read them with
`os.getenv`. bloob has no secret manager, keyring integration or redaction layer
in this build.

Provider requests send the conversation, tool schemas and (for native tools)
your workspace paths/content to the configured endpoint. Review the provider and
base URL you configure. A compatible endpoint can see the same prompt and tool
traffic.

## Headless and persistence

- `--print` does not create the Lua runtime, does not load config and currently
  supports only the mock/fixture provider.
- There are no sessions, transcripts or JSONL persistence yet, so there is no
  stored-history exposure to audit or delete.
- Approval interaction exists only in the interactive TUI. Do not assume that a
  headless or future automation path enforces the same approval policy until it
  is implemented and documented.

## Hardening checklist

- Run `bloob --no-config` in untrusted repositories.
- Review any config that uses `ffi`, `os.execute`, `io.popen` or absolute paths.
- Keep provider keys in the environment, not in `init.lua`.
- Do not grant a Lua tool more authority than its model-facing schema implies.
- Treat `tool.before_execute` as a brake, not as a grant.
- Avoid logging full tool arguments or file contents.
- Use `reset`/`stty sane` if a crash leaves the terminal unusable.
- Re-check this document before relying on a security property; the permission
  and plugin layers are still under active implementation.
