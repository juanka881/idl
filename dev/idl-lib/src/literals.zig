const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const unicode = std.unicode;
const diag = @import("diagnostics.zig");
const text = @import("text.zig");
const syntax = @import("syntax.zig");

const Line = struct {
    start: usize,
    end: usize,
    newline_start: usize,
    newline_len: usize,
    blank: bool,
    more_indented: bool,
};

pub const DecodeResult = struct {
    decoded: ?[]const u8,
    diagnostics: []const diag.Diagnostic,
};

pub fn decode(
    allocator: Allocator,
    source: []const u8,
    raw_span: text.TextSpan,
    style: syntax.StringStyle,
    terminated: bool,
) Allocator.Error!DecodeResult {
    const no_diagnostics: []const diag.Diagnostic = &.{};
    const is_span_start_in_bounds = raw_span.start <= source.len;
    if (!is_span_start_in_bounds) {
        const result: DecodeResult = .{
            .decoded = null,
            .diagnostics = no_diagnostics,
        };

        return result;
    }

    const remaining_source_len = source.len - raw_span.start;
    const is_span_in_bounds = raw_span.len <= remaining_source_len;
    if (!is_span_in_bounds) {
        const result: DecodeResult = .{
            .decoded = null,
            .diagnostics = no_diagnostics,
        };

        return result;
    }

    var diagnostic_list: ArrayList(diag.Diagnostic) = .empty;

    errdefer {
        diagnostic_list.deinit(allocator);
    }

    var marker_len: usize = 1;
    if (style == .ordinary) {
        marker_len = 0;
    }

    const minimum_raw_string_len = marker_len + 1;
    const has_minimum_string_length = raw_span.len >= minimum_raw_string_len;
    if (!has_minimum_string_length) {
        const result: DecodeResult = .{
            .decoded = null,
            .diagnostics = no_diagnostics,
        };

        return result;
    }

    const quote_start = raw_span.start + marker_len;
    const raw_end = raw_span.start + raw_span.len;
    const content_start = quote_start + 1;
    const has_closing_quote = terminated and raw_end > content_start;
    var content_end = raw_end;
    if (has_closing_quote) {
        content_end = raw_end - 1;
    }

    const has_valid_content_bounds = content_end >= content_start;
    if (!has_valid_content_bounds) {
        const result: DecodeResult = .{
            .decoded = null,
            .diagnostics = no_diagnostics,
        };

        return result;
    }

    var is_valid_content = terminated;
    try validateRawContent(allocator, source, content_start, content_end, &diagnostic_list, &is_valid_content);

    const finished_diagnostics = try diagnostic_list.toOwnedSlice(allocator);

    errdefer {
        if (finished_diagnostics.len > 0) {
            allocator.free(finished_diagnostics);
        }
    }

    if (!is_valid_content) {
        const result: DecodeResult = .{
            .decoded = null,
            .diagnostics = finished_diagnostics,
        };

        return result;
    }

    const layout = try buildLayout(allocator, source, content_start, content_end, style);
    defer {
        allocator.free(layout);
    }

    const decoded = try decodeValidContent(allocator, layout);
    const result: DecodeResult = .{
        .decoded = decoded,
        .diagnostics = finished_diagnostics,
    };

    return result;
}

fn validateRawContent(
    allocator: Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    diagnostic_list: *ArrayList(diag.Diagnostic),
    is_valid_content: *bool,
) Allocator.Error!void {
    var index = start;
    while (index < end) {
        if (source[index] == '\\') {
            const escape = validateEscape(source, index, end);
            if (!escape.valid) {
                is_valid_content.* = false;
                try diagnostic_list.append(allocator, .{
                    .code = diag.invalid_escape_code,
                    .severity = .err,
                    .message = diag.invalid_escape_message,
                    .span = .{
                        .start = index,
                        .len = escape.next - index,
                    },
                });
            }

            index = escape.next;
            continue;
        }

        const scalar = decodeScalar(source, index, end) orelse {
            // The scanner reports invalid UTF-8 once for the whole source.
            is_valid_content.* = false;
            index += 1;
            continue;
        };
        if (isForbiddenControl(scalar.value)) {
            is_valid_content.* = false;
            try diagnostic_list.append(allocator, .{
                .code = diag.invalid_control_code,
                .severity = .err,
                .message = diag.invalid_control_message,
                .span = .{
                    .start = index,
                    .len = scalar.len,
                },
            });
        }

        index += scalar.len;
    }
}

