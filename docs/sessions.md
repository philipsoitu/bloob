# Session persistence

`src/sessions/` implements durable, local session storage for bloob. It is
independent of the application loop and can be tested without LuaJIT:

```sh
nix develop -c zig test src/sessions/store.zig
```

## Location

The `Store` is opened with an explicit sessions directory. The default helper
uses the XDG data directory:

```text
$XDG_DATA_HOME/bloob/sessions
# or, when XDG_DATA_HOME is unset/relative:
$HOME/.local/share/bloob/sessions
```

```zig
var data_dir = try sessions.Store.defaultDataDir(init.gpa, init.environ_map);
defer init.gpa.free(data_dir);
var store = try sessions.Store.init(init.gpa, init.io, data_dir);
defer store.deinit();
```

`Store.init` creates the directory if needed and applies restrictive POSIX
permissions: the sessions directory is `0700`, and every session file is
`0600`. It does not require root and does not touch the user's config directory.

## Files

Each session has two files:

```text
<id>.jsonl       append-only conversation + initial header
<id>.meta.json   latest metadata snapshot, replaced atomically
```

`<id>` is an opaque 128-bit random value encoded as 32 lowercase hex characters.
Only `[A-Za-z0-9_-]` ids are accepted by `load`, `delete`, and `list`, so an id
can never escape the sessions directory.

### `<id>.jsonl`

The first line is a JSON object header:

```json
{"type":"session","schema_version":1,"id":"<id>","created_at_ms":1763500000000,"updated_at_ms":1763500000000,"cwd":"/work/project","model":"provider/model","message_count":0}
```

Every subsequent non-empty line is one message:

```json
{"type":"message","id":1,"role":"user","text":"hello","timestamp_ms":1763500000100,"model":null,"streaming":false,"tool_calls":[],"tool_call_id":null,"tool_name":null,"tool_is_error":false,"usage":{"prompt_tokens":0,"completion_tokens":0,"reported":false}}
```

Tool results use `role:"tool"` with `tool_call_id`, `tool_name`, and
`tool_is_error`. Assistant tool requests use `tool_calls` entries with
`id`, `name`, and `args`. Usage values and per-message timestamps are preserved.
`streaming` is always written as `false`; a resumed session never starts in a
half-live streaming state.

Messages are appended one complete line at a time and synced before
`appendMessage` returns. The message content is copied, so the caller keeps
ownership of the in-memory `Message`.

### `<id>.meta.json`

A small JSON object with the same metadata fields, but `"type":"meta"`. It is
written through a temporary file followed by `rename`, so readers see either the
old complete snapshot or the new complete snapshot, never a partial file.
`appendMessage` and `updateMeta` refresh it. It intentionally contains no
message text or tool output.

The sidecar is an optimization and a recovery aid, not a second source of truth:
if it is missing, corrupt, or has an unknown id/schema, the JSONL header is used
instead. If a process crashes between appending a message and refreshing the
sidecar, `load` recomputes the actual message count from the JSONL.

## Format versioning and bounds

The current schema version is `1`. Readers accept known older versions and
reject a newer version with `error.IncompatibleSchemaVersion`; this is a clear
signal that the binary is too old to safely interpret the file. `list` skips
unreadable or future-version entries rather than failing the whole listing.

Limits are enforced before writes and while loading:

| Limit | Value |
| --- | --- |
| Header / metadata line | 16 KiB |
| One encoded message line | 4 MiB |
| Message text | 2 MiB |
| Session file | 64 MiB |
| Messages per session | 100,000 |
| Tool calls per message | 128 |
| CWD | 4 KiB |
| Model name | 512 B |

## Crash recovery

`load` validates the header, then each message line in order.

- An **incomplete final line** (no trailing newline) is treated as an
  uncommitted append. It is dropped and the file is truncated to the last
  complete record before `load` returns.
- A **malformed final line** (with or without a newline) is also treated as a
  trailing corruption and truncated.
- A malformed line **followed by another non-whitespace line** is a hard
  `error.CorruptSession`. Silently dropping a middle message would corrupt the
  conversation semantics.
- A truncated/corrupt header is `error.CorruptHeader`.
- A missing session file is `error.FileNotFound`.
- `appendMessage` refuses to append unless the current file ends in a newline
  (`error.CorruptTrailingLine`), so it cannot compound a corrupt tail.

After truncation, `Session.recovered_tail` is `true`, and the metadata sidecar is
refreshed with the actual recovered message count. The next append is safe.

## API

```zig
pub const Store = struct {
    pub fn init(gpa, io, data_dir) !Store;
    pub fn deinit(self: *Store) void;

    pub fn create(self: *Store, cwd: []const u8, model: []const u8) !Session;
    pub fn load(self: *Store, id: []const u8) !Session;
    pub fn list(self: *Store) ![]SessionInfo;
    pub fn appendMessage(self: *Store, session: *Session, message: anytype) !void;
    pub fn updateMeta(self: *Store, session: *Session) !void;
    pub fn delete(self: *Store, id: []const u8) !void;
};
```

`appendMessage` is generic over the message value and only reads the existing
fields (`role`, `text.items`, `tool_calls.items`, `usage`, etc.), so the
application can pass `*src/messages.zig.Message` directly without an adapter.

`Session` owns its id, path, cwd, model, and a local `Conversation` of local
`Message` values. `SessionInfo` rows own their strings; free a list with:

```zig
const infos = try store.list();
defer sessions.freeInfoList(gpa, infos);
```

`list` returns sessions newest-first by `updated_ms`, with id as a deterministic
tie-breaker. `message_count` in the sidecar is refreshed on append; after a hard
crash it may lag until the next `load`/append/updateMeta.

## Conversion to `src/messages.zig`

The store is also testable as a standalone module root
(`zig test src/sessions/store.zig`, which cannot import files above
`src/sessions/`). It therefore uses `src/sessions/types.zig`, a field-for-field
mirror of the public conversation types. `src/sessions/compat.zig` provides
explicit conversion in both directions:

```zig
const compat = @import("sessions/compat.zig");

// loaded session -> normal app conversation
var conversation = try compat.conversationToNative(gpa, &session.conversation);
defer conversation.deinit();

// normal app message -> store message (appendMessage can also use the native
// message directly)
var stored = try compat.fromNative(gpa, &native_message);
defer stored.deinit(gpa);
```

`src/messages.zig` itself is unchanged.

## What is not stored

Session files contain the model name, working directory, message text, tool
names/arguments/results, usage counters, and timestamps. They do not contain API
keys, environment dumps, credentials, or terminal contents. Application code
must still treat session text and tool output as user data and avoid writing
secrets into prompts or tool arguments.

## Integration checklist

1. Resolve `data_dir` with `Store.defaultDataDir` and open `Store` at startup.
2. On first message, `create(cwd, model)`; retain the returned `Session`.
3. After adding a message to the app conversation, call `appendMessage` with it.
4. Call `updateMeta` when cwd/model changes or the app wants a metadata refresh.
5. On resume, `load(id)`; convert `session.conversation` with `compat` if the app
   keeps a native conversation.
6. Use `list` for a resume picker and `delete` for removal.

The store is intended for one process per session at a time. Concurrent writers
are not coordinated beyond the append-only line boundary; the sidecar can be
replaced by the last writer, and JSONL remains valid because each writer appends
complete lines.
