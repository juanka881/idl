const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const diag = @import("diagnostics.zig");
const literal = @import("literals.zig");
const syntax = @import("syntax.zig");
const text = @import("text.zig");

pub const NameMode = enum {
    header,
    symbol,
};

pub const Context = struct {
    name_mode: NameMode = .symbol,
    operand_start: bool = false,
};

pub const Probe = struct {
    kind: syntax.TokenKind,
    span: text.TextSpan,
    leading_span: text.TextSpan = .{
        .start = 0,
        .len = 0,
    },
    has_gap: bool = false,
    has_logical_newline: bool = false,
    string_style: ?syntax.StringStyle = null,
    string_terminated: bool = false,
    invalid_number: bool = false,
    radix: ?syntax.Radix = null,
    number_span: ?text.TextSpan = null,
    unit_span: ?text.TextSpan = null,
    invalid_character: bool = false,
    invalid_control: bool = false,
    invalid_continuation: bool = false,
    invalid_operator: bool = false,
};

pub const ScannedToken = struct {
    token: syntax.Token,
    decoded_string: ?[]const u8 = null,
    string_style: ?syntax.StringStyle = null,
    radix: ?syntax.Radix = null,
    number_span: ?text.TextSpan = null,
    unit_span: ?text.TextSpan = null,
};

pub const Options = struct {
    report_invalid_utf8: bool = true,
};