const EscapeValidation = struct {
    valid: bool,
    next: usize,
};

fn validateEscape(source: []const u8, slash: usize, end: usize) EscapeValidation {
    const next = slash + 1;
    const has_escape_byte = next < end;
    if (!has_escape_byte) {
        const result: EscapeValidation = .{
            .valid = false,
            .next = end,
        };

        return result;
    }

    const escaped = source[next];
    switch (escaped) {
        '\\', '\'', 'n', 'r', 't', 'b', 'f' => {
            const result: EscapeValidation = .{
                .valid = true,
                .next = next + 1,
            };

            return result;
        },
        '\r', '\n' => {
            const newline_len = physicalNewlineLength(source, next, end);
            const result: EscapeValidation = .{
                .valid = false,
                .next = next + newline_len,
            };

            return result;
        },
        'u' => {},
        else => {
            const result: EscapeValidation = .{
                .valid = false,
                .next = next + 1,
            };

            return result;
        },
    }

    const brace = next + 1;
    const is_brace_position_in_bounds = brace < end;
    if (!is_brace_position_in_bounds) {
        const result: EscapeValidation = .{
            .valid = false,
            .next = brace,
        };

        return result;
    }

    const has_opening_brace = source[brace] == '{';
    if (!has_opening_brace) {
        const result: EscapeValidation = .{
            .valid = false,
            .next = brace,
        };

        return result;
    }

    var index = brace + 1;
    var digit_count: usize = 0;
    var value: u32 = 0;
    while (index < end) {
        const digit = hexValue(source[index]) orelse {
            break;
        };
        if (digit_count == 6) {
            const next_index = consumeEscapeTail(source, index, end);
            const result: EscapeValidation = .{
                .valid = false,
                .next = next_index,
            };

            return result;
        }

        digit_count += 1;
        value = value * 16 + digit;
        index += 1;
    }

    const has_digits = digit_count > 0;
    const has_close_brace_position = index < end;
    const has_close_brace = has_close_brace_position and source[index] == '}';
    const is_valid_unicode_escape = has_digits and has_close_brace;
    if (!is_valid_unicode_escape) {
        const next_index = consumeEscapeTail(source, index, end);
        const result: EscapeValidation = .{
            .valid = false,
            .next = next_index,
        };

        return result;
    }

    index += 1;

    const is_at_or_below_unicode_scalar_max = value <= 0x10ffff;
    const is_outside_surrogate_range = value < 0xd800 or value > 0xdfff;
    const is_valid_unicode_scalar = is_at_or_below_unicode_scalar_max and is_outside_surrogate_range;
    if (!is_valid_unicode_scalar) {
        const result: EscapeValidation = .{
            .valid = false,
            .next = index,
        };

        return result;
    }

    const result: EscapeValidation = .{
        .valid = true,
        .next = index,
    };

    return result;
}

fn consumeEscapeTail(source: []const u8, start: usize, end: usize) usize {
    var index = start;
    while (index < end) {
        const is_escape_terminator = source[index] == '}' or isNewline(source[index]);
        if (is_escape_terminator) {
            break;
        }

        index += 1;
    }

    if (index < end and source[index] == '}') {
        index += 1;
    }

    return index;
}

