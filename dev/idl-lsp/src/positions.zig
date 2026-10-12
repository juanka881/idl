//! Line indexing and conversion between LSP UTF-8 positions and byte offsets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;
const lsp = @import("lsp.zig");

pub const Line = struct {
    start: usize,
    content_end: usize,
};

pub const Offsets = struct {
    start: usize,
    end: usize,
};

pub const MapError = error{
    OutOfMemory,
    InvalidLine,
    SplitUtf8Scalar,
    ReversedRange,
};

pub fn buildLineMap(allocator: Allocator, text: []const u8) MapError![]Line {
    var lines: ArrayList(Line) = .empty;
    defer {
        lines.deinit(allocator);
    }

    var line_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const is_carriage_return = text[index] == '\r';
        const is_line_feed = text[index] == '\n';
        const is_line_break = is_carriage_return or is_line_feed;
        if (!is_line_break) {
            index += 1;
            continue;
        }

        const line: Line = .{
            .start = line_start,
            .content_end = index,
        };
        lines.append(allocator, line) catch {
            return error.OutOfMemory;
        };

        const has_crlf = is_carriage_return and index + 1 < text.len and text[index + 1] == '\n';
        if (has_crlf) {
            index += 2;
        } else {
            index += 1;
        }
        line_start = index;
    }

    const final_line: Line = .{
        .start = line_start,
        .content_end = text.len,
    };
    lines.append(allocator, final_line) catch {
        return error.OutOfMemory;
    };

    const owned_lines = lines.toOwnedSlice(allocator) catch {
        return error.OutOfMemory;
    };

    return owned_lines;
}

pub fn positionToOffset(
    text: []const u8,
    lines: []const Line,
    position: lsp.Position,
) MapError!usize {
    const line_index: usize = position.line;
    const is_line_valid = line_index < lines.len;
    if (!is_line_valid) {
        return error.InvalidLine;
    }

    const line = lines[line_index];
    const line_length = line.content_end - line.start;
    const requested_column: usize = position.character;
    const column = @min(requested_column, line_length);
    const offset = line.start + column;
    const is_scalar_boundary = isUtf8Boundary(text, offset);
    if (!is_scalar_boundary) {
        return error.SplitUtf8Scalar;
    }

    return offset;
}

pub fn rangeToOffsets(
    text: []const u8,
    lines: []const Line,
    range: lsp.Range,
) MapError!Offsets {
    const start = try positionToOffset(text, lines, range.start);
    const end = try positionToOffset(text, lines, range.end);
    const is_ordered = start <= end;
    if (!is_ordered) {
        return error.ReversedRange;
    }

    const offsets: Offsets = .{
        .start = start,
        .end = end,
    };

    return offsets;
}

test "line maps count CR LF and CRLF and clamp to content ends" {
    const allocator = testing.allocator;
    const text = "a\rb\nc\r\nd";
    const lines = try buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqual(@as(usize, 0), lines[0].start);
    try testing.expectEqual(@as(usize, 1), lines[0].content_end);
    try testing.expectEqual(@as(usize, 2), lines[1].start);
    try testing.expectEqual(@as(usize, 3), lines[1].content_end);
    try testing.expectEqual(@as(usize, 4), lines[2].start);
    try testing.expectEqual(@as(usize, 5), lines[2].content_end);
    try testing.expectEqual(@as(usize, 7), lines[3].start);
    try testing.expectEqual(@as(usize, 8), lines[3].content_end);

    const clamped_offset = try positionToOffset(text, lines, .{
        .line = 2,
        .character = 200,
    });
    try testing.expectEqual(@as(usize, 5), clamped_offset);
    try testing.expectError(error.InvalidLine, positionToOffset(text, lines, .{
        .line = 4,
        .character = 0,
    }));
}

test "UTF-8 positions support scalar boundaries and reject split scalars" {
    const allocator = testing.allocator;
    const text = "Aé😀\r\nb\rc\n";
    const lines = try buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqual(@as(usize, 1), try positionToOffset(text, lines, .{
        .line = 0,
        .character = 1,
    }));
    try testing.expectEqual(@as(usize, 3), try positionToOffset(text, lines, .{
        .line = 0,
        .character = 3,
    }));
    try testing.expectEqual(@as(usize, 7), try positionToOffset(text, lines, .{
        .line = 0,
        .character = 500,
    }));
    try testing.expectError(error.SplitUtf8Scalar, positionToOffset(text, lines, .{
        .line = 0,
        .character = 2,
    }));
    try testing.expectError(error.SplitUtf8Scalar, positionToOffset(text, lines, .{
        .line = 0,
        .character = 4,
    }));
    try testing.expectEqual(@as(usize, 13), try positionToOffset(text, lines, .{
        .line = 3,
        .character = 0,
    }));
}

test "ranges compare clamped absolute endpoints" {
    const allocator = testing.allocator;
    const text = "first\r\nsecond";
    const lines = try buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    const clamped_equal_range: lsp.Range = .{
        .start = .{
            .line = 0,
            .character = 100,
        },
        .end = .{
            .line = 0,
            .character = 200,
        },
    };
    const offsets = try rangeToOffsets(text, lines, clamped_equal_range);
    try testing.expectEqual(@as(usize, 5), offsets.start);
    try testing.expectEqual(@as(usize, 5), offsets.end);

    const reversed_after_clamp: lsp.Range = .{
        .start = .{
            .line = 1,
            .character = 50,
        },
        .end = .{
            .line = 0,
            .character = 1,
        },
    };
    try testing.expectError(error.ReversedRange, rangeToOffsets(text, lines, reversed_after_clamp));
}

test "empty text and trailing newlines retain EOF lines" {
    const allocator = testing.allocator;
    const empty_lines = try buildLineMap(allocator, "");
    defer {
        allocator.free(empty_lines);
    }
    try testing.expectEqual(@as(usize, 1), empty_lines.len);
    try testing.expectEqual(@as(usize, 0), try positionToOffset("", empty_lines, .{
        .line = 0,
        .character = 0,
    }));

    const trailing_lines = try buildLineMap(allocator, "x\n");
    defer {
        allocator.free(trailing_lines);
    }
    try testing.expectEqual(@as(usize, 2), trailing_lines.len);
    try testing.expectEqual(@as(usize, 2), try positionToOffset("x\n", trailing_lines, .{
        .line = 1,
        .character = 0,
    }));
}

fn isUtf8Boundary(text: []const u8, offset: usize) bool {
    const is_at_end = offset == text.len;
    if (is_at_end) {
        return true;
    }

    const is_continuation_byte = text[offset] & 0b1100_0000 == 0b1000_0000;
    return !is_continuation_byte;
}