pub const Scanner = struct {
    allocator: Allocator,
    source: []const u8,
    options: Options,
    cursor: usize = 0,
    diagnostic_list: ArrayList(diag.Diagnostic) = .empty,
    owned_trivia: ArrayList([]const syntax.Trivia) = .empty,
    owned_strings: ArrayList([]const u8) = .empty,

    pub fn init(allocator: Allocator, source: []const u8, options: Options) Scanner {
        const scanner: Scanner = .{
            .allocator = allocator,
            .source = source,
            .options = options,
        };

        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        for (self.owned_trivia.items) |trivia| {
            self.allocator.free(trivia);
        }

        for (self.owned_strings.items) |decoded| {
            self.allocator.free(decoded);
        }

        self.owned_trivia.deinit(self.allocator);
        self.owned_strings.deinit(self.allocator);
        self.diagnostic_list.deinit(self.allocator);
    }

    pub fn diagnostics(self: *const Scanner) []const diag.Diagnostic {
        return self.diagnostic_list.items;
    }

    pub fn probe(self: *const Scanner, context: Context) ?Probe {
        const token_start = self.skipTriviaForProbe(self.cursor);
        var result: Probe = undefined;
        if (token_start == self.source.len) {
            result = Probe{
                .kind = .end_of_file,
                .span = .{
                    .start = self.source.len,
                    .len = 0,
                },
            };
        } else {
            result = self.probeTokenAt(token_start, context) orelse {
                return null;
            };
        }

        result.leading_span = makeSpan(self.cursor, token_start);
        result.has_gap = token_start > self.cursor;
        result.has_logical_newline = containsLogicalNewline(self.source, self.cursor, token_start);

        return result;
    }

    pub fn probePropertyName(self: *const Scanner) ?text.TextSpan {
        const name_start = self.skipTriviaForProbe(self.cursor);
        if (isNumericLookingPrefix(self.source, name_start)) {
            return null;
        }

        const name_end = self.scanWord(name_start, .header) orelse {
            return null;
        };
        if (name_end == name_start) {
            return null;
        }

        var lookahead = name_end;
        while (lookahead < self.source.len) {
            if (isHorizontalWhitespace(self.source[lookahead])) {
                lookahead += 1;
                continue;
            }

            if (startsWith(self.source, lookahead, "/*")) {
                const close = findBlockCommentEnd(self.source, lookahead + 2) orelse {
                    return null;
                };
                lookahead = close;
                continue;
            }

            if (self.source[lookahead] == '\\') {
                const continuation_end = continuationEnd(self.source, lookahead) orelse {
                    return null;
                };
                lookahead = continuation_end;
                continue;
            }

            break;
        }

        const equals_position_is_in_bounds = lookahead < self.source.len;
        if (!equals_position_is_in_bounds) {
            return null;
        }

        const has_equals = self.source[lookahead] == '=';
        if (!has_equals) {
            return null;
        }

        const remaining_source_len = self.source.len - lookahead;
        const has_following_byte = remaining_source_len > 1;
        const is_double_equals = has_following_byte and self.source[lookahead + 1] == '=';
        if (is_double_equals) {
            return null;
        }

        const name_span: text.TextSpan = .{
            .start = name_start,
            .len = name_end - name_start,
        };

        return name_span;
    }

    pub fn next(self: *Scanner, context: Context) Allocator.Error!ScannedToken {
        var trivia: ArrayList(syntax.Trivia) = .empty;
        defer {
            trivia.deinit(self.allocator);
        }

        try self.scanLeadingTrivia(&trivia);
        const trivia_copy = try self.copyTrivia(trivia.items);

        const has_source_at_cursor = self.cursor < self.source.len;
        if (!has_source_at_cursor) {
            const eof_span: text.TextSpan = .{
                .start = self.source.len,
                .len = 0,
            };
            const eof_token: syntax.Token = .{
                .kind = .end_of_file,
                .span = eof_span,
                .leading_trivia = trivia_copy,
            };
            const eof_scanned_token: ScannedToken = .{
                .token = eof_token,
            };

            return eof_scanned_token;
        }

        const probe_result = self.probeTokenAt(self.cursor, context) orelse {
            unreachable;
        };
        const token_start = probe_result.span.start;
        const token_end = probe_result.span.end();
        self.cursor = token_end;

        try self.reportInvalidUtf8(token_start, token_end);
        if (probe_result.invalid_number) {
            try self.appendDiagnostic(diag.invalid_number_code, diag.invalid_number_message, probe_result.span);
        }

        if (probe_result.invalid_character) {
            try self.appendDiagnostic(diag.invalid_character_code, diag.invalid_character_message, probe_result.span);
        }

        if (probe_result.invalid_control) {
            try self.appendDiagnostic(diag.invalid_control_code, diag.invalid_control_message, probe_result.span);
        }

        if (probe_result.invalid_continuation) {
            try self.appendDiagnostic(diag.invalid_continuation_code, diag.invalid_continuation_message, probe_result.span);
        }

        if (probe_result.invalid_operator) {
            try self.appendDiagnostic(diag.invalid_operator_code, diag.invalid_operator_message, probe_result.span);
        }

        var decoded_string: ?[]const u8 = null;
        if (probe_result.kind == .string) {
            const style = probe_result.string_style.?;
            const decoded = try literal.decode(
                self.allocator,
                self.source,
                probe_result.span,
                style,
                probe_result.string_terminated,
            );
            decoded_string = decoded.decoded;
            if (decoded_string) |string| {
                self.owned_strings.append(self.allocator, string) catch |err| {
                    self.allocator.free(string);

                    return err;
                };
            }

            if (decoded.diagnostics.len > 0) {
                self.diagnostic_list.appendSlice(self.allocator, decoded.diagnostics) catch |err| {
                    self.allocator.free(decoded.diagnostics);

                    return err;
                };
                self.allocator.free(decoded.diagnostics);
            }

            if (!probe_result.string_terminated) {
                try self.appendDiagnostic(
                    diag.unterminated_string_code,
                    diag.unterminated_string_message,
                    probe_result.span,
                );
            }
        }

        const token: syntax.Token = .{
            .kind = probe_result.kind,
            .span = probe_result.span,
            .leading_trivia = trivia_copy,
        };
        const scanned_token: ScannedToken = .{
            .token = token,
            .decoded_string = decoded_string,
            .string_style = probe_result.string_style,
            .radix = probe_result.radix,
            .number_span = probe_result.number_span,
            .unit_span = probe_result.unit_span,
        };

        return scanned_token;
    }

    fn scanLeadingTrivia(self: *Scanner, trivia: *ArrayList(syntax.Trivia)) Allocator.Error!void {
        while (self.cursor < self.source.len) {
            const start = self.cursor;
            const byte = self.source[self.cursor];

            if (isHorizontalWhitespace(byte)) {
                self.cursor += 1;
                while (self.cursor < self.source.len and isHorizontalWhitespace(self.source[self.cursor])) : (self.cursor += 1) {}

                try trivia.append(self.allocator, .{
                    .kind = .horizontal_whitespace,
                    .span = makeSpan(start, self.cursor),
                });
                try self.reportInvalidUtf8(start, self.cursor);
                continue;
            }

            if (isNewline(byte)) {
                self.cursor += physicalNewlineLength(self.source, self.cursor);
                try trivia.append(self.allocator, .{
                    .kind = .newline,
                    .span = makeSpan(start, self.cursor),
                });
                continue;
            }

            if (startsWith(self.source, self.cursor, "//")) {
                self.cursor += 2;
                while (self.cursor < self.source.len and !isNewline(self.source[self.cursor])) : (self.cursor += 1) {}

                try trivia.append(self.allocator, .{
                    .kind = .line_comment,
                    .span = makeSpan(start, self.cursor),
                });
                try self.reportInvalidUtf8(start, self.cursor);
                continue;
            }

            if (startsWith(self.source, self.cursor, "/*")) {
                const comment_end = findBlockCommentEnd(self.source, self.cursor + 2);
                self.cursor = comment_end orelse self.source.len;
                try trivia.append(self.allocator, .{
                    .kind = .block_comment,
                    .span = makeSpan(start, self.cursor),
                });
                try self.reportInvalidUtf8(start, self.cursor);
                if (comment_end == null) {
                    try self.appendDiagnostic(
                        diag.unterminated_comment_code,
                        diag.unterminated_comment_message,
                        makeSpan(start, self.cursor),
                    );
                }

                continue;
            }

            if (byte == '\\') {
                if (continuationEnd(self.source, self.cursor)) |continuation_end| {
                    self.cursor = continuation_end;
                    try trivia.append(self.allocator, .{
                        .kind = .continuation,
                        .span = makeSpan(start, self.cursor),
                    });
                    try self.reportInvalidUtf8(start, self.cursor);
                    continue;
                }

                break;
            }

            break;
        }
    }

    fn copyTrivia(self: *Scanner, trivia: []const syntax.Trivia) Allocator.Error![]const syntax.Trivia {
        if (trivia.len == 0) {
            const empty_trivia: []const syntax.Trivia = &.{};

            return empty_trivia;
        }

        const copy = try self.allocator.alloc(syntax.Trivia, trivia.len);
        @memcpy(copy, trivia);

        errdefer {
            self.allocator.free(copy);
        }

        try self.owned_trivia.append(self.allocator, copy);

        return copy;
    }

    fn probeTokenAt(self: *const Scanner, start: usize, context: Context) ?Probe {
        const is_start_in_bounds = start < self.source.len;
        if (!is_start_in_bounds) {
            return null;
        }

        const byte = self.source[start];

        const starts_ordinary_string = byte == '\'';
        const starts_marked_string = isAdjacentMarkedStringStart(self.source, start, context.operand_start);
        if (starts_ordinary_string or starts_marked_string) {
            const style = stringStyleAt(self.source, start);
            const quote_start = start + @intFromBool(style != .ordinary);
            const string_end = self.scanStringEnd(quote_start);
            const string_span = makeSpan(start, string_end.end);
            const string_probe: Probe = .{
                .kind = .string,
                .span = string_span,
                .string_style = style,
                .string_terminated = string_end.terminated,
            };

            return string_probe;
        }

        const starts_decimal_digit = isAsciiDigit(byte);
        const remaining_source_len = self.source.len - start;
        const has_following_byte = remaining_source_len > 1;
        const starts_fractional_number = byte == '.' and
            has_following_byte and
            isAsciiDigit(self.source[start + 1]);
        if (starts_decimal_digit or starts_fractional_number) {
            return self.probeNumber(start);
        }

        if (context.name_mode == .header and isNumericLookingPrefix(self.source, start)) {
            const span: text.TextSpan = .{
                .start = start,
                .len = 1,
            };
            const numeric_prefix_probe: Probe = .{
                .kind = .operator,
                .span = span,
            };

            return numeric_prefix_probe;
        }

        const is_header_name_mode = context.name_mode == .header;
        const is_hyphen = byte == '-';
        const has_non_digit_after_hyphen = has_following_byte and !isAsciiDigit(self.source[start + 1]);
        const starts_hyphenated_header_name = is_header_name_mode and is_hyphen and has_non_digit_after_hyphen;
        if (starts_hyphenated_header_name) {
            if (self.scanWord(start, .header)) |word_end| {
                const name_span = makeSpan(start, word_end);
                const header_name_probe: Probe = .{
                    .kind = .name,
                    .span = name_span,
                };

                return header_name_probe;
            }
        }

        if (self.scanWord(start, context.name_mode)) |word_end| {
            const word_span = makeSpan(start, word_end);
            var kind: syntax.TokenKind = .symbol;
            if (context.name_mode == .header) {
                kind = .name;
            }

            const word_probe: Probe = .{
                .kind = kind,
                .span = word_span,
            };

            return word_probe;
        }

        return self.probePunctuation(start, context);
    }

    fn probePunctuation(self: *const Scanner, start: usize, context: Context) Probe {
        const byte = self.source[start];
        if (byte == '\\') {
            const span: text.TextSpan = .{
                .start = start,
                .len = 1,
            };
            const invalid_continuation_probe: Probe = .{
                .kind = .unknown,
                .span = span,
                .invalid_continuation = true,
            };

            return invalid_continuation_probe;
        }

        const single: ?syntax.TokenKind = switch (byte) {
            '@' => .at_sign,
            '=' => .equals,
            ',' => .comma,
            ';' => .semicolon,
            '(' => .left_parenthesis,
            ')' => .right_parenthesis,
            '[' => .left_bracket,
            ']' => .right_bracket,
            '{' => .left_brace,
            '}' => .right_brace,
            else => null,
        };
        if (single) |kind| {
            const is_equals_sign = byte == '=';
            const remaining_source_len = self.source.len - start;
            const has_following_byte = remaining_source_len > 1;
            const is_double_equals = is_equals_sign and has_following_byte and self.source[start + 1] == '=';
            if (is_double_equals) {
                const span: text.TextSpan = .{
                    .start = start,
                    .len = 2,
                };
                const equals_operator_probe: Probe = .{
                    .kind = .operator,
                    .span = span,
                };

                return equals_operator_probe;
            }

            const span: text.TextSpan = .{
                .start = start,
                .len = 1,
            };
            const punctuation_probe: Probe = .{
                .kind = kind,
                .span = span,
            };

            return punctuation_probe;
        }

        if (isComparisonBeforeFoldedString(self.source, start, context)) {
            const span: text.TextSpan = .{
                .start = start,
                .len = 1,
            };
            const comparison_probe: Probe = .{
                .kind = .operator,
                .span = span,
            };

            return comparison_probe;
        }

        if (unsupportedOperatorPair(self.source, start)) |length| {
            const span = makeSpan(start, start + length);
            const invalid_operator_probe: Probe = .{
                .kind = .unknown,
                .span = span,
                .invalid_operator = true,
            };

            return invalid_operator_probe;
        }

        if (isOperator(byte)) {
            var length: usize = 1;
            const can_be_followed_by_equals = byte == '!' or byte == '<' or byte == '>';
            const remaining_source_len = self.source.len - start;
            const has_following_byte = remaining_source_len > 1;
            const has_equals_suffix = has_following_byte and self.source[start + 1] == '=';
            const is_two_byte_comparison = can_be_followed_by_equals and has_equals_suffix;
            if (is_two_byte_comparison) {
                length = 2;
            }

            const span: text.TextSpan = .{
                .start = start,
                .len = length,
            };
            const operator_probe: Probe = .{
                .kind = .operator,
                .span = span,
            };

            return operator_probe;
        }

        const decoded = decodeAt(self.source, start);
        if (decoded) |scalar| {
            if (isControl(scalar.value)) {
                const span: text.TextSpan = .{
                    .start = start,
                    .len = scalar.len,
                };
                const control_probe: Probe = .{
                    .kind = .unknown,
                    .span = span,
                    .invalid_control = true,
                };

                return control_probe;
            }

            const span: text.TextSpan = .{
                .start = start,
                .len = scalar.len,
            };
            const invalid_character_probe: Probe = .{
                .kind = .unknown,
                .span = span,
                .invalid_character = true,
            };

            return invalid_character_probe;
        }

        const span: text.TextSpan = .{
            .start = start,
            .len = 1,
        };
        const unknown_probe: Probe = .{
            .kind = .unknown,
            .span = span,
        };

        return unknown_probe;
    }

    fn probeNumber(self: *const Scanner, start: usize) Probe {
        const end = self.source.len;
        var is_valid_number = true;

        if (self.source[start] == '.') {
            const invalid_end = consumeNumericTail(self.source, start + 1);
            const invalid_span = makeSpan(start, invalid_end);
            const invalid_number: Probe = .{
                .kind = .unknown,
                .span = invalid_span,
                .invalid_number = true,
            };

            return invalid_number;
        }

        const starts_with_zero = self.source[start] == '0';
        const remaining_number_len = end - start;
        const has_prefix_letter = remaining_number_len > 1;
        const prefix_letter_is_x = has_prefix_letter and
            (self.source[start + 1] == 'x' or self.source[start + 1] == 'X');
        const has_hexadecimal_prefix = starts_with_zero and prefix_letter_is_x;
        if (has_hexadecimal_prefix) {
            var index = start + 2;
            const digit_start = index;
            while (index < end and isHexDigit(self.source[index])) : (index += 1) {}

            if (index == digit_start) {
                is_valid_number = false;
            }

            const numeric_end = index;

            while (index < end and isAsciiLetter(self.source[index])) : (index += 1) {}

            const unit_end = index;
            const has_current_byte = index < end;
            const has_trailing_digit_or_dot = has_current_byte and
                (isAsciiDigit(self.source[index]) or self.source[index] == '.');
            if (has_trailing_digit_or_dot) {
                is_valid_number = false;
                index = consumeNumericTail(self.source, index);
            }

            const has_numeric_word_continuation = index < end and isNumericContinuation(self.source, index);
            if (has_numeric_word_continuation) {
                is_valid_number = false;
                index = consumeNumericTail(self.source, index);
            }

            const has_hex_suffix = unit_end > digit_start;
            if (!has_hex_suffix) {
                is_valid_number = false;
                index = consumeNumericTail(self.source, index);
            }

            var token_end = @max(unit_end, index);
            if (is_valid_number) {
                token_end = unit_end;
            }

            var number_span: ?text.TextSpan = null;
            if (is_valid_number) {
                number_span = makeSpan(start, numeric_end);
            }

            var unit_span: ?text.TextSpan = null;
            if (is_valid_number and unit_end > numeric_end) {
                unit_span = makeSpan(numeric_end, unit_end);
            }

            var number_kind: syntax.TokenKind = .unknown;
            if (is_valid_number) {
                number_kind = .number;
            }

            var number_radix: ?syntax.Radix = null;
            if (is_valid_number) {
                number_radix = .hexadecimal;
            }

            const number_probe: Probe = .{
                .kind = number_kind,
                .span = makeSpan(start, token_end),
                .invalid_number = !is_valid_number,
                .radix = number_radix,
                .number_span = number_span,
                .unit_span = unit_span,
            };

            return number_probe;
        }

        var index = start;
        while (index < end and isAsciiDigit(self.source[index])) : (index += 1) {}

        const decimal_starts_with_zero = self.source[start] == '0';
        const has_additional_integer_digits = index - start > 1;
        const has_leading_zero = decimal_starts_with_zero and has_additional_integer_digits;
        if (has_leading_zero) {
            is_valid_number = false;
        }

        const has_decimal_point = index < end and self.source[index] == '.';
        if (has_decimal_point) {
            index += 1;
            const fraction_start = index;
            while (index < end and isAsciiDigit(self.source[index])) : (index += 1) {}

            if (index == fraction_start) {
                is_valid_number = false;
            }
        }

        const has_exponent_marker = index < end and
            (self.source[index] == 'e' or self.source[index] == 'E');
        if (has_exponent_marker) {
            const exponent_start = index;
            var exponent_digits = index + 1;
            var has_exponent_sign = false;
            const has_exponent_sign_byte = exponent_digits < end;
            const is_exponent_sign = has_exponent_sign_byte and
                (self.source[exponent_digits] == '+' or self.source[exponent_digits] == '-');
            if (is_exponent_sign) {
                has_exponent_sign = true;
                exponent_digits += 1;
            }

            const digit_start = exponent_digits;
            while (exponent_digits < end and isAsciiDigit(self.source[exponent_digits])) : (exponent_digits += 1) {}

            const has_exponent_digits = exponent_digits > digit_start;
            if (has_exponent_digits) {
                index = exponent_digits;
            } else if (has_exponent_sign) {
                index = exponent_start;
            }
        }

        const numeric_end = index;
        while (index < end and isAsciiLetter(self.source[index])) : (index += 1) {}

        const unit_end = index;
        const has_current_byte = index < end;
        const has_trailing_digit_or_dot = has_current_byte and
            (isAsciiDigit(self.source[index]) or self.source[index] == '.');
        if (has_trailing_digit_or_dot) {
            is_valid_number = false;
            index = consumeNumericTail(self.source, index);
        }

        const has_numeric_word_continuation = index < end and isNumericContinuation(self.source, index);
        if (has_numeric_word_continuation) {
            is_valid_number = false;
            index = consumeNumericTail(self.source, index);
        }

        var number_span: ?text.TextSpan = null;
        if (is_valid_number) {
            number_span = makeSpan(start, numeric_end);
        }

        var unit_span: ?text.TextSpan = null;
        if (is_valid_number and unit_end > numeric_end) {
            unit_span = makeSpan(numeric_end, unit_end);
        }

        var number_kind: syntax.TokenKind = .unknown;
        if (is_valid_number) {
            number_kind = .number;
        }

        var number_radix: ?syntax.Radix = null;
        if (is_valid_number) {
            number_radix = .decimal;
        }

        const number_probe: Probe = .{
            .kind = number_kind,
            .span = makeSpan(start, index),
            .invalid_number = !is_valid_number,
            .radix = number_radix,
            .number_span = number_span,
            .unit_span = unit_span,
        };

        return number_probe;
    }

    fn scanWord(self: *const Scanner, start: usize, mode: NameMode) ?usize {
        const is_start_in_bounds = start < self.source.len;
        if (!is_start_in_bounds) {
            return null;
        }

        var index = start;
        const allow_hyphen = mode == .header;
        var first = true;

        while (index < self.source.len) {
            const scalar = decodeAt(self.source, index) orelse {
                break;
            };
            if (!isWordCodepoint(scalar.value, allow_hyphen)) {
                break;
            }

            const begins_with_digit = first and isAsciiDigit(self.source[index]);
            if (begins_with_digit) {
                break;
            }

            const begins_with_numeric_word = first and startsNumericWord(self.source, index);
            if (begins_with_numeric_word) {
                break;
            }

            index += scalar.len;
            first = false;
        }

        if (first) {
            return null;
        }

        return index;
    }

    fn scanStringEnd(self: *const Scanner, quote_start: usize) StringEnd {
        var index = quote_start + 1;
        while (index < self.source.len) {
            if (self.source[index] == '\'') {
                const string_end: StringEnd = .{
                    .end = index + 1,
                    .terminated = true,
                };

                return string_end;
            }

            if (self.source[index] == '\\') {
                index += 1;
                if (index < self.source.len) {
                    if (isNewline(self.source[index])) {
                        index += physicalNewlineLength(self.source, index);
                    } else if (decodeAt(self.source, index)) |scalar| {
                        index += scalar.len;
                    } else {
                        index += 1;
                    }
                }

                continue;
            }

            if (decodeAt(self.source, index)) |scalar| {
                index += scalar.len;
            } else {
                index += 1;
            }
        }

        const unterminated_string_end: StringEnd = .{
            .end = self.source.len,
            .terminated = false,
        };

        return unterminated_string_end;
    }

    fn skipTriviaForProbe(self: *const Scanner, initial: usize) usize {
        var index = initial;
        while (index < self.source.len) {
            if (isHorizontalWhitespace(self.source[index])) {
                index += 1;
                continue;
            }

            if (isNewline(self.source[index])) {
                index += physicalNewlineLength(self.source, index);
                continue;
            }

            if (startsWith(self.source, index, "//")) {
                while (index < self.source.len and !isNewline(self.source[index])) : (index += 1) {}

                continue;
            }

            if (startsWith(self.source, index, "/*")) {
                index = findBlockCommentEnd(self.source, index + 2) orelse {
                    return self.source.len;
                };
                continue;
            }

            if (self.source[index] == '\\') {
                index = continuationEnd(self.source, index) orelse {
                    return index;
                };
                continue;
            }

            break;
        }

        return index;
    }

    fn reportInvalidUtf8(self: *Scanner, start: usize, end: usize) Allocator.Error!void {
        if (!self.options.report_invalid_utf8) {
            return;
        }

        var index = start;
        while (index < end) {
            if (decodeAt(self.source, index)) |scalar| {
                index += scalar.len;
                continue;
            }

            try self.appendDiagnostic(
                diag.invalid_utf8_code,
                diag.invalid_utf8_message,
                .{
                    .start = index,
                    .len = 1,
                },
            );
            index += 1;
        }
    }

    fn appendDiagnostic(self: *Scanner, code: []const u8, message: []const u8, span: text.TextSpan) Allocator.Error!void {
        try self.diagnostic_list.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .span = span,
        });
    }
};