fn buildLayout(
    allocator: Allocator,
    source: []const u8,
    content_start: usize,
    content_end: usize,
    style: syntax.StringStyle,
) Allocator.Error![]u8 {
    if (style == .ordinary) {
        return allocator.dupe(u8, source[content_start..content_end]);
    }

    var layout_start = content_start;
    var layout_end = content_end;
    var opening_newline_removed = false;
    const has_layout_content = layout_start < layout_end;
    const starts_with_opening_newline = has_layout_content and isNewline(source[layout_start]);
    if (starts_with_opening_newline) {
        layout_start += physicalNewlineLength(source, layout_start, layout_end);
        opening_newline_removed = true;
    }

    const has_layout_content_after_opening = layout_end > layout_start;
    if (has_layout_content_after_opening) {
        if (findLastNewline(source, layout_start, layout_end)) |last_newline| {
            const suffix_start = last_newline + physicalNewlineLength(source, last_newline, layout_end);
            if (isIndent(source[suffix_start..layout_end])) {
                layout_end = last_newline;
            }
        } else {
            const has_only_framing_indent = opening_newline_removed and isIndent(source[layout_start..layout_end]);
            if (has_only_framing_indent) {
                layout_end = layout_start;
            }
        }
    }

    var lines: ArrayList(Line) = .empty;
    defer {
        lines.deinit(allocator);
    }

    try collectLines(allocator, source, layout_start, layout_end, &lines);
    removeCommonIndent(source, lines.items);

    var output: ArrayList(u8) = .empty;

    errdefer {
        output.deinit(allocator);
    }

    if (style == .dedented) {
        for (lines.items) |line| {
            try output.appendSlice(allocator, source[line.start..line.end]);
            try output.appendSlice(allocator, source[line.newline_start .. line.newline_start + line.newline_len]);
        }

        return output.toOwnedSlice(allocator);
    }

    var line_index: usize = 0;
    while (line_index < lines.items.len) {
        const line = lines.items[line_index];
        try output.appendSlice(allocator, source[line.start..line.end]);
        const is_last_line = line_index + 1 >= lines.items.len;
        const has_following_newline = line.newline_len > 0;
        if (is_last_line or !has_following_newline) {
            break;
        }

        const is_foldable_text_line = !line.blank and !line.more_indented;
        if (is_foldable_text_line) {
            var next_nonblank = line_index + 1;
            while (next_nonblank < lines.items.len) {
                const is_blank_line = lines.items[next_nonblank].blank;
                if (!is_blank_line) {
                    break;
                }

                next_nonblank += 1;
            }

            const has_following_nonblank_line = next_nonblank < lines.items.len;
            if (has_following_nonblank_line) {
                const following_line_is_more_indented = lines.items[next_nonblank].more_indented;
                if (following_line_is_more_indented) {
                    try output.append(allocator, '\n');
                    line_index += 1;
                    continue;
                }

                if (next_nonblank == line_index + 1) {
                    try output.append(allocator, ' ');
                } else {
                    const blank_line_count = next_nonblank - line_index - 1;
                    for (0..blank_line_count) |_| {
                        try output.append(allocator, '\n');
                    }
                }

                line_index = next_nonblank;
                continue;
            }
        }

        try output.append(allocator, '\n');
        line_index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn removeCommonIndent(source: []const u8, lines: []Line) void {
    var common_prefix_len: ?usize = null;
    var reference_line: ?Line = null;

    for (lines) |line| {
        if (lineIsBlank(source[line.start..line.end])) {
            continue;
        }

        const indent_len = indentationLength(source[line.start..line.end]);
        if (common_prefix_len) |current_len| {
            const reference = reference_line.?;
            const limit = @min(current_len, indent_len);
            var matched: usize = 0;
            while (matched < limit) : (matched += 1) {
                if (source[reference.start + matched] != source[line.start + matched]) {
                    break;
                }
            }

            common_prefix_len = matched;
        } else {
            common_prefix_len = indent_len;
            reference_line = line;
        }
    }

    const prefix_len = common_prefix_len orelse 0;
    for (lines) |*line| {
        if (lineIsBlank(source[line.start..line.end])) {
            line.start = line.end;
            line.blank = true;
            continue;
        }

        line.start += prefix_len;
        line.blank = line.start == line.end;
        const has_more_indented_content = !line.blank and isIndentByte(source[line.start]);
        line.more_indented = has_more_indented_content;
    }
}

fn collectLines(
    allocator: Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    lines: *ArrayList(Line),
) Allocator.Error!void {
    var line_start = start;
    var index = start;
    while (index < end) {
        if (isNewline(source[index])) {
            const newline_len = physicalNewlineLength(source, index, end);
            try lines.append(allocator, .{
                .start = line_start,
                .end = index,
                .newline_start = index,
                .newline_len = newline_len,
                .blank = lineIsBlank(source[line_start..index]),
                .more_indented = false,
            });
            index += newline_len;
            line_start = index;
        } else {
            index += 1;
        }
    }

    try lines.append(allocator, .{
        .start = line_start,
        .end = end,
        .newline_start = end,
        .newline_len = 0,
        .blank = lineIsBlank(source[line_start..end]),
        .more_indented = false,
    });
}

fn decodeValidContent(allocator: Allocator, source: []const u8) Allocator.Error![]u8 {
    var output: ArrayList(u8) = .empty;

    errdefer {
        output.deinit(allocator);
    }

    var index: usize = 0;
    while (index < source.len) {
        if (source[index] != '\\') {
            const scalar = decodeScalar(source, index, source.len) orelse {
                unreachable;
            };
            try output.appendSlice(allocator, source[index .. index + scalar.len]);
            index += scalar.len;
            continue;
        }

        const escaped = source[index + 1];
        switch (escaped) {
            '\\', '\'' => {
                try output.append(allocator, escaped);
            },
            'n' => {
                try output.append(allocator, '\n');
            },
            'r' => {
                try output.append(allocator, '\r');
            },
            't' => {
                try output.append(allocator, '\t');
            },
            'b' => {
                try output.append(allocator, 0x08);
            },
            'f' => {
                try output.append(allocator, 0x0c);
            },
            'u' => {
                var cursor = index + 3;
                var value: u32 = 0;
                while (source[cursor] != '}') : (cursor += 1) {
                    const digit = hexValue(source[cursor]) orelse {
                        unreachable;
                    };
                    value = value * 16 + digit;
                }

                var encoded: [4]u8 = undefined;
                const encoded_len = unicode.utf8Encode(@intCast(value), &encoded) catch {
                    unreachable;
                };
                try output.appendSlice(allocator, encoded[0..encoded_len]);
                index = cursor + 1;
                continue;
            },
            else => {
                unreachable;
            },
        }

        index += 2;
    }

    return output.toOwnedSlice(allocator);
}

const Scalar = struct {
    value: u21,
    len: usize,
};

fn decodeScalar(source: []const u8, index: usize, end: usize) ?Scalar {
    const is_scalar_start_in_bounds = index < end;
    if (!is_scalar_start_in_bounds) {
        return null;
    }

    const length = unicode.utf8ByteSequenceLength(source[index]) catch {
        return null;
    };
    const len: usize = length;
    const remaining_content_len = end - index;
    const scalar_fits_remaining_content = len <= remaining_content_len;
    if (!scalar_fits_remaining_content) {
        return null;
    }

    const value = unicode.utf8Decode(source[index .. index + len]) catch {
        return null;
    };
    const scalar: Scalar = .{
        .value = value,
        .len = len,
    };

    return scalar;
}

fn isForbiddenControl(codepoint: u21) bool {
    const is_allowed_ascii_control = codepoint == '\t' or codepoint == '\r' or codepoint == '\n';
    const is_c0_control = codepoint < 0x20;
    if (is_c0_control) {
        return !is_allowed_ascii_control;
    }

    const is_c1_control = codepoint >= 0x7f and codepoint <= 0x9f;

    return is_c1_control;
}

fn findLastNewline(source: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    var result: ?usize = null;
    while (index < end) {
        if (isNewline(source[index])) {
            result = index;
            index += physicalNewlineLength(source, index, end);
        } else {
            index += 1;
        }
    }

    return result;
}

fn physicalNewlineLength(source: []const u8, index: usize, end: usize) usize {
    const starts_with_carriage_return = source[index] == '\r';
    const remaining_source_len = end - index;
    const has_following_byte = remaining_source_len > 1;
    const is_crlf = starts_with_carriage_return and has_following_byte and source[index + 1] == '\n';
    if (is_crlf) {
        return 2;
    }

    return 1;
}

fn isNewline(byte: u8) bool {
    return byte == '\r' or byte == '\n';
}

fn lineIsBlank(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!isIndentByte(byte)) {
            return false;
        }
    }

    return true;
}

