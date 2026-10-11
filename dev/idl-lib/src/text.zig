const std = @import("std");
const math = std.math;
const testing = std.testing;

pub const TextSpan = struct {
    start: usize,
    len: usize,

    /// Requires this span to have been checked and to fit within its source.
    pub fn end(self: TextSpan) usize {
        return self.start + self.len;
    }

    pub fn checkedEnd(self: TextSpan) error{OutOfBounds}!usize {
        const remaining_address_space = math.maxInt(usize) - self.start;
        const is_end_representable = self.len <= remaining_address_space;
        if (!is_end_representable) {
            return error.OutOfBounds;
        }

        return self.start + self.len;
    }
};

pub const Position = struct {
    line: usize,
    column: usize,
};

pub const SourceText = struct {
    bytes: []const u8,
    line_starts: []const usize,

    pub fn slice(self: SourceText, span: TextSpan) error{OutOfBounds}![]const u8 {
        const span_start_is_in_bounds = span.start <= self.bytes.len;
        if (!span_start_is_in_bounds) {
            return error.OutOfBounds;
        }

        const remaining_source_len = self.bytes.len - span.start;
        const is_span_in_bounds = span.len <= remaining_source_len;
        if (!is_span_in_bounds) {
            return error.OutOfBounds;
        }

        return self.bytes[span.start .. span.start + span.len];
    }

    pub fn positionAt(self: SourceText, offset: usize) error{OutOfBounds}!Position {
        const is_offset_in_bounds = offset <= self.bytes.len;
        if (!is_offset_in_bounds) {
            return error.OutOfBounds;
        }

        const has_line_starts = self.line_starts.len > 0;
        if (!has_line_starts) {
            return error.OutOfBounds;
        }

        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle] <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        const line = low - 1;
        const position: Position = .{
            .line = line,
            .column = offset - self.line_starts[line],
        };

        return position;
    }
};

pub fn countPhysicalLines(bytes: []const u8) error{SourceTooLarge}!usize {
    var line_count: usize = 1;
    var index: usize = 0;

    while (index < bytes.len) {
        if (bytes[index] == '\r') {
            const can_add_physical_line = line_count < math.maxInt(usize);
            if (!can_add_physical_line) {
                return error.SourceTooLarge;
            }

            line_count += 1;
            index += 1;
            if (index < bytes.len and bytes[index] == '\n') {
                index += 1;
            }

            continue;
        }

        if (bytes[index] == '\n') {
            const can_add_physical_line = line_count < math.maxInt(usize);
            if (!can_add_physical_line) {
                return error.SourceTooLarge;
            }

            line_count += 1;
        }

        index += 1;
    }

    return line_count;
}

pub fn fillLineStarts(bytes: []const u8, starts: []usize) void {
    starts[0] = 0;
    var next_slot: usize = 1;
    var index: usize = 0;

    while (index < bytes.len) {
        if (bytes[index] == '\r') {
            index += 1;
            if (index < bytes.len and bytes[index] == '\n') {
                index += 1;
            }

            starts[next_slot] = index;
            next_slot += 1;
            continue;
        }

        if (bytes[index] == '\n') {
            index += 1;
            starts[next_slot] = index;
            next_slot += 1;
            continue;
        }

        index += 1;
    }
}

test "line index handles empty text and mixed physical newlines" {
    const empty_starts = [_]usize{0};
    try testing.expectEqual(@as(usize, 1), try countPhysicalLines(""));
    try testing.expectEqualSlices(usize, &empty_starts, &.{0});

    const bytes = "a\r\nb\rc\nd\r";
    const expected = [_]usize{ 0, 3, 5, 7, 9 };
    var actual: [expected.len]usize = undefined;
    try testing.expectEqual(expected.len, try countPhysicalLines(bytes));
    fillLineStarts(bytes, &actual);
    try testing.expectEqualSlices(usize, &expected, &actual);
}
