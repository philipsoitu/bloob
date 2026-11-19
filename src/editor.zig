//! Multiline prompt editor with UTF-8-safe cursor movement, undo/redo and history.
const std = @import("std");
const text = @import("text.zig");

const Snapshot = struct {
    text: []u8,
    cursor: usize,
};

pub const VLine = struct {
    start: usize,
    end: usize,
    logical: usize,
};

pub const Editor = struct {
    gpa: std.mem.Allocator,
    clock_ms: i64 = 0,
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    preferred_col: ?usize = null,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,
    history: std.ArrayList([]u8) = .empty,
    history_index: usize = 0,
    draft: []u8 = &.{},
    last_edit_ms: i64 = 0,
    max_bytes: usize = 1024 * 1024,

    pub fn init(gpa: std.mem.Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.gpa);
        for (self.undo_stack.items) |s| self.gpa.free(s.text);
        self.undo_stack.deinit(self.gpa);
        for (self.redo_stack.items) |s| self.gpa.free(s.text);
        self.redo_stack.deinit(self.gpa);
        for (self.history.items) |h| self.gpa.free(h);
        self.history.deinit(self.gpa);
        if (self.draft.len > 0) self.gpa.free(self.draft);
    }

    fn nowMs(self: *Editor) i64 {
        return self.clock_ms;
    }

    fn snapshot(self: *Editor) !Snapshot {
        return .{ .text = try self.gpa.dupe(u8, self.text.items), .cursor = self.cursor };
    }

    fn freeSnapshots(self: *Editor, list: *std.ArrayList(Snapshot)) void {
        for (list.items) |s| self.gpa.free(s.text);
        list.clearRetainingCapacity();
    }

    fn pushUndo(self: *Editor, force: bool) void {
        const now = self.nowMs();
        if (!force and self.undo_stack.items.len > 0 and now - self.last_edit_ms < 700) {
            self.last_edit_ms = now;
            return;
        }
        self.last_edit_ms = now;
        const s = self.snapshot() catch return;
        self.undo_stack.append(self.gpa, s) catch {
            self.gpa.free(s.text);
            return;
        };
        if (self.undo_stack.items.len > 100) {
            const old = self.undo_stack.orderedRemove(0);
            self.gpa.free(old.text);
        }
        self.freeSnapshots(&self.redo_stack);
    }

    pub fn effectiveLen(self: *Editor) usize {
        return self.text.items.len;
    }

    fn prevBoundary(self: *Editor, index: usize) usize {
        if (index == 0) return 0;
        var i = index - 1;
        while (i > 0 and (self.text.items[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    fn nextBoundary(self: *Editor, index: usize) usize {
        if (index >= self.text.items.len) return self.text.items.len;
        var i = index + 1;
        while (i < self.text.items.len and (self.text.items[i] & 0xC0) == 0x80) i += 1;
        return i;
    }

    fn clampCursor(self: *Editor) void {
        if (self.cursor > self.text.items.len) self.cursor = self.text.items.len;
        while (self.cursor > 0 and self.cursor < self.text.items.len and (self.text.items[self.cursor] & 0xC0) == 0x80) {
            self.cursor -= 1;
        }
    }

    pub fn setText(self: *Editor, bytes: []const u8) !void {
        self.pushUndo(true);
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, bytes);
        self.cursor = self.text.items.len;
        self.preferred_col = null;
    }

    pub fn clear(self: *Editor) void {
        self.pushUndo(true);
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.preferred_col = null;
    }

    pub fn insertText(self: *Editor, bytes: []const u8, force_undo: bool) !void {
        if (bytes.len == 0) return;
        if (self.text.items.len + bytes.len > self.max_bytes) return error.TooLarge;
        self.pushUndo(force_undo);
        try self.text.insertSlice(self.gpa, self.cursor, bytes);
        self.cursor += bytes.len;
        self.preferred_col = null;
    }

    pub fn insertCodepoint(self: *Editor, cp: u21) !void {
        var buf: [4]u8 = undefined;
        try self.insertText(text.encode(cp, &buf), false);
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        self.pushUndo(false);
        const prev = self.prevBoundary(self.cursor);
        self.text.replaceRange(self.gpa, prev, self.cursor - prev, &.{}) catch return;
        self.cursor = prev;
        self.preferred_col = null;
    }

    pub fn deleteForward(self: *Editor) void {
        if (self.cursor >= self.text.items.len) return;
        self.pushUndo(false);
        const next = self.nextBoundary(self.cursor);
        self.text.replaceRange(self.gpa, self.cursor, next - self.cursor, &.{}) catch return;
        self.preferred_col = null;
    }

    pub fn deleteWordBackward(self: *Editor) void {
        if (self.cursor == 0) return;
        self.pushUndo(true);
        var start = self.cursor;
        while (start > 0) {
            const p = self.prevBoundary(start);
            const d = text.decode(self.text.items, p);
            if (d.cp != ' ' and d.cp != '\t' and d.cp != '\n') break;
            start = p;
        }
        while (start > 0) {
            const p = self.prevBoundary(start);
            const d = text.decode(self.text.items, p);
            if (d.cp == ' ' or d.cp == '\t' or d.cp == '\n') break;
            start = p;
        }
        self.text.replaceRange(self.gpa, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        self.preferred_col = null;
    }

    pub fn deleteToLineStart(self: *Editor) void {
        const line_start = self.lineStart(self.cursor);
        if (line_start == self.cursor) return;
        self.pushUndo(true);
        self.text.replaceRange(self.gpa, line_start, self.cursor - line_start, &.{}) catch return;
        self.cursor = line_start;
    }

    pub fn deleteToLineEnd(self: *Editor) void {
        const line_end = self.lineEnd(self.cursor);
        if (line_end == self.cursor) {
            if (self.cursor < self.text.items.len) self.deleteForward();
            return;
        }
        self.pushUndo(true);
        self.text.replaceRange(self.gpa, self.cursor, line_end - self.cursor, &.{}) catch return;
    }

    fn lineStart(self: *Editor, at: usize) usize {
        var i = at;
        while (i > 0 and self.text.items[i - 1] != '\n') i -= 1;
        return i;
    }

    fn lineEnd(self: *Editor, at: usize) usize {
        var i = at;
        while (i < self.text.items.len and self.text.items[i] != '\n') i += 1;
        return i;
    }

    pub fn moveLeft(self: *Editor) void {
        self.cursor = self.prevBoundary(self.cursor);
        self.preferred_col = null;
    }

    pub fn moveRight(self: *Editor) void {
        self.cursor = self.nextBoundary(self.cursor);
        self.preferred_col = null;
    }

    pub fn moveWordLeft(self: *Editor) void {
        var i = self.cursor;
        while (i > 0) {
            const p = self.prevBoundary(i);
            const d = text.decode(self.text.items, p);
            if (d.cp != ' ' and d.cp != '\t' and d.cp != '\n') break;
            i = p;
        }
        while (i > 0) {
            const p = self.prevBoundary(i);
            const d = text.decode(self.text.items, p);
            if (d.cp == ' ' or d.cp == '\t' or d.cp == '\n') break;
            i = p;
        }
        self.cursor = i;
        self.preferred_col = null;
    }

    pub fn moveWordRight(self: *Editor) void {
        var i = self.cursor;
        while (i < self.text.items.len) {
            const d = text.decode(self.text.items, i);
            if (d.cp == ' ' or d.cp == '\t' or d.cp == '\n') break;
            i = self.nextBoundary(i);
        }
        while (i < self.text.items.len) {
            const d = text.decode(self.text.items, i);
            if (d.cp != ' ' and d.cp != '\t' and d.cp != '\n') break;
            i = self.nextBoundary(i);
        }
        self.cursor = i;
        self.preferred_col = null;
    }

    pub fn moveHome(self: *Editor) void {
        self.cursor = self.lineStart(self.cursor);
        self.preferred_col = null;
    }

    pub fn moveEnd(self: *Editor) void {
        self.cursor = self.lineEnd(self.cursor);
        self.preferred_col = null;
    }

    pub fn moveUp(self: *Editor) void {
        const start = self.lineStart(self.cursor);
        if (start == 0) {
            self.cursor = 0;
            return;
        }
        const col = self.visualColumnAt(self.cursor);
        const prev_end = start - 1;
        const prev_start = self.lineStart(prev_end);
        self.cursor = self.offsetAtVisualColumn(prev_start, prev_end, self.preferred_col orelse col);
        self.preferred_col = self.preferred_col orelse col;
    }

    pub fn moveDown(self: *Editor) void {
        const end = self.lineEnd(self.cursor);
        if (end >= self.text.items.len) {
            self.cursor = self.text.items.len;
            return;
        }
        const col = self.visualColumnAt(self.cursor);
        const next_start = end + 1;
        const next_end = self.lineEnd(next_start);
        self.cursor = self.offsetAtVisualColumn(next_start, next_end, self.preferred_col orelse col);
        self.preferred_col = self.preferred_col orelse col;
    }

    fn visualColumnAt(self: *Editor, at: usize) usize {
        const start = self.lineStart(at);
        return text.displayWidth(self.text.items[start..at]);
    }

    fn offsetAtVisualColumn(self: *Editor, start: usize, end: usize, target: usize) usize {
        var i = start;
        var col: usize = 0;
        while (i < end) {
            const d = text.decode(self.text.items, i);
            if (d.len == 0) break;
            const w = text.codepointWidth(d.cp);
            if (col + w > target) break;
            col += w;
            i += d.len;
        }
        return i;
    }

    pub fn insertNewline(self: *Editor) !void {
        try self.insertText("\n", true);
    }

    pub fn undo(self: *Editor) void {
        if (self.undo_stack.items.len == 0) return;
        const cur = self.snapshot() catch return;
        self.redo_stack.append(self.gpa, cur) catch {
            self.gpa.free(cur.text);
            return;
        };
        const s = self.undo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.gpa, s.text) catch {};
        self.cursor = @min(s.cursor, self.text.items.len);
        self.gpa.free(s.text);
        self.preferred_col = null;
    }

    pub fn redo(self: *Editor) void {
        if (self.redo_stack.items.len == 0) return;
        const cur = self.snapshot() catch return;
        self.undo_stack.append(self.gpa, cur) catch {
            self.gpa.free(cur.text);
            return;
        };
        const s = self.redo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.gpa, s.text) catch {};
        self.cursor = @min(s.cursor, self.text.items.len);
        self.gpa.free(s.text);
        self.preferred_col = null;
    }

    pub fn submit(self: *Editor) ![]u8 {
        const value = try self.gpa.dupe(u8, std.mem.trim(u8, self.text.items, " \t\r\n"));
        if (value.len > 0) {
            const same = self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], value);
            if (!same) {
                const owned = try self.gpa.dupe(u8, value);
                try self.history.append(self.gpa, owned);
                if (self.history.items.len > 100) {
                    const old = self.history.orderedRemove(0);
                    self.gpa.free(old);
                }
            }
        }
        self.text.clearRetainingCapacity();
        self.cursor = 0;
        self.preferred_col = null;
        self.history_index = self.history.items.len;
        if (self.draft.len > 0) {
            self.gpa.free(self.draft);
            self.draft = &.{};
        }
        return value;
    }

    pub fn historyPrev(self: *Editor) void {
        if (self.history.items.len == 0) return;
        if (self.history_index == self.history.items.len) {
            if (self.draft.len > 0) self.gpa.free(self.draft);
            self.draft = self.gpa.dupe(u8, self.text.items) catch &.{};
        }
        if (self.history_index == 0) return;
        self.history_index -= 1;
        self.setText(self.history.items[self.history_index]) catch {};
        self.cursor = self.text.items.len;
    }

    pub fn historyNext(self: *Editor) void {
        if (self.history.items.len == 0 or self.history_index >= self.history.items.len) return;
        self.history_index += 1;
        if (self.history_index == self.history.items.len) {
            if (self.draft.len > 0) {
                self.setText(self.draft) catch {};
                self.cursor = self.text.items.len;
            } else {
                self.text.clearRetainingCapacity();
                self.cursor = 0;
            }
        } else {
            self.setText(self.history.items[self.history_index]) catch {};
            self.cursor = self.text.items.len;
        }
    }

    pub fn cursorLineCol(self: *Editor) struct { line: usize, col: usize } {
        var line: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < self.cursor and i < self.text.items.len) {
            const d = text.decode(self.text.items, i);
            if (d.len == 0) break;
            if (d.cp == '\n') {
                line += 1;
                col = 0;
            } else {
                col += text.codepointWidth(d.cp);
            }
            i += d.len;
        }
        return .{ .line = line, .col = col };
    }

    /// Wrapped visual lines for a given content width.
    pub fn layout(self: *Editor, gpa: std.mem.Allocator, width: u16) ![]VLine {
        var lines: std.ArrayList(VLine) = .empty;
        errdefer lines.deinit(gpa);
        const w = if (width == 0) 1 else width;
        var logical: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= self.text.items.len) {
            const at_end = i == self.text.items.len;
            const is_nl = !at_end and self.text.items[i] == '\n';
            if (is_nl or at_end) {
                const line_end = i;
                // Wrap this logical line.
                var seg_start = line_start;
                var col: usize = 0;
                var j = line_start;
                while (j < line_end) {
                    const d = text.decode(self.text.items, j);
                    if (d.len == 0) break;
                    const cw = text.codepointWidth(d.cp);
                    if (col + cw > w and j > seg_start) {
                        try lines.append(gpa, .{ .start = seg_start, .end = j, .logical = logical });
                        seg_start = j;
                        col = 0;
                    }
                    col += cw;
                    j += d.len;
                }
                try lines.append(gpa, .{ .start = seg_start, .end = line_end, .logical = logical });
                logical += 1;
                line_start = i + 1;
                if (at_end) break;
            }
            i += 1;
        }
        if (lines.items.len == 0) try lines.append(gpa, .{ .start = 0, .end = 0, .logical = 0 });
        return lines.toOwnedSlice(gpa);
    }

    pub fn visualCursor(self: *Editor, gpa: std.mem.Allocator, width: u16) !struct { row: usize, col: usize, lines: []VLine } {
        const lines = try self.layout(gpa, width);
        var row: usize = 0;
        var col: usize = 0;
        var best: usize = 0;
        for (lines, 0..) |l, idx| {
            if (self.cursor >= l.start and self.cursor <= l.end) {
                row = idx;
                best = idx;
                col = text.displayWidth(self.text.items[l.start..self.cursor]);
                // Prefer the line containing the cursor; subsequent wrapped lines
                // with the same start are only selected if cursor is at boundary.
                if (self.cursor < l.end or self.cursor == l.start) break;
            }
        }
        if (best >= lines.len) {
            row = lines.len - 1;
            col = text.displayWidth(self.text.items[lines[row].start..self.cursor]);
        }
        return .{ .row = row, .col = col, .lines = lines };
    }
};

test "editor basics" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText("hello\nworld", true);
    try std.testing.expectEqualStrings("hello\nworld", ed.text.items);
    ed.moveHome();
    try std.testing.expectEqual(@as(usize, 6), ed.lineStart(9));
    ed.undo();
    try std.testing.expectEqualStrings("", ed.text.items);
}

test "submit keeps ownership and handles duplicate history" {
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText("hello", true);
    const first = try ed.submit();
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("hello", first);
    try ed.insertText("hello", true);
    const second = try ed.submit();
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("hello", second);
    try std.testing.expectEqual(@as(usize, 1), ed.history.items.len);
}