fn indentationLength(bytes: []const u8) usize {
    var length: usize = 0;
    while (length < bytes.len and isIndentByte(bytes[length])) : (length += 1) {}

    return length;
}

fn isIndent(bytes: []const u8) bool {
    return lineIsBlank(bytes);
}

fn isIndentByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn hexValue(byte: u8) ?u32 {
    if (byte >= '0' and byte <= '9') {
        return byte - '0';
    }

    if (byte >= 'a' and byte <= 'f') {
        return byte - 'a' + 10;
    }

    if (byte >= 'A' and byte <= 'F') {
        return byte - 'A' + 10;
    }

    return null;
}

test "ordinary and dedented strings preserve physical line endings" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const ordinary = try decode(arena.allocator(), "'a\r\nb'", .{
        .start = 0,
        .len = 6,
    }, .ordinary, true);
    try testing.expectEqualStrings("a\r\nb", ordinary.decoded.?);

    const dedented_source = "|'\r\n\tfirst\r\n\tsecond\r\n'";
    const dedented = try decode(arena.allocator(), dedented_source, .{
        .start = 0,
        .len = dedented_source.len,
    }, .dedented, true);
    try testing.expectEqualStrings("first\r\nsecond", dedented.decoded.?);
}

test "folded strings fold ordinary paragraphs and preserve indented lines" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const paragraph = ">'first\nsecond\n\nthird'";
    const result = try decode(arena.allocator(), paragraph, .{
        .start = 0,
        .len = paragraph.len,
    }, .folded, true);
    try testing.expectEqualStrings("first second\nthird", result.decoded.?);

    const code = ">'intro\n  code\nend'";
    const code_result = try decode(arena.allocator(), code, .{
        .start = 0,
        .len = code.len,
    }, .folded, true);
    try testing.expectEqualStrings("intro\n  code\nend", code_result.decoded.?);
}