const StringEnd = struct {
    end: usize,
    terminated: bool,
};

const DecodedScalar = struct {
    value: u21,
    len: usize,
};

fn decodeAt(bytes: []const u8, index: usize) ?DecodedScalar {
    const is_index_in_bounds = index < bytes.len;
    if (!is_index_in_bounds) {
        return null;
    }

    const length = unicode.utf8ByteSequenceLength(bytes[index]) catch {
        return null;
    };
    const len: usize = length;
    const scalar_fits_remaining_bytes = len <= bytes.len - index;
    if (!scalar_fits_remaining_bytes) {
        return null;
    }

    const value = unicode.utf8Decode(bytes[index .. index + len]) catch {
        return null;
    };
    const scalar: DecodedScalar = .{
        .value = value,
        .len = len,
    };

    return scalar;
}

fn isWordCodepoint(codepoint: u21, allow_hyphen: bool) bool {
    const is_whitespace_or_control = isUnicodeWhitespace(codepoint) or isControl(codepoint);
    if (is_whitespace_or_control) {
        return false;
    }

    const is_byte_order_mark = codepoint == 0xfeff;
    if (is_byte_order_mark) {
        return false;
    }

    if (codepoint > 0x7f) {
        return true;
    }

    const byte: u8 = @intCast(codepoint);
    if (isHorizontalWhitespace(byte) or isNewline(byte)) {
        return false;
    }

    if (byte == '-') {
        return allow_hyphen;
    }

    return switch (byte) {
        '\'', '"', '\\', '/', '(', ')', '[', ']', '{', '}', '=', ';', '@', ',', '<', '>', '|', '+', '*', '%', '!', '&', '^', '?', '~' => false,
        else => true,
    };
}

