//! Converts core diagnostics into protocol diagnostics without owning parser data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;
const testing = std.testing;
const unicode = std.unicode;
const idl = @import("idl");
const lsp = @import("lsp.zig");
const positions = @import("positions.zig");

pub const MappingError = error{
    OutOfMemory,
    InvalidSpan,
    PositionTooLarge,
};

const BoundaryBias = enum {
    floor,
    ceiling,
};

pub fn mapAll(
    allocator: Allocator,
    uri: []const u8,
    document: *const idl.Document,
    lines: []const positions.Line,
    related_information_supported: bool,
) MappingError![]lsp.Diagnostic {
    const source = document.source().bytes;
    // The 4,000-diagnostic single-line benchmark showed that rescanning UTF-8
    // for every span is costly, so validate the source once for this pass.
    const source_is_valid_utf8 = unicode.utf8ValidateSlice(source);
    var mapped: ArrayList(lsp.Diagnostic) = .empty;
    defer {
        mapped.deinit(allocator);
    }

    for (document.diagnostics()) |diagnostic| {
        const range = try mapSpanValidated(source, lines, diagnostic.span, source_is_valid_utf8);
        var maybe_related: ?lsp.RelatedInformation = null;
        if (related_information_supported) {
            if (diagnostic.related_span) |related_span| {
                const related_range = try mapSpanValidated(source, lines, related_span, source_is_valid_utf8);
                maybe_related = .{
                    .uri = uri,
                    .range = related_range,
                    .message = "Related location",
                };
            }
        }

        const mapped_diagnostic: lsp.Diagnostic = .{
            .range = range,
            .severity = mapSeverity(diagnostic.severity),
            .code = diagnostic.code,
            .source = "idl",
            .message = diagnostic.message,
            .related_information = maybe_related,
        };
        mapped.append(allocator, mapped_diagnostic) catch {
            return error.OutOfMemory;
        };
    }

    const owned_diagnostics = mapped.toOwnedSlice(allocator) catch {
        return error.OutOfMemory;
    };

    return owned_diagnostics;
}

pub fn mapSpan(
    text: []const u8,
    lines: []const positions.Line,
    span: idl.TextSpan,
) MappingError!lsp.Range {
    const text_is_valid_utf8 = unicode.utf8ValidateSlice(text);
    return mapSpanValidated(text, lines, span, text_is_valid_utf8);
}

fn mapSpanValidated(
    text: []const u8,
    lines: []const positions.Line,
    span: idl.TextSpan,
    text_is_valid_utf8: bool,
) MappingError!lsp.Range {
    const end = span.checkedEnd() catch {
        return error.InvalidSpan;
    };
    const span_end_is_within_text = end <= text.len;
    if (!span_end_is_within_text) {
        return error.InvalidSpan;
    }

    const is_empty = span.len == 0;
    if (is_empty) {
        const offset = try adjustOffset(text, lines, span.start, .floor, text_is_valid_utf8);
        const position = try offsetToPosition(text, lines, offset);
        const range: lsp.Range = .{
            .start = position,
            .end = position,
        };

        return range;
    }

    const start_offset = try adjustOffset(text, lines, span.start, .floor, text_is_valid_utf8);
    const end_offset = try adjustOffset(text, lines, end, .ceiling, text_is_valid_utf8);
    const start = try offsetToPosition(text, lines, start_offset);
    const end_position = try offsetToPosition(text, lines, end_offset);
    const range: lsp.Range = .{
        .start = start,
        .end = end_position,
    };

    return range;
}

fn mapSeverity(severity: idl.Severity) u32 {
    return switch (severity) {
        .err => 1,
        .warning => 2,
        .information => 3,
    };
}

test "core severities map to LSP severity numbers" {
    try testing.expectEqual(@as(u32, 1), mapSeverity(.err));
    try testing.expectEqual(@as(u32, 2), mapSeverity(.warning));
    try testing.expectEqual(@as(u32, 3), mapSeverity(.information));
}

fn adjustOffset(
    text: []const u8,
    lines: []const positions.Line,
    offset: usize,
    bias: BoundaryBias,
    text_is_valid_utf8: bool,
) MappingError!usize {
    const offset_is_within_text = offset <= text.len;
    if (!offset_is_within_text) {
        return error.InvalidSpan;
    }

    const has_lines = lines.len > 0;
    if (!has_lines) {
        return error.InvalidSpan;
    }

    const maybe_line_index = lineIndexAtOrBefore(lines, offset);
    if (maybe_line_index == null) {
        return error.InvalidSpan;
    }
    const line_index = maybe_line_index.?;
    const line = lines[line_index];
    const offset_is_on_line_content = offset <= line.content_end;
    if (offset_is_on_line_content) {
        return adjustLineOffset(text, line, offset, bias, text_is_valid_utf8);
    }

    const has_next_line = line_index + 1 < lines.len;
    if (!has_next_line) {
        return error.InvalidSpan;
    }

    const next_line = lines[line_index + 1];
    const offset_is_inside_line_terminator = offset < next_line.start;
    if (offset_is_inside_line_terminator) {
        return line.content_end;
    }

    return error.InvalidSpan;
}

