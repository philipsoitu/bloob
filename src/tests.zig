const std = @import("std");

test {
    _ = @import("text.zig");
    _ = @import("style.zig");
    _ = @import("theme.zig");
    _ = @import("frame.zig");
    _ = @import("key.zig");
    _ = @import("editor.zig");
    _ = @import("messages.zig");
    _ = @import("lua/runtime_test.zig");
    _ = @import("core/workspace.zig");
    _ = @import("tools/permissions.zig");
    _ = @import("tools/tools.zig");
    _ = @import("tools/shell_job.zig");
    _ = @import("providers/stream.zig");
    _ = @import("providers/request.zig");
    _ = @import("providers/registry.zig");
    _ = @import("headless.zig");
    _ = @import("sessions/store.zig");
    _ = @import("sessions/compat.zig");
}