fn isUnicodeWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0085, 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        0x2000...0x200a => true,
        else => false,
    };
}

fn isControl(codepoint: u21) bool {
    const is_c0_control = codepoint < 0x20;
    const is_c1_control = codepoint >= 0x7f and codepoint <= 0x9f;

    return is_c0_control or is_c1_control;
}

fn isHorizontalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c;
}

fn isNewline(byte: u8) bool {
    return byte == '\r' or byte == '\n';
}

fn isAsciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn startsNumericWord(source: []const u8, index: usize) bool {
    const is_index_in_bounds = index < source.len;
    if (!is_index_in_bounds) {
        return false;
    }

    const starts_with_numeric_punctuation = source[index] == '-' or source[index] == '.';
    if (!starts_with_numeric_punctuation) {
        return false;
    }

    const remaining_source_len = source.len - index;
    const has_following_byte = remaining_source_len > 1;
    if (!has_following_byte) {
        return false;
    }

    return isAsciiDigit(source[index + 1]);
}

fn isNumericLookingPrefix(source: []const u8, start: usize) bool {
    const start_is_in_bounds = start < source.len;
    if (!start_is_in_bounds) {
        return false;
    }

    const remaining_source_len = source.len - start;
    const has_following_byte = remaining_source_len > 1;
    if (!has_following_byte) {
        return false;
    }

    const starts_with_minus = source[start] == '-';
    const next_byte_is_digit = isAsciiDigit(source[start + 1]);

    return starts_with_minus and next_byte_is_digit;
}

