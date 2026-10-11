const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const math = std.math;
const testing = std.testing;
const unicode = std.unicode;

pub const text = @import("text.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const syntax = @import("syntax.zig");
const literals = @import("literals.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");

pub const TextSpan = text.TextSpan;
pub const Position = text.Position;
pub const SourceText = text.SourceText;
pub const Severity = diagnostics.Severity;
pub const Diagnostic = diagnostics.Diagnostic;
pub const TriviaKind = syntax.TriviaKind;
pub const Trivia = syntax.Trivia;
pub const TokenKind = syntax.TokenKind;
pub const Token = syntax.Token;
pub const Radix = syntax.Radix;
pub const Number = syntax.Number;
pub const NumberWithUnit = syntax.NumberWithUnit;
pub const StringStyle = syntax.StringStyle;
pub const String = syntax.String;
pub const UnaryOperator = syntax.UnaryOperator;
pub const BinaryOperator = syntax.BinaryOperator;
pub const Expression = syntax.Expression;
pub const ExpressionData = syntax.Data;
pub const List = syntax.List;
pub const Call = syntax.Call;
pub const Group = syntax.Group;
pub const Unary = syntax.Unary;
pub const Binary = syntax.Binary;
pub const Property = syntax.Property;
pub const Annotation = syntax.Annotation;
pub const Body = syntax.Body;
pub const Node = syntax.Node;

pub const ParseError = error{
    OutOfMemory,
    SourceTooLarge,
    NestingLimitExceeded,
};

pub const Document = struct {
    backing_allocator: Allocator,
    arena: ArenaAllocator,
    source_text: SourceText,
    root_nodes: []const Node,
    token_list: []const Token,
    diagnostic_list: []const Diagnostic,

    fn init(allocator: Allocator) Document {
        const empty_source: SourceText = .{
            .bytes = &.{},
            .line_starts = &.{},
        };
        const document: Document = .{
            .backing_allocator = allocator,
            .arena = ArenaAllocator.init(allocator),
            .source_text = empty_source,
            .root_nodes = &.{},
            .token_list = &.{},
            .diagnostic_list = &.{},
        };

        return document;
    }

    pub fn destroy(self: *Document) void {
        const allocator = self.backing_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn source(self: *const Document) SourceText {
        return self.source_text;
    }

    pub fn nodes(self: *const Document) []const Node {
        return self.root_nodes;
    }

    pub fn tokens(self: *const Document) []const Token {
        return self.token_list;
    }

    pub fn diagnostics(self: *const Document) []const Diagnostic {
        return self.diagnostic_list;
    }

    pub fn hasErrors(self: *const Document) bool {
        for (self.diagnostic_list) |diagnostic| {
            if (diagnostic.severity == .err) {
                return true;
            }
        }

        return false;
    }
};

pub fn parse(allocator: Allocator, source_bytes: []const u8) ParseError!*Document {
    const can_represent_source_length_plus_one = source_bytes.len < math.maxInt(usize);
    if (!can_represent_source_length_plus_one) {
        return error.SourceTooLarge;
    }

    const document = allocator.create(Document) catch {
        return error.OutOfMemory;
    };
    document.* = Document.init(allocator);

    errdefer {
        document.destroy();
    }

    const arena = document.arena.allocator();
    const copied_source = arena.dupe(u8, source_bytes) catch {
        return error.OutOfMemory;
    };
    const line_count = text.countPhysicalLines(copied_source) catch {
        return error.SourceTooLarge;
    };
    _ = checkedArrayByteSize(usize, line_count) catch {
        return error.SourceTooLarge;
    };
    const line_starts = arena.alloc(usize, line_count) catch {
        return error.OutOfMemory;
    };
    text.fillLineStarts(copied_source, line_starts);

    const invalid_byte_count = countInvalidUtf8Bytes(copied_source) catch {
        return error.SourceTooLarge;
    };
    _ = checkedArrayByteSize(Diagnostic, invalid_byte_count) catch {
        return error.SourceTooLarge;
    };
    const diagnostics_slice = arena.alloc(Diagnostic, invalid_byte_count) catch {
        return error.OutOfMemory;
    };
    fillInvalidUtf8Diagnostics(copied_source, diagnostics_slice);

    document.source_text = .{
        .bytes = copied_source,
        .line_starts = line_starts,
    };

    var document_parser = parser.Parser.initWithOptions(arena, copied_source, .{
        .report_invalid_utf8 = false,
    });
    const parsed = document_parser.parseDocument() catch |err| {
        return err;
    };

    const diagnostic_count = math.add(usize, invalid_byte_count, parsed.diagnostics.len) catch {
        return error.SourceTooLarge;
    };
    _ = checkedArrayByteSize(Diagnostic, diagnostic_count) catch {
        return error.SourceTooLarge;
    };
    const all_diagnostics = arena.alloc(Diagnostic, diagnostic_count) catch {
        return error.OutOfMemory;
    };
    @memcpy(all_diagnostics[0..invalid_byte_count], diagnostics_slice);
    @memcpy(all_diagnostics[invalid_byte_count..], parsed.diagnostics);

    document.root_nodes = parsed.nodes;
    document.token_list = parsed.tokens;
    document.diagnostic_list = all_diagnostics;

    return document;
}

fn checkedArrayByteSize(comptime T: type, count: usize) error{SourceTooLarge}!usize {
    return math.mul(usize, count, @sizeOf(T)) catch error.SourceTooLarge;
}

fn countInvalidUtf8Bytes(bytes: []const u8) error{SourceTooLarge}!usize {
    var invalid_count: usize = 0;
    var index: usize = 0;

    while (index < bytes.len) {
        const sequence_length = validSequenceLength(bytes[index..]) orelse {
            const can_add_invalid_diagnostic = invalid_count < math.maxInt(usize);
            if (!can_add_invalid_diagnostic) {
                return error.SourceTooLarge;
            }

            invalid_count += 1;
            index += 1;
            continue;
        };
        index += sequence_length;
    }

    return invalid_count;
}

fn fillInvalidUtf8Diagnostics(bytes: []const u8, diagnostics_slice: []Diagnostic) void {
    var diagnostic_index: usize = 0;
    var byte_index: usize = 0;

    while (byte_index < bytes.len) {
        const sequence_length = validSequenceLength(bytes[byte_index..]) orelse {
            diagnostics_slice[diagnostic_index] = .{
                .code = diagnostics.invalid_utf8_code,
                .severity = .err,
                .message = diagnostics.invalid_utf8_message,
                .span = .{
                    .start = byte_index,
                    .len = 1,
                },
            };
            diagnostic_index += 1;
            byte_index += 1;
            continue;
        };
        byte_index += sequence_length;
    }
}

fn validSequenceLength(bytes: []const u8) ?usize {
    const sequence_length = unicode.utf8ByteSequenceLength(bytes[0]) catch {
        return null;
    };
    const length: usize = sequence_length;
    const has_complete_utf8_sequence = bytes.len >= length;
    if (!has_complete_utf8_sequence) {
        return null;
    }

    _ = unicode.utf8Decode(bytes[0..length]) catch {
        return null;
    };

    return length;
}

test "document source and diagnostics use document-owned storage" {
    const input = "a";
    const document = try parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqualSlices(u8, input, document.source().bytes);
    try testing.expectEqual(@as(usize, 0), document.diagnostics().len);
    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    try testing.expectEqual(@as(usize, 2), document.tokens().len);
    try testing.expectEqual(TokenKind.name, document.tokens()[0].kind);
    try testing.expectEqual(TokenKind.end_of_file, document.tokens()[1].kind);
}

test {
    _ = @import("scanner.zig");
    _ = @import("literals.zig");
    _ = @import("parser.zig");
}