test "escape decoding preserves Unicode and reports raw escape spans" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const valid = "'hello \\u{1F600}\\n'";
    const decoded = try decode(arena.allocator(), valid, .{
        .start = 0,
        .len = valid.len,
    }, .ordinary, true);
    try testing.expectEqualStrings("hello 😀\n", decoded.decoded.?);

    const invalid = "'x\\q'";
    const bad = try decode(arena.allocator(), invalid, .{
        .start = 0,
        .len = invalid.len,
    }, .ordinary, true);
    try testing.expect(bad.decoded == null);
    try testing.expectEqualStrings("invalid_escape", bad.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 2), bad.diagnostics[0].span.start);
}

test "empty marked blocks remove only their shared framing newline" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "|'\n'";
    const decoded = try decode(arena.allocator(), source, .{
        .start = 0,
        .len = source.len,
    }, .dedented, true);
    try testing.expectEqualStrings("", decoded.decoded.?);
}

test "physical newline escapes are diagnosed before marked layout is removed" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "|'\n  \\\n  text'";
    const decoded = try decode(arena.allocator(), source, .{
        .start = 0,
        .len = source.len,
    }, .dedented, true);
    try testing.expect(decoded.decoded == null);
    try testing.expectEqualStrings("invalid_escape", decoded.diagnostics[0].code);
}

test "marked layout preserves exact tab space prefixes and folded blank line counts" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const mixed_indent = "|'\n \talpha\n \t  deeper\n \tbeta\n \t'";
    const mixed = try decode(
        arena.allocator(),
        mixed_indent,
        .{
            .start = 0,
            .len = mixed_indent.len,
        },
        .dedented,
        true,
    );
    try testing.expectEqualStrings("alpha\n  deeper\nbeta", mixed.decoded.?);

    const paragraph = ">'first\n\n\nsecond\n  code\nlast'";
    const folded = try decode(
        arena.allocator(),
        paragraph,
        .{
            .start = 0,
            .len = paragraph.len,
        },
        .folded,
        true,
    );
    try testing.expectEqualStrings("first\n\nsecond\n  code\nlast", folded.decoded.?);
}

test "folded CRLF layout uses LF and retains framing adjacent empty lines" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const crlf = ">'first\r\n  code\r\nlast'";
    const folded = try decode(arena.allocator(), crlf, .{
        .start = 0,
        .len = crlf.len,
    }, .folded, true);
    try testing.expectEqualStrings("first\n  code\nlast", folded.decoded.?);

    const empties = ">'\n\n    first\n\n\n    '";
    const with_empty_lines = try decode(
        arena.allocator(),
        empties,
        .{
            .start = 0,
            .len = empties.len,
        },
        .folded,
        true,
    );
    try testing.expectEqualStrings("\nfirst\n\n", with_empty_lines.decoded.?);
}

test "invalid Unicode scalar escapes and overlong escapes report raw spans" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const invalid_sources = [_][]const u8{
        "'\\u{D800}'",
        "'\\u{110000}'",
        "'\\u{1234567}'",
        "'\\u{}'",
    };
    for (invalid_sources) |source| {
        const result = try decode(arena.allocator(), source, .{
            .start = 0,
            .len = source.len,
        }, .ordinary, true);
        try testing.expect(result.decoded == null);
        try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try testing.expectEqualStrings("invalid_escape", result.diagnostics[0].code);
        try testing.expectEqual(@as(usize, 1), result.diagnostics[0].span.start);
        try testing.expect(result.diagnostics[0].span.len > 1);
    }
}