fn isAdjacentMarkedStringStart(source: []const u8, start: usize, operand_start: bool) bool {
    if (!operand_start) {
        return false;
    }

    const start_is_in_bounds = start < source.len;
    if (!start_is_in_bounds) {
        return false;
    }

    if (source[start] != '|' and source[start] != '>') {
        return false;
    }

    const remaining_source_len = source.len - start;
    const has_following_byte = remaining_source_len > 1;
    if (!has_following_byte) {
        return false;
    }

    return source[start + 1] == '\'';
}

fn stringStyleAt(source: []const u8, start: usize) syntax.StringStyle {
    if (source[start] == '|') {
        return .dedented;
    }

    if (source[start] == '>') {
        return .folded;
    }

    return .ordinary;
}

fn isAsciiLetter(byte: u8) bool {
    const is_lowercase_letter = byte >= 'a' and byte <= 'z';
    const is_uppercase_letter = byte >= 'A' and byte <= 'Z';

    return is_lowercase_letter or is_uppercase_letter;
}

fn isHexDigit(byte: u8) bool {
    const is_lowercase_hex_letter = byte >= 'a' and byte <= 'f';
    const is_uppercase_hex_letter = byte >= 'A' and byte <= 'F';

    return isAsciiDigit(byte) or is_lowercase_hex_letter or is_uppercase_hex_letter;
}