fn adjustLineOffset(
    text: []const u8,
    line: positions.Line,
    offset: usize,
    bias: BoundaryBias,
    text_is_valid_utf8: bool,
) MappingError!usize {
    if (text_is_valid_utf8) {
        return adjustValidLineOffset(text, line, offset, bias);
    }

    // Malformed parser input is uncommon. Scan only until the requested
    // endpoint is resolved, treating each invalid byte run as indivisible.
    var cursor = line.start;
    while (cursor < line.content_end) {
        const maybe_sequence_length = validSequenceLength(text, cursor, line.content_end);
        if (maybe_sequence_length) |sequence_length| {
            const next_cursor = cursor + sequence_length;
            const is_inside_sequence = offset > cursor and offset < next_cursor;
            if (is_inside_sequence) {
                return switch (bias) {
                    .floor => cursor,
                    .ceiling => next_cursor,
                };
            }

            cursor = next_cursor;
            continue;
        }

        const invalid_run_start = cursor;
        cursor += 1;
        while (cursor < line.content_end) {
            const next_sequence_length = validSequenceLength(text, cursor, line.content_end);
            if (next_sequence_length != null) {
                break;
            }

            cursor += 1;
        }

        const is_inside_invalid_run = offset > invalid_run_start and offset < cursor;
        if (is_inside_invalid_run) {
            return switch (bias) {
                .floor => invalid_run_start,
                .ceiling => cursor,
            };
        }
    }

    return offset;
}

