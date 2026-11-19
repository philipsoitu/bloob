# Troubleshooting

## Terminal looks broken after a crash

Normal exits restore raw mode/alternate screen/mouse/paste. Zig panics abort
without unwinding, so a crash can leave the terminal in raw mode. Recover with:

```sh
reset
# or
stty sane
```

Then report the panic with the command that triggered it.

## `bloob` says "cannot start interactive TUI: NotATerminal"

`bloob` needs a TTY on stdin/stdout. Use `--print` / `--json` for scripts, or run
inside a real terminal. CI/PTY harnesses can use `script`.

## Provider errors

- `API key is not set`: export `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` or set
  `BLOOB_COMPAT_BASE_URL` (+ optional `BLOOB_COMPAT_API_KEY`) for a local
  OpenAI-compatible endpoint.
- `Model must be provider/model`: use e.g. `--model openai/<model-id>` or
  `--model compat/<model-id>`.
- HTTP/SSE errors appear in the chat/status and stderr. API keys are redacted
  from normal errors and are not stored in sessions.
- `curl` must be on `PATH` for real providers.

## Config does not load

Check `bloob --doctor` for the resolved config path and existence. `--no-config`
wins over `--config`. Lua syntax errors are shown as a notification and the
previous/default UI is kept. Project-local `.bloob/` config is never auto-loaded.

For local modules, put them under the config directory (`lua/foo.lua` or
`foo.lua`) and `require("foo")`. The path is added before `init.lua` runs.

## Config reload failed

`Ctrl-R` builds a candidate runtime; on syntax/runtime/layout errors the previous
runtime is kept and an error is shown. Custom theme registrations from the failed
candidate may remain until restart; theme/model are rolled back.

## A tool is denied

The Zig permission engine is authoritative. Read-only workspace tools default to
allow; edits/shell/custom tools default to ask. Sensitive paths, symlinks to
sensitive files, outside-workspace targets, `.git` internals and credential
files are ground-denied. Headless mode denies approval-gated tools.

## Session resume

`--list-sessions` prints IDs. `--resume` loads the latest; `--session ID` loads a
specific one. Corrupt trailing JSONL is truncated on load; earlier corruption is
reported and not silently repaired. Delete a bad session with
`--delete-session ID`.

## CJK/emoji alignment

bloob uses a conservative wcwidth table for combining/wide glyphs. Some
terminals disagree about emoji width or variation selectors; report the glyph,
terminal and width. RTL shaping is not implemented (characters are laid out
left-to-right).