fn isOperator(byte: u8) bool {
    return switch (byte) {
        '+', '-', '*', '/', '%', '!', '<', '>' => true,
        else => false,
    };
}

fn unsupportedOperatorPair(source: []const u8, index: usize) ?usize {
    const is_index_in_bounds = index < source.len;
    if (!is_index_in_bounds) {
        return null;
    }

    const remaining_source_len = source.len - index;
    const has_two_bytes_remaining = remaining_source_len > 1;
    if (!has_two_bytes_remaining) {
        return null;
    }

    const first = source[index];
    const second = source[index + 1];
    if (first == '&' and second == '&') {
        return 2;
    }

    if (first == '|' and second == '|') {
        return 2;
    }

    if (first == '*' and second == '*') {
        return 2;
    }

    if (first == '<' and second == '<') {
        return 2;
    }

    if (first == '>' and second == '>') {
        return 2;
    }

    return null;
}

fn isComparisonBeforeFoldedString(source: []const u8, index: usize, context: Context) bool {
    const is_operand_position = context.operand_start;
    if (is_operand_position) {
        return false;
    }

    const operator_start_is_in_bounds = index < source.len;
    if (!operator_start_is_in_bounds) {
        return false;
    }

    const starts_with_greater_than = source[index] == '>';
    if (!starts_with_greater_than) {
        return false;
    }

    return startsWith(source, index, ">>'");
}

fn isNumericContinuation(source: []const u8, index: usize) bool {
    const scalar = decodeAt(source, index) orelse {
        return false;
    };

    return isWordCodepoint(scalar.value, false);
}

fn consumeNumericTail(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len) {
        const scalar = decodeAt(source, index) orelse {
            break;
        };
        if (!isWordCodepoint(scalar.value, false)) {
            break;
        }

        index += scalar.len;
    }

    return index;
}

fn continuationEnd(source: []const u8, start: usize) ?usize {
    const continuation_start_is_in_bounds = start < source.len;
    if (!continuation_start_is_in_bounds) {
        return null;
    }

    const starts_with_backslash = source[start] == '\\';
    if (!starts_with_backslash) {
        return null;
    }

    var index = start + 1;
    while (index < source.len) {
        if (isHorizontalWhitespace(source[index])) {
            index += 1;
            continue;
        }

        if (startsWith(source, index, "/*")) {
            index = findBlockCommentEnd(source, index + 2) orelse {
                return null;
            };
            continue;
        }

        if (startsWith(source, index, "//")) {
            while (index < source.len and !isNewline(source[index])) : (index += 1) {}

            break;
        }

        break;
    }

    const newline_position_is_in_bounds = index < source.len;
    if (!newline_position_is_in_bounds) {
        return null;
    }

    const has_physical_newline = isNewline(source[index]);
    if (!has_physical_newline) {
        return null;
    }

    return index + physicalNewlineLength(source, index);
}

fn findBlockCommentEnd(source: []const u8, content_start: usize) ?usize {
    var index = content_start;
    while (index < source.len) {
        const remaining_source_len = source.len - index;
        const has_two_bytes_remaining = remaining_source_len > 1;
        if (!has_two_bytes_remaining) {
            break;
        }

        if (source[index] == '*' and source[index + 1] == '/') {
            return index + 2;
        }

        index += 1;
    }

    return null;
}

fn physicalNewlineLength(source: []const u8, index: usize) usize {
    const starts_with_carriage_return = source[index] == '\r';
    const remaining_source_len = source.len - index;
    const has_following_byte = remaining_source_len > 1;
    const is_crlf = starts_with_carriage_return and has_following_byte and source[index + 1] == '\n';
    if (is_crlf) {
        return 2;
    }

    return 1;
}

fn startsWith(source: []const u8, index: usize, needle: []const u8) bool {
    const is_start_in_bounds = index <= source.len;
    if (!is_start_in_bounds) {
        return false;
    }

    const remaining_source_len = source.len - index;
    const needle_fits_remaining_source = needle.len <= remaining_source_len;
    if (!needle_fits_remaining_source) {
        return false;
    }

    return mem.eql(u8, source[index .. index + needle.len], needle);
}

fn makeSpan(start: usize, end: usize) text.TextSpan {
    const span: text.TextSpan = .{
        .start = start,
        .len = end - start,
    };

    return span;
}

fn containsLogicalNewline(source: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index < end) {
        if (isNewline(source[index])) {
            return true;
        }

        if (startsWith(source, index, "//")) {
            while (index < end and !isNewline(source[index])) : (index += 1) {}

            continue;
        }

        if (startsWith(source, index, "/*")) {
            index = findBlockCommentEnd(source, index + 2) orelse {
                return false;
            };
            continue;
        }

        if (source[index] == '\\') {
            index = continuationEnd(source, index) orelse {
                index += 1;
                continue;
            };
            continue;
        }

        index += 1;
    }

    return false;
}

test "scanner preserves complete ordered token and trivia coverage" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "  node /*comment\nbody*/ value\r\n//tail";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    var prior_end: usize = 0;
    while (true) {
        const scanned = try scanner.next(.{
            .name_mode = .header,
        });
        for (scanned.token.leading_trivia) |trivia| {
            try testing.expectEqual(prior_end, trivia.span.start);
            prior_end = trivia.span.end();
        }

        try testing.expectEqual(prior_end, scanned.token.span.start);
        prior_end = scanned.token.span.end();
        if (scanned.token.kind == .end_of_file) {
            break;
        }
    }

    try testing.expectEqual(source.len, prior_end);
    try testing.expectEqual(@as(usize, 0), scanner.diagnostics().len);
}