fn adjustValidLineOffset(
    text: []const u8,
    line: positions.Line,
    offset: usize,
    bias: BoundaryBias,
) MappingError!usize {
    const is_at_line_boundary = offset == line.start or offset == line.content_end;
    if (is_at_line_boundary) {
        return offset;
    }

    const is_continuation_byte = isUtf8ContinuationByte(text[offset]);
    if (!is_continuation_byte) {
        return offset;
    }

    // Valid UTF-8 needs at most three backward byte checks to reach a scalar lead.
    var sequence_start = offset;
    while (sequence_start > line.start) {
        sequence_start -= 1;
        const is_leading_byte = !isUtf8ContinuationByte(text[sequence_start]);
        if (is_leading_byte) {
            break;
        }
    }

    const maybe_sequence_length = validSequenceLength(text, sequence_start, line.content_end);
    if (maybe_sequence_length == null) {
        return error.InvalidSpan;
    }
    const sequence_length = maybe_sequence_length.?;
    const sequence_end = sequence_start + sequence_length;
    const is_inside_sequence = offset < sequence_end;
    if (!is_inside_sequence) {
        return error.InvalidSpan;
    }

    return switch (bias) {
        .floor => sequence_start,
        .ceiling => sequence_end,
    };
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn validSequenceLength(text: []const u8, offset: usize, end: usize) ?usize {
    const maybe_length = unicode.utf8ByteSequenceLength(text[offset]) catch {
        return null;
    };
    const length: usize = maybe_length;
    const remaining_length = end - offset;
    const sequence_fits_line = length <= remaining_length;
    if (!sequence_fits_line) {
        return null;
    }

    const sequence_end = offset + length;
    _ = unicode.utf8Decode(text[offset..sequence_end]) catch {
        return null;
    };

    return length;
}

fn offsetToPosition(
    text: []const u8,
    lines: []const positions.Line,
    offset: usize,
) MappingError!lsp.Position {
    const offset_is_within_text = offset <= text.len;
    if (!offset_is_within_text) {
        return error.InvalidSpan;
    }

    const maybe_line_index = lineIndexAtOrBefore(lines, offset);
    if (maybe_line_index == null) {
        return error.InvalidSpan;
    }
    const line_index = maybe_line_index.?;
    const line = lines[line_index];
    const offset_is_on_line_content = offset <= line.content_end;
    if (!offset_is_on_line_content) {
        return error.InvalidSpan;
    }

    return positionForLine(line, line_index, offset);
}

fn lineIndexAtOrBefore(lines: []const positions.Line, offset: usize) ?usize {
    var low: usize = 0;
    var high = lines.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const line_starts_at_or_before_offset = lines[middle].start <= offset;
        if (line_starts_at_or_before_offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    const has_preceding_line = low > 0;
    if (!has_preceding_line) {
        return null;
    }

    return low - 1;
}

fn positionForLine(line: positions.Line, line_index: usize, offset: usize) MappingError!lsp.Position {
    const column = offset - line.start;
    const maximum_position = math.maxInt(i32);
    const line_is_representable = line_index <= maximum_position;
    const column_is_representable = column <= maximum_position;
    const position_is_representable = line_is_representable and column_is_representable;
    if (!position_is_representable) {
        return error.PositionTooLarge;
    }

    const position: lsp.Position = .{
        .line = @intCast(line_index),
        .character = @intCast(column),
    };

    return position;
}

test "outgoing line and column positions stay within signed i32 bounds" {
    const maximum_position: usize = math.maxInt(i32);
    const first_unrepresentable_position = maximum_position + 1;
    const short_line: positions.Line = .{
        .start = 0,
        .content_end = 0,
    };
    try testing.expectError(
        error.PositionTooLarge,
        positionForLine(short_line, first_unrepresentable_position, 0),
    );

    const long_line: positions.Line = .{
        .start = 0,
        .content_end = first_unrepresentable_position,
    };
    try testing.expectError(
        error.PositionTooLarge,
        positionForLine(long_line, 0, first_unrepresentable_position),
    );
}

test "diagnostic spans map UTF-8 scalar boundaries, newlines, and EOF" {
    const allocator = testing.allocator;
    const text = "é😀x\r\nlast\r";
    const lines = try positions.buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    const scalar_span: idl.TextSpan = .{
        .start = 1,
        .len = 1,
    };
    const scalar_range = try mapSpan(text, lines, scalar_span);
    try testing.expectEqual(@as(u32, 0), scalar_range.start.line);
    try testing.expectEqual(@as(u32, 0), scalar_range.start.character);
    try testing.expectEqual(@as(u32, 2), scalar_range.end.character);

    const crlf_span: idl.TextSpan = .{
        .start = 7,
        .len = 1,
    };
    const crlf_range = try mapSpan(text, lines, crlf_span);
    try testing.expectEqual(@as(u32, 0), crlf_range.start.line);
    try testing.expectEqual(@as(u32, 7), crlf_range.start.character);
    try testing.expectEqual(@as(u32, 0), crlf_range.end.line);
    try testing.expectEqual(@as(u32, 7), crlf_range.end.character);

    const zero_width_crlf_span: idl.TextSpan = .{
        .start = 8,
        .len = 0,
    };
    const zero_width_crlf_range = try mapSpan(text, lines, zero_width_crlf_span);
    try testing.expectEqual(@as(u32, 0), zero_width_crlf_range.start.line);
    try testing.expectEqual(@as(u32, 7), zero_width_crlf_range.start.character);
    try testing.expectEqual(zero_width_crlf_range.start, zero_width_crlf_range.end);

    const eof_span: idl.TextSpan = .{
        .start = text.len,
        .len = 0,
    };
    const eof_range = try mapSpan(text, lines, eof_span);
    try testing.expectEqual(@as(u32, 2), eof_range.start.line);
    try testing.expectEqual(@as(u32, 0), eof_range.start.character);
    try testing.expectEqual(eof_range.start, eof_range.end);
}

test "malformed UTF-8 runs map to indivisible diagnostic boundaries" {
    const allocator = testing.allocator;
    const text = "a\xff\xfez";
    const lines = try positions.buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    const nonempty_span: idl.TextSpan = .{
        .start = 2,
        .len = 1,
    };
    const range = try mapSpan(text, lines, nonempty_span);
    try testing.expectEqual(@as(u32, 1), range.start.character);
    try testing.expectEqual(@as(u32, 3), range.end.character);

    const zero_width_span: idl.TextSpan = .{
        .start = 2,
        .len = 0,
    };
    const zero_width_range = try mapSpan(text, lines, zero_width_span);
    try testing.expectEqual(@as(u32, 1), zero_width_range.start.character);
    try testing.expectEqual(zero_width_range.start, zero_width_range.end);
}

test "truncated UTF-8 runs remain adjacent to valid multibyte scalars" {
    const allocator = testing.allocator;
    const text = "é\xff\xfe😀\xe2\x82";
    const lines = try positions.buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    const invalid_middle: idl.TextSpan = .{
        .start = 3,
        .len = 1,
    };
    const middle_range = try mapSpan(text, lines, invalid_middle);
    try testing.expectEqual(@as(u32, 2), middle_range.start.character);
    try testing.expectEqual(@as(u32, 4), middle_range.end.character);

    const scalar_interior: idl.TextSpan = .{
        .start = 5,
        .len = 1,
    };
    const scalar_range = try mapSpan(text, lines, scalar_interior);
    try testing.expectEqual(@as(u32, 4), scalar_range.start.character);
    try testing.expectEqual(@as(u32, 8), scalar_range.end.character);

    const truncated_interior: idl.TextSpan = .{
        .start = 9,
        .len = 1,
    };
    const truncated_range = try mapSpan(text, lines, truncated_interior);
    try testing.expectEqual(@as(u32, 8), truncated_range.start.character);
    try testing.expectEqual(@as(u32, 10), truncated_range.end.character);
}

test "zero-width valid scalar spans snap to one preceding boundary" {
    const allocator = testing.allocator;
    const text = "aé😀z";
    const lines = try positions.buildLineMap(allocator, text);
    defer {
        allocator.free(lines);
    }

    const span: idl.TextSpan = .{
        .start = 4,
        .len = 0,
    };
    const range = try mapSpan(text, lines, span);
    try testing.expectEqual(@as(u32, 3), range.start.character);
    try testing.expectEqual(range.start, range.end);
}

test "empty text and all physical newline forms map to valid positions" {
    const allocator = testing.allocator;
    const empty_lines = try positions.buildLineMap(allocator, "");
    defer {
        allocator.free(empty_lines);
    }
    const empty_range = try mapSpan("", empty_lines, .{
        .start = 0,
        .len = 0,
    });
    try testing.expectEqual(@as(u32, 0), empty_range.start.line);
    try testing.expectEqual(@as(u32, 0), empty_range.start.character);

    const newline_texts = [_][]const u8{
        "a\nb",
        "a\rb",
        "a\r\nb",
    };
    for (newline_texts) |text| {
        const lines = try positions.buildLineMap(allocator, text);
        defer {
            allocator.free(lines);
        }
        const newline_span: idl.TextSpan = .{
            .start = 1,
            .len = 1,
        };
        const range = try mapSpan(text, lines, newline_span);
        try testing.expectEqual(@as(u32, 0), range.start.line);
        try testing.expectEqual(@as(u32, 1), range.start.character);
        if (text.len == 4) {
            try testing.expectEqual(@as(u32, 0), range.end.line);
            try testing.expectEqual(@as(u32, 1), range.end.character);
        } else {
            try testing.expectEqual(@as(u32, 1), range.end.line);
            try testing.expectEqual(@as(u32, 0), range.end.character);
        }
    }
}

test "mapped diagnostics preserve core metadata and related information policy" {
    const allocator = testing.allocator;
    const parsed = try idl.parse(allocator, "node title='é😀'\r\nnode key=1 key=2");
    defer {
        parsed.destroy();
    }

    const lines = try positions.buildLineMap(allocator, parsed.source().bytes);
    defer {
        allocator.free(lines);
    }

    const uri = "file:///diagnostic.idl";
    const without_related = try mapAll(allocator, uri, parsed, lines, false);
    defer {
        allocator.free(without_related);
    }

    try testing.expectEqual(@as(usize, 1), without_related.len);
    try testing.expectEqual(@as(u32, 1), without_related[0].severity.?);
    try testing.expectEqualStrings("duplicate_property", without_related[0].code.?);
    try testing.expectEqualStrings("idl", without_related[0].source.?);
    try testing.expectEqualStrings("Property is repeated in this header.", without_related[0].message);
    try testing.expectEqual(@as(u32, 1), without_related[0].range.start.line);
    try testing.expectEqual(@as(u32, 11), without_related[0].range.start.character);
    try testing.expectEqual(@as(u32, 1), without_related[0].range.end.line);
    try testing.expectEqual(@as(u32, 14), without_related[0].range.end.character);
    try testing.expect(without_related[0].related_information == null);

    const with_related = try mapAll(allocator, uri, parsed, lines, true);
    defer {
        allocator.free(with_related);
    }

    const related = with_related[0].related_information.?;
    try testing.expectEqualStrings(uri, related.uri);
    try testing.expectEqualStrings("Related location", related.message);
    try testing.expectEqual(@as(u32, 1), related.range.start.line);
    try testing.expectEqual(@as(u32, 5), related.range.start.character);
    try testing.expectEqual(@as(u32, 8), related.range.end.character);
}