test "property probe is side effect free and requires one equals on this logical line" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var scanner = Scanner.init(arena.allocator(), "mode /* gap */ = value", .{});
    defer {
        scanner.deinit();
    }

    const before = scanner.diagnostics().len;
    const property = scanner.probePropertyName().?;
    try testing.expectEqualStrings("mode", scanner.source[property.start .. property.start + property.len]);
    try testing.expectEqual(before, scanner.diagnostics().len);

    var equality_scanner = Scanner.init(arena.allocator(), "mode == value", .{});
    defer {
        equality_scanner.deinit();
    }

    try testing.expect(equality_scanner.probePropertyName() == null);

    var newline_scanner = Scanner.init(arena.allocator(), "mode\n= value", .{});
    defer {
        newline_scanner.deinit();
    }

    try testing.expect(newline_scanner.probePropertyName() == null);

    var signed_property_scanner = Scanner.init(arena.allocator(), "-2=1", .{});
    defer {
        signed_property_scanner.deinit();
    }

    try testing.expect(signed_property_scanner.probePropertyName() == null);

    var continuation_scanner = Scanner.init(arena.allocator(), "mode \\ /* comment\n*/\r\n= value", .{});
    defer {
        continuation_scanner.deinit();
    }

    try testing.expect(continuation_scanner.probePropertyName() != null);
}

test "peek exposes logical newlines and gaps without consuming trivia" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var scanner = Scanner.init(arena.allocator(), "left /* internal\nnewline */  right\n", .{});
    defer {
        scanner.deinit();
    }

    const first = scanner.probe(.{}).?;
    try testing.expectEqual(@as(usize, 0), first.span.start);
    try testing.expect(!first.has_gap);
    try testing.expect(!first.has_logical_newline);

    _ = try scanner.next(.{});
    const second = scanner.probe(.{}).?;
    try testing.expect(second.has_gap);
    try testing.expect(!second.has_logical_newline);
    try testing.expectEqual(@as(usize, 29), second.span.start);
    try testing.expectEqual(@as(usize, 0), scanner.diagnostics().len);
}

test "strings are contextual and number signs remain operators" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var scanner = Scanner.init(arena.allocator(), "left>'right' left > >'fold' -2", .{});
    defer {
        scanner.deinit();
    }

    const left = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.symbol, left.token.kind);
    const greater = try scanner.next(.{
        .operand_start = false,
    });
    try testing.expectEqual(syntax.TokenKind.operator, greater.token.kind);
    const ordinary = try scanner.next(.{
        .operand_start = true,
    });
    try testing.expectEqual(syntax.StringStyle.ordinary, ordinary.string_style.?);

    _ = try scanner.next(.{});
    _ = try scanner.next(.{
        .operand_start = false,
    });
    const folded = try scanner.next(.{
        .operand_start = true,
    });
    try testing.expectEqual(syntax.StringStyle.folded, folded.string_style.?);

    const minus = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.operator, minus.token.kind);
    const number = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.number, number.token.kind);
}

test "numeric candidates retain radix units and reject malformed tails whole" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "42 1e3ms 1e 0x10B 0x10ms 01 1. 1.2.3 30ms2 0x1p2";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    const expected_kinds = [_]syntax.TokenKind{
        .number,  .number,  .number,  .number,  .number,
        .unknown, .unknown, .unknown, .unknown, .unknown,
    };
    for (expected_kinds) |expected| {
        const scanned = try scanner.next(.{});
        try testing.expectEqual(expected, scanned.token.kind);
    }

    _ = try scanner.next(.{});
    try testing.expectEqual(@as(usize, 5), scanner.diagnostics().len);
    try testing.expectEqualStrings("invalid_number", scanner.diagnostics()[0].code);
}

test "number probes expose radix and exact number and unit spans" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var decimal_scanner = Scanner.init(arena.allocator(), "1e3ms", .{});
    defer {
        decimal_scanner.deinit();
    }

    const decimal = decimal_scanner.probe(.{}).?;
    try testing.expectEqual(syntax.Radix.decimal, decimal.radix.?);
    try testing.expectEqualSlices(u8, "1e3", decimal_scanner.source[decimal.number_span.?.start..decimal.number_span.?.end()]);
    try testing.expectEqualSlices(u8, "ms", decimal_scanner.source[decimal.unit_span.?.start..decimal.unit_span.?.end()]);

    var hexadecimal_scanner = Scanner.init(arena.allocator(), "0x10ms", .{});
    defer {
        hexadecimal_scanner.deinit();
    }

    const hexadecimal = hexadecimal_scanner.probe(.{}).?;
    try testing.expectEqual(syntax.Radix.hexadecimal, hexadecimal.radix.?);
    try testing.expectEqualSlices(u8, "0x10", hexadecimal_scanner.source[hexadecimal.number_span.?.start..hexadecimal.number_span.?.end()]);
    try testing.expectEqualSlices(u8, "ms", hexadecimal_scanner.source[hexadecimal.unit_span.?.start..hexadecimal.unit_span.?.end()]);

    const committed = try hexadecimal_scanner.next(.{});
    try testing.expectEqual(syntax.Radix.hexadecimal, committed.radix.?);
    try testing.expectEqual(hexadecimal.number_span.?.start, committed.number_span.?.start);
    try testing.expectEqual(hexadecimal.unit_span.?.len, committed.unit_span.?.len);
}

test "numeric scanner handles exponent boundaries and the full malformed set" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "3.14 1e1000 1e-3 1em 1e3ms 1e 0xFF 0Xff 0x10B -0xFF 0x10ms 01 .5 1. 1.2.3 30ms2 0x 0xms 0x1.2 0x1p2 1e-";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    for (0..9) |_| {
        const scanned = try scanner.next(.{});
        try testing.expectEqual(syntax.TokenKind.number, scanned.token.kind);
    }

    const minus = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.operator, minus.token.kind);
    const negative_hex = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.number, negative_hex.token.kind);
    try testing.expectEqual(syntax.Radix.hexadecimal, negative_hex.radix.?);
    const hex_unit = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.number, hex_unit.token.kind);
    try testing.expect(hex_unit.unit_span != null);

    const malformed_spellings = [_][]const u8{
        "01", ".5", "1.", "1.2.3", "30ms2", "0x", "0xms", "0x1.2", "0x1p2",
    };
    for (malformed_spellings) |spelling| {
        const malformed = try scanner.next(.{});
        try testing.expectEqual(syntax.TokenKind.unknown, malformed.token.kind);
        try testing.expectEqualStrings(spelling, source[malformed.token.span.start..malformed.token.span.end()]);
    }

    const incomplete_exponent = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.number, incomplete_exponent.token.kind);
    try testing.expectEqualStrings("e", source[incomplete_exponent.unit_span.?.start..incomplete_exponent.unit_span.?.end()]);
    try testing.expectEqual(syntax.TokenKind.operator, (try scanner.next(.{})).token.kind);
    _ = try scanner.next(.{});
    _ = try scanner.next(.{});
    try testing.expectEqual(@as(usize, 9), scanner.diagnostics().len);
}

test "minus remains an operator boundary after numbers and units" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "10-2 30ms-offset 1e-foo 1e+foo";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    const first = try scanner.next(.{});
    try testing.expectEqualSlices(u8, "10", source[first.number_span.?.start..first.number_span.?.end()]);
    try testing.expectEqual(syntax.TokenKind.operator, (try scanner.next(.{})).token.kind);
    try testing.expectEqual(syntax.TokenKind.number, (try scanner.next(.{})).token.kind);

    const unit_number = try scanner.next(.{});
    try testing.expectEqualSlices(u8, "ms", source[unit_number.unit_span.?.start..unit_number.unit_span.?.end()]);
    try testing.expectEqual(syntax.TokenKind.operator, (try scanner.next(.{})).token.kind);
    _ = try scanner.next(.{});

    for (0..2) |_| {
        const number = try scanner.next(.{});
        try testing.expectEqual(syntax.TokenKind.number, number.token.kind);
        try testing.expectEqual(@as(usize, 1), number.unit_span.?.len);
        try testing.expectEqual(syntax.TokenKind.operator, (try scanner.next(.{})).token.kind);
        try testing.expectEqual(syntax.TokenKind.symbol, (try scanner.next(.{})).token.kind);
    }

    try testing.expectEqual(@as(usize, 0), scanner.diagnostics().len);
}

test "numeric candidates reject all adjacent symbol word content" {
    const malformed_candidates = [_][]const u8{
        "30ms:tail",
        "1$tail",
        "1#tail",
        "1`tail",
        "1_name",
        "1.thing",
        "1étiquette",
    };

    for (malformed_candidates) |source| {
        var arena = ArenaAllocator.init(testing.allocator);
        defer {
            arena.deinit();
        }

        var scanner = Scanner.init(arena.allocator(), source, .{});
        defer {
            scanner.deinit();
        }

        const scanned = try scanner.next(.{});
        try testing.expectEqual(syntax.TokenKind.unknown, scanned.token.kind);
        try testing.expectEqualSlices(u8, source, source[scanned.token.span.start..scanned.token.span.end()]);
        try testing.expectEqual(@as(usize, 1), scanner.diagnostics().len);
        try testing.expectEqualStrings("invalid_number", scanner.diagnostics()[0].code);
    }
}

test "header names allow hyphens but do not start with negative numbers" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    var name_scanner = Scanner.init(arena.allocator(), "cache-size -name -2", .{});
    defer {
        name_scanner.deinit();
    }

    const hyphenated = try name_scanner.next(.{
        .name_mode = .header,
    });
    try testing.expectEqual(syntax.TokenKind.name, hyphenated.token.kind);
    const leading_hyphen = try name_scanner.next(.{
        .name_mode = .header,
    });
    try testing.expectEqual(syntax.TokenKind.name, leading_hyphen.token.kind);
    const minus = try name_scanner.next(.{
        .name_mode = .header,
    });
    try testing.expectEqual(syntax.TokenKind.operator, minus.token.kind);
    const number = try name_scanner.next(.{
        .name_mode = .header,
    });
    try testing.expectEqual(syntax.TokenKind.number, number.token.kind);
}

test "comments and line continuation remain distinct trivia" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "a \\ /* comment\ninside */ // tail\r\nb";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    _ = try scanner.next(.{});
    const second = try scanner.next(.{});
    try testing.expectEqual(@as(usize, 2), second.token.leading_trivia.len);
    try testing.expectEqual(syntax.TriviaKind.horizontal_whitespace, second.token.leading_trivia[0].kind);
    try testing.expectEqual(syntax.TriviaKind.continuation, second.token.leading_trivia[1].kind);
    const continuation_span = second.token.leading_trivia[1].span;
    try testing.expect(mem.indexOfScalar(u8, source[continuation_span.start..continuation_span.end()], '\n') != null);
}

test "invalid UTF-8 is diagnosed once per byte in strings and comments" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "'\xff' /*\xfe*/";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    _ = try scanner.next(.{
        .operand_start = true,
    });
    _ = try scanner.next(.{});
    try testing.expectEqual(@as(usize, 2), scanner.diagnostics().len);
    try testing.expectEqualStrings("invalid_utf8", scanner.diagnostics()[0].code);
    try testing.expectEqualStrings("invalid_utf8", scanner.diagnostics()[1].code);
}

test "invalid controls and unsupported operators are rejected as whole tokens" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer {
        arena.deinit();
    }

    const source = "\x01 && || ** << >> \u{00a0}";
    var scanner = Scanner.init(arena.allocator(), source, .{});
    defer {
        scanner.deinit();
    }

    const control = try scanner.next(.{});
    try testing.expectEqual(@as(usize, 1), control.token.span.len);
    try testing.expectEqualStrings("invalid_control", scanner.diagnostics()[0].code);
    for (0..5) |_| {
        const unsupported = try scanner.next(.{});
        try testing.expectEqual(syntax.TokenKind.unknown, unsupported.token.kind);
        try testing.expectEqual(@as(usize, 2), unsupported.token.span.len);
    }

    const whitespace = try scanner.next(.{});
    try testing.expectEqual(syntax.TokenKind.unknown, whitespace.token.kind);
    try testing.expectEqualStrings("invalid_character", scanner.diagnostics()[scanner.diagnostics().len - 1].code);
}
