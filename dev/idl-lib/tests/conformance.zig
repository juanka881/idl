const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const DefaultPrng = std.Random.DefaultPrng;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const debug = std.debug;
const idl = @import("idl");

const canonical_fixture = @embedFile("fixtures/canonical.idl");
const recovery_fixture = @embedFile("fixtures/recovery.idl");
const strings_fixture = @embedFile("fixtures/strings.idl");
const kitchen_sink_fixture = @embedFile("fixtures/kitchen-sink.idl");

test "empty source has a valid EOF position and line index" {
    const document = try idl.parse(testing.allocator, "");
    defer {
        document.destroy();
    }

    const source = document.source();
    try testing.expectEqual(@as(usize, 0), source.bytes.len);
    try testing.expectEqualSlices(usize, &.{0}, source.line_starts);
    try testing.expectEqualDeep(idl.Position{
        .line = 0,
        .column = 0,
    }, try source.positionAt(0));
    try testing.expectError(error.OutOfBounds, source.positionAt(1));
    try testing.expectEqual(@as(usize, 0), (try source.slice(.{
        .start = 0,
        .len = 0,
    })).len);
}

test "span slicing rejects out of bounds and overflowing ranges" {
    const source = idl.SourceText{
        .bytes = "abc",
        .line_starts = &.{0},
    };

    try testing.expectEqualSlices(u8, "bc", try source.slice(.{
        .start = 1,
        .len = 2,
    }));
    try testing.expectError(error.OutOfBounds, source.slice(.{
        .start = 4,
        .len = 0,
    }));
    try testing.expectError(error.OutOfBounds, source.slice(.{
        .start = 2,
        .len = 2,
    }));
    try testing.expectError(error.OutOfBounds, source.slice(.{
        .start = 1,
        .len = math.maxInt(usize),
    }));
    try testing.expectError(error.OutOfBounds, (idl.TextSpan{
        .start = math.maxInt(usize),
        .len = 1,
    }).checkedEnd());
}

test "UTF-8 positions count bytes and retain supplementary characters" {
    const document = try idl.parse(testing.allocator, "x 'é😀'\r\nend");
    defer {
        document.destroy();
    }

    const source = document.source();
    try testing.expectEqualSlices(usize, &.{ 0, 12 }, source.line_starts);
    try testing.expectEqualDeep(idl.Position{
        .line = 0,
        .column = 5,
    }, try source.positionAt(5));
    try testing.expectEqualDeep(idl.Position{
        .line = 0,
        .column = 8,
    }, try source.positionAt(8));
    try testing.expectEqualDeep(idl.Position{
        .line = 1,
        .column = 0,
    }, try source.positionAt(12));
    try testing.expectEqualDeep(idl.Position{
        .line = 1,
        .column = 3,
    }, try source.positionAt(15));
}

test "positions on CRLF bytes remain on the preceding line" {
    const document = try idl.parse(testing.allocator, "a\r\nb");
    defer {
        document.destroy();
    }

    const source = document.source();
    try testing.expectEqualDeep(idl.Position{
        .line = 0,
        .column = 1,
    }, try source.positionAt(1));
    try testing.expectEqualDeep(idl.Position{
        .line = 0,
        .column = 2,
    }, try source.positionAt(2));
    try testing.expectEqualDeep(idl.Position{
        .line = 1,
        .column = 0,
    }, try source.positionAt(3));
}

test "public physical line index handles LF CRLF and CR together" {
    const document = try idl.parse(testing.allocator, "a\r\nb\rc\nd\r");
    defer {
        document.destroy();
    }

    try testing.expectEqualSlices(usize, &.{ 0, 3, 5, 7, 9 }, document.source().line_starts);
    try testing.expectEqualDeep(idl.Position{
        .line = 4,
        .column = 0,
    }, try document.source().positionAt(9));
}

test "malformed UTF-8 is preserved and diagnosed per invalid byte" {
    const input = [_]u8{ 'a', 0xf0, 0x80, 0x80, 'b' };
    const document = try idl.parse(testing.allocator, &input);
    defer {
        document.destroy();
    }

    try testing.expectEqualSlices(u8, &input, document.source().bytes);
    try testing.expect(document.hasErrors());
    var invalid_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (!mem.eql(u8, "invalid_utf8", diagnostic.code)) {
            continue;
        }

        try testing.expectEqual(idl.Severity.err, diagnostic.severity);
        try testing.expectEqual(invalid_count + 1, diagnostic.span.start);
        try testing.expectEqual(@as(usize, 1), diagnostic.span.len);
        invalid_count += 1;
    }

    try testing.expectEqual(@as(usize, 3), invalid_count);
}

test "malformed trailing sequence reports every unconsumed byte" {
    const input = [_]u8{ 'x', 0xe2, 0x82 };
    const document = try idl.parse(testing.allocator, &input);
    defer {
        document.destroy();
    }

    try testing.expect(document.hasErrors());
    var invalid_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (!mem.eql(u8, "invalid_utf8", diagnostic.code)) {
            continue;
        }

        try testing.expectEqual(invalid_count + 1, diagnostic.span.start);
        invalid_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), invalid_count);
}

test "canonical headers preserve arguments properties children and bodies" {
    const input = "server 'api' host='0.0.0.0' port=8080 {\n    route '/users' method='GET' {\n        handler users.list\n    }\n}\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expect(!document.hasErrors());
    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    const server = document.nodes()[0];
    try testing.expectEqualStrings("server", try document.source().slice(server.name_span));
    try testing.expectEqual(@as(usize, 1), server.arguments.len);
    try testing.expectEqual(@as(usize, 2), server.properties.len);
    try testing.expect(server.body != null);
    const body = server.body.?;
    try testing.expectEqual(@as(usize, 1), body.children.len);
    const route = body.children[0];
    try testing.expectEqualStrings("route", try document.source().slice(route.name_span));
    try testing.expectEqual(@as(usize, 1), route.arguments.len);
    try testing.expectEqual(@as(usize, 1), route.properties.len);
    try testing.expectEqual(@as(usize, 1), route.body.?.children.len);
}

test "headers diagnose ordering duplicates and missing values while retaining syntax" {
    const input = "database engine=postgres 'main' port=\nnext 10 -2 value=10 -2\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 2), document.nodes().len);
    const database = document.nodes()[0];
    try testing.expectEqual(@as(usize, 1), database.arguments.len);
    try testing.expectEqual(@as(usize, 2), database.properties.len);
    try testing.expectEqual(idl.ExpressionData.missing, meta.activeTag(database.properties[1].value.data));
    try testing.expectEqualStrings("argument_after_property", document.diagnostics()[0].code);
    try testing.expectEqualStrings("expected_value", document.diagnostics()[1].code);

    const next = document.nodes()[1];
    try testing.expectEqual(@as(usize, 3), next.arguments.len);
    const signed = next.arguments[1].data.number;
    try testing.expectEqualStrings("-2", try document.source().slice(signed.number_span));
    try testing.expectEqual(@as(usize, 1), next.properties.len);
    try testing.expectEqualStrings("10", try document.source().slice(next.properties[0].value.data.number.number_span));
}

test "annotations attach across blank lines but not semicolon barriers" {
    const input = "@deprecated 'Use UserV2'\n\nrecord User\n@a\n@b;node\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 2), document.nodes().len);
    try testing.expectEqual(@as(usize, 1), document.nodes()[0].annotations.len);
    try testing.expectEqualStrings(
        "deprecated",
        try document.source().slice(document.nodes()[0].annotations[0].name_span),
    );
    try testing.expectEqual(@as(usize, 0), document.nodes()[1].annotations.len);

    var unattached_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "unattached_annotation", diagnostic.code)) {
            unattached_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), unattached_count);
}

test "newline-terminated annotations orphan at a later semicolon without invalid terminator" {
    const input = "@a\n;node\n@b\n@c\n;other\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 2), document.nodes().len);
    try testing.expectEqual(@as(usize, 0), document.nodes()[0].annotations.len);
    try testing.expectEqual(@as(usize, 0), document.nodes()[1].annotations.len);

    var orphan_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        try testing.expect(!mem.eql(u8, "invalid_annotation_terminator", diagnostic.code));
        if (mem.eql(u8, "unattached_annotation", diagnostic.code)) {
            orphan_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 3), orphan_count);
}

test "duplicate properties retain both entries and link the original span" {
    const document = try idl.parse(testing.allocator, "@meta key=1 key=2\nnode key=3 key=4\n");
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    const node = document.nodes()[0];
    try testing.expectEqual(@as(usize, 1), node.annotations.len);
    try testing.expectEqual(@as(usize, 2), node.annotations[0].properties.len);
    try testing.expectEqual(@as(usize, 2), node.properties.len);

    var duplicate_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (!mem.eql(u8, "duplicate_property", diagnostic.code)) {
            continue;
        }

        const related = diagnostic.related_span orelse {
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("key", try document.source().slice(diagnostic.span));
        try testing.expectEqualStrings("key", try document.source().slice(related));
        try testing.expect(related.start < diagnostic.span.start);
        duplicate_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), duplicate_count);
}

test "next-line bodies attach across comments but stop at semicolons" {
    const input = "attached\n/* comment */\n{ child }\nbarrier;\n{ orphan }\nnext\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 4), document.nodes().len);
    try testing.expectEqual(@as(usize, 1), document.nodes()[0].body.?.children.len);
    try testing.expect(document.nodes()[1].body == null);
    try testing.expect(document.nodes()[2].body == null);
    try testing.expect(document.nodes()[3].body == null);
    try testing.expect(document.hasErrors());
}

test "same-line siblings after bodies are recovered as separate nodes" {
    const document = try idl.parse(testing.allocator, "first{} second{}\n");
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 2), document.nodes().len);
    try testing.expect(document.nodes()[0].body != null);
    try testing.expect(document.nodes()[1].body != null);
    try testing.expectEqualStrings("expected_separator", document.diagnostics()[0].code);
}

test "document body nesting accepts 256 levels and rejects the next level" {
    const depth: usize = 256;
    const accepted = try testing.allocator.alloc(u8, depth * 4 + 4);
    defer {
        testing.allocator.free(accepted);
    }

    var offset: usize = 0;
    for (0..depth) |_| {
        @memcpy(accepted[offset .. offset + 3], "n {");
        offset += 3;
    }

    @memcpy(accepted[offset .. offset + 4], "leaf");
    offset += 4;
    for (0..depth) |_| {
        accepted[offset] = '}';
        offset += 1;
    }

    const document = try idl.parse(testing.allocator, accepted);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, depth + 1), document.nodes().len + countNestedNodes(document.nodes()));
    try testing.expect(!document.hasErrors());

    const rejected = try testing.allocator.alloc(u8, (depth + 1) * 4 + 4);
    defer {
        testing.allocator.free(rejected);
    }

    offset = 0;
    for (0..depth + 1) |_| {
        @memcpy(rejected[offset .. offset + 3], "n {");
        offset += 3;
    }

    @memcpy(rejected[offset .. offset + 4], "leaf");
    offset += 4;
    for (0..depth + 1) |_| {
        rejected[offset] = '}';
        offset += 1;
    }

    try testing.expectError(error.NestingLimitExceeded, idl.parse(testing.allocator, rejected));
}

test "public token and diagnostic spans cover source exactly for malformed inputs" {
    const inputs = [_][]const u8{
        "node value=[1,,2] // trailing\r\nnext key=\n",
        "@meta\nnode key='bad\\q'\n",
        "node /* first\r\nsecond */ value=0x1p2\rnext\n",
        "node \\ // continued\r\n    value=1\n",
        "node value={attempts=3}\n",
    };

    for (inputs) |input| {
        const document = try idl.parse(testing.allocator, input);
        defer {
            document.destroy();
        }

        try expectPublicCoverage(document);
        try testing.expectEqualSlices(u8, input, document.source().bytes);
    }
}

test "checked-in fixtures exercise canonical recovery and marked strings through public parse" {
    const canonical = try idl.parse(testing.allocator, canonical_fixture);
    defer {
        canonical.destroy();
    }

    try testing.expect(!canonical.hasErrors());
    try testing.expectEqual(@as(usize, 1), canonical.nodes().len);
    try testing.expectEqual(@as(usize, 1), canonical.nodes()[0].annotations.len);
    try testing.expectEqual(@as(usize, 1), canonical.nodes()[0].body.?.children[0].body.?.children.len);
    try expectPublicCoverage(canonical);

    const recovery = try idl.parse(testing.allocator, recovery_fixture);
    defer {
        recovery.destroy();
    }

    try testing.expect(recovery.hasErrors());
    try testing.expectEqual(@as(usize, 1), recovery.nodes().len);
    try testing.expectEqual(@as(usize, 2), recovery.nodes()[0].body.?.children.len);
    try expectPublicCoverage(recovery);

    const strings = try idl.parse(testing.allocator, strings_fixture);
    defer {
        strings.destroy();
    }

    try testing.expectEqualStrings("first\nsecond", strings.nodes()[0].arguments[0].data.string.decoded.?);
    try testing.expectEqualStrings("first second\nthird", strings.nodes()[1].arguments[0].data.string.decoded.?);
    try expectPublicCoverage(strings);
}

test "kitchen sink fixture covers valid public syntax without evaluation" {
    const document = try idl.parse(testing.allocator, kitchen_sink_fixture);
    defer {
        document.destroy();
    }

    if (document.hasErrors()) {
        for (document.diagnostics()) |diagnostic| {
            debug.print("{s} at {d}: {s}\n", .{
                diagnostic.code,
                diagnostic.span.start,
                diagnostic.message,
            });
        }
    }

    try testing.expect(!document.hasErrors());
    try testing.expectEqual(@as(usize, 0), document.diagnostics().len);
    try testing.expectEqualSlices(u8, kitchen_sink_fixture, document.source().bytes);
    try expectPublicCoverage(document);

    try expectKitchenSinkNodes(document);
    try expectKitchenSinkHeaderValues(document);
    try expectKitchenSinkCollections(document);
    try expectKitchenSinkStrings(document);
    try expectKitchenSinkOperators(document);
}

fn expectKitchenSinkNodes(document: *const idl.Document) !void {
    const source = document.source();
    const simple_empty = try requiredNode(document, "simple_empty");
    try testing.expect(simple_empty.body == null);
    try testing.expectEqual(@as(usize, 0), simple_empty.arguments.len);
    try testing.expectEqual(@as(usize, 0), simple_empty.properties.len);
    _ = try requiredNode(document, "semicolon_first");
    _ = try requiredNode(document, "semicolon_second");

    const action_login = try requiredNode(document, "action");
    try testing.expectEqual(@as(usize, 1), action_login.arguments.len);
    try testing.expectEqualStrings("login", try source.slice(action_login.arguments[0].data.symbol));
    try testing.expectEqual(@as(usize, 0), action_login.body.?.children.len);

    const hyphenated = try requiredNode(document, "hyphenated-node");
    const hyphenated_value = try requiredProperty(source, hyphenated, "property-name");
    try testing.expectEqualStrings("value-with-symbols", hyphenated_value.value.data.string.decoded.?);

    const header_words = try requiredNode(document, "header_words");
    try testing.expectEqualStrings("dotted.path", try source.slice(header_words.arguments[2].data.symbol));
    try testing.expectEqualStrings("café_name", try source.slice(header_words.arguments[3].data.symbol));
    try testing.expectEqualStrings("namespace::entry", try source.slice(header_words.arguments[4].data.symbol));
    try testing.expectEqualStrings("nan", try source.slice(header_words.arguments[5].data.symbol));
    try testing.expectEqualStrings("and", try source.slice(header_words.arguments[7].data.symbol));

    const annotated = try requiredNode(document, "annotated");
    try testing.expectEqual(@as(usize, 3), annotated.annotations.len);
    try testing.expectEqual(@as(usize, 1), annotated.annotations[0].arguments.len);
    try testing.expectEqual(@as(usize, 1), annotated.annotations[0].properties.len);
    try testing.expectEqual(@as(usize, 1), annotated.body.?.children.len);

    const next_line_body = try requiredNode(document, "next_line_body");
    try testing.expectEqual(@as(usize, 4), next_line_body.body.?.children.len);
    try testing.expectEqual(@as(usize, 2), countChildrenNamed(next_line_body.body.?.children, source, "repeated_child"));
    const nested_body = try requiredChild(next_line_body.body.?.children, source, "nested_body");
    try testing.expectEqual(@as(usize, 1), nested_body.body.?.children.len);
    const empty_body = try requiredNode(document, "empty_body");
    try testing.expect(empty_body.body != null);
    try testing.expect((try requiredNode(document, "absent_body")).body == null);
}

fn expectKitchenSinkHeaderValues(document: *const idl.Document) !void {
    const source = document.source();
    const keyword_properties = try requiredNode(document, "keyword_properties");
    try testing.expectEqual(@as(usize, 3), keyword_properties.properties.len);
    try testing.expect(!keyword_properties.properties[0].value.data.boolean);
    try testing.expect(meta.activeTag(keyword_properties.properties[1].value.data) == .null_value);
    try testing.expect(keyword_properties.properties[2].value.data.boolean);

    const numeric_header = try requiredNode(document, "numeric_header");
    try testing.expectEqual(@as(usize, 13), numeric_header.arguments.len);
    const signed_decimal = numeric_header.arguments[0].data.number;
    try testing.expectEqual(idl.Radix.decimal, signed_decimal.radix);
    try testing.expectEqualStrings("-42", try source.slice(signed_decimal.number_span));
    const signed_hex = numeric_header.arguments[1].data.number;
    try testing.expectEqual(idl.Radix.hexadecimal, signed_hex.radix);
    try testing.expectEqualStrings("-0xFF", try source.slice(signed_hex.number_span));
    const fraction = numeric_header.arguments[2].data.number;
    try testing.expectEqualStrings("3.125", try source.slice(fraction.number_span));
    const decimal_unit = numeric_header.arguments[3].data.number_with_unit;
    try testing.expectEqualStrings("ms", try source.slice(decimal_unit.unit_span));
    const exponent_unit = numeric_header.arguments[5].data.number_with_unit;
    try testing.expectEqualStrings("e", try source.slice(exponent_unit.unit_span));
    const letter_unit = numeric_header.arguments[6].data.number_with_unit;
    try testing.expectEqualStrings("em", try source.slice(letter_unit.unit_span));
    const large_number = numeric_header.arguments[11].data.number;
    try testing.expectEqualStrings("1e1000", try source.slice(large_number.number_span));

    const header_values = try requiredNode(document, "header_values");
    const header_not = header_values.arguments[0].data.unary;
    try testing.expectEqual(idl.UnaryOperator.logical_not, header_not.operator);
    const header_repeated_not = header_values.arguments[1].data.unary;
    try testing.expectEqual(idl.UnaryOperator.logical_not, header_repeated_not.operator);
    try testing.expect(meta.activeTag(header_repeated_not.operand.data) == .unary);
    const signed_unit = header_values.arguments[2].data.number_with_unit;
    try testing.expectEqualStrings("-30", try source.slice(signed_unit.number_span));
    try testing.expectEqualStrings("ms", try source.slice(signed_unit.unit_span));
}

fn expectKitchenSinkCollections(document: *const idl.Document) !void {
    const source = document.source();
    const collections = try requiredNode(document, "collections");
    const empty_list_property = try requiredProperty(source, collections, "empty_list");
    const empty_list = empty_list_property.value.data.list;
    try testing.expectEqual(@as(usize, 0), empty_list.elements.len);
    const values_property = try requiredProperty(source, collections, "values");
    const values = values_property.value.data.list;
    try testing.expectEqual(@as(usize, 5), values.elements.len);
    try testing.expect(meta.activeTag(values.elements[1].data) == .string);
    try testing.expect(meta.activeTag(values.elements[4].data) == .list);

    const calls = try requiredNode(document, "calls");
    const empty_call_property = try requiredProperty(source, calls, "empty");
    try testing.expect(meta.activeTag(empty_call_property.value.data) == .call);
    const dotted_call_property = try requiredProperty(source, calls, "dotted");
    const dotted_call = dotted_call_property.value.data.call;
    try testing.expectEqualStrings("math.clamp", try source.slice(dotted_call.name_span));
    const nested_call_property = try requiredProperty(source, calls, "nested");
    const nested_call = nested_call_property.value.data.call;
    try testing.expect(meta.activeTag(nested_call.arguments[0].data) == .call);
    try testing.expect(meta.activeTag(nested_call.arguments[1].data) == .list);
    const multiline_call_property = try requiredProperty(source, calls, "multiline");
    const multiline_call = multiline_call_property.value.data.call;
    try testing.expectEqual(@as(usize, 2), multiline_call.arguments.len);

    const call_and_group = try requiredNode(document, "call_and_group");
    try testing.expectEqual(@as(usize, 3), call_and_group.arguments.len);
    try testing.expect(meta.activeTag(call_and_group.arguments[0].data) == .call);
    try testing.expect(meta.activeTag(call_and_group.arguments[1].data) == .symbol);
    try testing.expect(meta.activeTag(call_and_group.arguments[2].data) == .group);
}

fn expectKitchenSinkStrings(document: *const idl.Document) !void {
    const source = document.source();
    const strings = try requiredNode(document, "strings");
    const empty_property = try requiredProperty(source, strings, "empty");
    const empty_string = empty_property.value.data.string;
    try testing.expectEqualStrings("", empty_string.decoded.?);
    const escaped_property = try requiredProperty(source, strings, "escaped");
    const escaped = escaped_property.value.data.string;
    try testing.expectEqualStrings("slash\\ quote' newline\n carriage\r tab\t back\x08 form\x0c smile😀", escaped.decoded.?);
    const physical_property = try requiredProperty(source, strings, "physical");
    const physical_string = physical_property.value.data.string;
    try testing.expectEqualStrings("first line\nsecond line", physical_string.decoded.?);
    const comment_property = try requiredProperty(source, strings, "markers");
    const comment_delimiters = comment_property.value.data.string;
    try testing.expectEqualStrings("// /* not comments */", comment_delimiters.decoded.?);

    const marked_strings = try requiredNode(document, "marked_strings");
    const inline_dedented_property = try requiredProperty(source, marked_strings, "inline_dedented");
    const inline_dedented = inline_dedented_property.value.data.string;
    try testing.expectEqual(idl.StringStyle.dedented, inline_dedented.style);
    const inline_folded_property = try requiredProperty(source, marked_strings, "inline_folded");
    const inline_folded = inline_folded_property.value.data.string;
    try testing.expectEqual(idl.StringStyle.folded, inline_folded.style);

    const multiline_strings = try requiredNode(document, "multiline_strings");
    const dedented_property = try requiredProperty(source, multiline_strings, "dedented");
    const dedented = dedented_property.value.data.string;
    try testing.expectEqualStrings("first\nsecond\n  more-indented\nlast", dedented.decoded.?);
    const folded_property = try requiredProperty(source, multiline_strings, "folded");
    const folded = folded_property.value.data.string;
    try testing.expectEqualStrings("first second\n\nthird\n  indented code\nlast", folded.decoded.?);
}

fn expectKitchenSinkOperators(document: *const idl.Document) !void {
    const source = document.source();
    const operators = try requiredNode(document, "operators");
    const binary_operators = [_]struct {
        property_name: []const u8,
        expected: idl.BinaryOperator,
    }{
        .{
            .property_name = "multiply",
            .expected = .multiply,
        },
        .{
            .property_name = "divide",
            .expected = .divide,
        },
        .{
            .property_name = "remainder",
            .expected = .remainder,
        },
        .{
            .property_name = "add",
            .expected = .add,
        },
        .{
            .property_name = "subtract",
            .expected = .subtract,
        },
        .{
            .property_name = "less",
            .expected = .less_than,
        },
        .{
            .property_name = "less_equal",
            .expected = .less_than_or_equal,
        },
        .{
            .property_name = "greater",
            .expected = .greater_than,
        },
        .{
            .property_name = "greater_equal",
            .expected = .greater_than_or_equal,
        },
        .{
            .property_name = "equal",
            .expected = .equal,
        },
        .{
            .property_name = "not_equal",
            .expected = .not_equal,
        },
        .{
            .property_name = "logical_and",
            .expected = .logical_and,
        },
        .{
            .property_name = "logical_or",
            .expected = .logical_or,
        },
    };
    for (binary_operators) |operator_case| {
        const property = try requiredProperty(source, operators, operator_case.property_name);
        const grouped = property.value.data.group;
        try testing.expectEqual(operator_case.expected, grouped.expression.data.binary.operator);
    }

    const prefix_property = try requiredProperty(source, operators, "prefix_not");
    const prefix_group = prefix_property.value.data.group;
    const prefix = prefix_group.expression.data.unary;
    try testing.expectEqual(idl.UnaryOperator.logical_not, prefix.operator);
    try testing.expect(meta.activeTag(prefix.operand.data) == .symbol);
    const prefix_plus_property = try requiredProperty(source, operators, "prefix_plus");
    const prefix_plus_group = prefix_plus_property.value.data.group;
    try testing.expectEqual(idl.UnaryOperator.plus, prefix_plus_group.expression.data.unary.operator);
    const prefix_minus_property = try requiredProperty(source, operators, "prefix_minus");
    const prefix_minus_group = prefix_minus_property.value.data.group;
    try testing.expectEqual(idl.UnaryOperator.minus, prefix_minus_group.expression.data.unary.operator);
    const repeated_property = try requiredProperty(source, operators, "repeated_not");
    const repeated_group = repeated_property.value.data.group;
    const repeated_prefix = repeated_group.expression.data.unary;
    try testing.expectEqual(idl.UnaryOperator.logical_not, repeated_prefix.operator);
    try testing.expect(meta.activeTag(repeated_prefix.operand.data) == .unary);
    const precedence_property = try requiredProperty(source, operators, "precedence");
    const precedence_group = precedence_property.value.data.group;
    const precedence = precedence_group.expression.data.binary;
    try testing.expectEqual(idl.BinaryOperator.add, precedence.operator);
    try testing.expectEqual(idl.BinaryOperator.multiply, precedence.right.data.binary.operator);
    const left_property = try requiredProperty(source, operators, "left_associative");
    const left_group = left_property.value.data.group;
    const left_associative = left_group.expression.data.binary;
    try testing.expectEqual(idl.BinaryOperator.subtract, left_associative.left.data.binary.operator);
    const multiline_property = try requiredProperty(source, operators, "multiline_group");
    const multiline_group = multiline_property.value.data.group;
    try testing.expectEqual(idl.BinaryOperator.add, multiline_group.expression.data.binary.operator);

    const string_comparisons = try requiredNode(document, "string_comparisons");
    const compact_property = try requiredProperty(source, string_comparisons, "compact");
    const compact_group = compact_property.value.data.group;
    const compact = compact_group.expression.data.binary;
    const spaced_property = try requiredProperty(source, string_comparisons, "spaced");
    const spaced_group = spaced_property.value.data.group;
    const spaced = spaced_group.expression.data.binary;
    try testing.expectEqual(idl.BinaryOperator.greater_than, compact.operator);
    try testing.expectEqual(idl.BinaryOperator.greater_than, spaced.operator);
    try testing.expectEqual(idl.StringStyle.folded, compact.right.data.string.style);
    try testing.expectEqual(idl.StringStyle.folded, spaced.right.data.string.style);
}

test "node property and annotation spans follow source boundaries" {
    const input = "@tag x=1\nnode arg key=2 {}\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    const node = document.nodes()[0];
    try testing.expectEqualStrings("@tag x=1", try document.source().slice(node.annotations[0].span));
    try testing.expectEqualStrings("key=2", try document.source().slice(node.properties[0].span));
    try testing.expectEqualStrings("@tag x=1\nnode arg key=2 {}", try document.source().slice(node.span));
    try testing.expectEqual(@as(usize, 0), node.annotations[0].span.start);
    try testing.expectEqual(node.span.start, node.annotations[0].span.start);
    try testing.expectEqual(@as(usize, 0), document.diagnostics().len);
    try expectPublicCoverage(document);
}

test "orphan annotations at EOF and body close retain diagnostics without attaching" {
    const document = try idl.parse(testing.allocator, "parent {\n    @close\n}\n@eof\n");
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    try testing.expectEqual(@as(usize, 0), document.nodes()[0].annotations.len);
    try testing.expectEqual(@as(usize, 0), document.nodes()[0].body.?.children.len);
    var unattached_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "unattached_annotation", diagnostic.code)) {
            unattached_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), unattached_count);
    try expectPublicCoverage(document);
}

test "public integration preserves number spelling radix units and signed context" {
    const document = try idl.parse(
        testing.allocator,
        "numbers -0 1e1000 1e-3 1em 1e3ms 1e 30ms 0xFF 0Xff -0xFF 0x10B 0x10ms 123456789012345678901234567890\nexpression (-0xFF)\ninvalid 01 .5 1. 1.2.3 30ms2 0x 0xms 0x1.2 0x1p2\n",
    );
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 3), document.nodes().len);
    const valid = document.nodes()[0].arguments;
    try testing.expectEqual(@as(usize, 13), valid.len);
    try testing.expectEqualStrings("-0", try document.source().slice(valid[0].data.number.number_span));
    try testing.expectEqual(idl.Radix.hexadecimal, valid[7].data.number.radix);
    try testing.expectEqual(idl.Radix.hexadecimal, valid[8].data.number.radix);
    try testing.expectEqualStrings("-0xFF", try document.source().slice(valid[9].data.number.number_span));
    try testing.expectEqualStrings("0x10B", try document.source().slice(valid[10].data.number.number_span));
    try testing.expectEqualStrings("ms", try document.source().slice(valid[11].data.number_with_unit.unit_span));
    try testing.expectEqualStrings("123456789012345678901234567890", try document.source().slice(valid[12].data.number.number_span));
    try testing.expectEqualStrings("1e1000", try document.source().slice(valid[1].data.number.number_span));
    try testing.expectEqualStrings("1e-3", try document.source().slice(valid[2].data.number.number_span));
    try testing.expectEqualStrings("em", try document.source().slice(valid[3].data.number_with_unit.unit_span));
    try testing.expectEqualStrings("1e3", try document.source().slice(valid[4].data.number_with_unit.number_span));

    var invalid_number_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "invalid_number", diagnostic.code)) {
            invalid_number_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 9), invalid_number_count);

    const expression_group = document.nodes()[1].arguments[0].data.group;
    try testing.expectEqual(idl.UnaryOperator.minus, expression_group.expression.data.unary.operator);
    try testing.expectEqual(idl.Radix.hexadecimal, expression_group.expression.data.unary.operand.data.number.radix);
    try testing.expect(document.hasErrors());
    try expectPublicCoverage(document);
}

test "numeric units stay adjacent-only and unsupported spellings are whole candidates" {
    const document = try idl.parse(testing.allocator, "values 30ms 30 ms -30ms 1e3ms 1e 1e-3\ninvalid 30ms2 1$tail 0x1p2\n");
    defer {
        document.destroy();
    }

    const values = document.nodes()[0].arguments;
    try testing.expectEqual(@as(usize, 7), values.len);
    try testing.expectEqualStrings("ms", try document.source().slice(values[0].data.number_with_unit.unit_span));
    try testing.expectEqualStrings("30", try document.source().slice(values[1].data.number.number_span));
    try testing.expectEqualStrings("ms", try document.source().slice(values[2].data.symbol));
    try testing.expectEqualStrings("-30", try document.source().slice(values[3].data.number_with_unit.number_span));
    try testing.expectEqualStrings("ms", try document.source().slice(values[3].data.number_with_unit.unit_span));
    try testing.expectEqualStrings("1e3", try document.source().slice(values[4].data.number_with_unit.number_span));
    try testing.expectEqualStrings("ms", try document.source().slice(values[4].data.number_with_unit.unit_span));
    try testing.expectEqualStrings("1e-3", try document.source().slice(values[6].data.number.number_span));
    try testing.expectEqualStrings("e", try document.source().slice(values[5].data.number_with_unit.unit_span));
    var invalid_number_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "invalid_number", diagnostic.code)) {
            invalid_number_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 3), invalid_number_count);
    try expectPublicCoverage(document);
}

test "public integration decodes ordinary dedented and folded strings" {
    const input = "strings 'line1\r\n  line2' |'\n    red\n      blue\n    green\n  ' >'\n    one\n    two\n\n    three\n      four\n  '\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    const values = document.nodes()[0].arguments;
    try testing.expectEqualStrings("line1\r\n  line2", values[0].data.string.decoded.?);
    try testing.expectEqual(idl.StringStyle.dedented, values[1].data.string.style);
    try testing.expectEqualStrings("red\n  blue\ngreen", values[1].data.string.decoded.?);
    try testing.expectEqual(idl.StringStyle.folded, values[2].data.string.style);
    try testing.expectEqualStrings("one two\nthree\n  four", values[2].data.string.decoded.?);
    try testing.expect(!document.hasErrors());
    try expectPublicCoverage(document);
}

test "public string diagnostics retain raw spans for escapes controls and invalid UTF-8" {
    const input = [_]u8{
        'n', ' ',  'a',  '=',  '\'', 'x',  '\\', 'q', '\'', ' ',
        'b', '=',  '\'', 'x',  1,    '\'', ' ',  'c', '=',  '\'',
        'x', 0xff, '\'', '\n',
    };
    const document = try idl.parse(testing.allocator, &input);
    defer {
        document.destroy();
    }

    var escape_count: usize = 0;
    var control_count: usize = 0;
    var utf8_count: usize = 0;
    for (document.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "invalid_escape", diagnostic.code)) {
            try testing.expectEqual(@as(usize, 6), diagnostic.span.start);
            escape_count += 1;
        } else if (mem.eql(u8, "invalid_control", diagnostic.code)) {
            try testing.expectEqual(@as(usize, 14), diagnostic.span.start);
            control_count += 1;
        } else if (mem.eql(u8, "invalid_utf8", diagnostic.code)) {
            try testing.expectEqual(@as(usize, 21), diagnostic.span.start);
            utf8_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), escape_count);
    try testing.expectEqual(@as(usize, 1), control_count);
    try testing.expectEqual(@as(usize, 1), utf8_count);
    try testing.expect(document.nodes()[0].properties[0].value.data.string.decoded == null);
    try expectPublicCoverage(document);
}

test "public names support Unicode and hyphens while invalid spacing and BOM diagnose" {
    const valid = try idl.parse(testing.allocator, "módulo-name café\n_ключ key-name=true\n");
    defer {
        valid.destroy();
    }

    try testing.expectEqual(@as(usize, 2), valid.nodes().len);
    try testing.expectEqualStrings("módulo-name", try valid.source().slice(valid.nodes()[0].name_span));
    try testing.expectEqualStrings("café", try valid.source().slice(valid.nodes()[0].arguments[0].data.symbol));
    try testing.expectEqualStrings("key-name", try valid.source().slice(valid.nodes()[1].properties[0].name_span));
    try testing.expect(!valid.hasErrors());
    try expectPublicCoverage(valid);

    const invalid_bytes = [_]u8{ 0xef, 0xbb, 0xbf, 'n', 'o', 'd', 'e', ' ', 0xc2, 0xa0, 'v', 'a', 'l', '\n' };
    const invalid = try idl.parse(testing.allocator, &invalid_bytes);
    defer {
        invalid.destroy();
    }

    try testing.expect(invalid.hasErrors());
    try testing.expect(countCode(invalid.diagnostics(), "invalid_character") >= 2);
    try expectPublicCoverage(invalid);
}

test "public continuation requires a physical newline outside multiline comments" {
    const valid = try idl.parse(testing.allocator, "node \\ /* block\ncomment */ // line\r\n    value=1\n");
    defer {
        valid.destroy();
    }

    try testing.expect(!valid.hasErrors());
    try testing.expectEqual(@as(usize, 1), valid.nodes()[0].properties.len);
    try expectPublicCoverage(valid);

    const invalid = try idl.parse(testing.allocator, "node \\ /* block\ncomment */ value=1\n");
    defer {
        invalid.destroy();
    }

    try testing.expect(invalid.hasErrors());
    var continuation_count: usize = 0;
    for (invalid.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "invalid_continuation", diagnostic.code)) {
            continuation_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), continuation_count);
    try expectPublicCoverage(invalid);

    const eof = try idl.parse(testing.allocator, "node \\");
    defer {
        eof.destroy();
    }

    try testing.expect(eof.hasErrors());
    try expectPublicCoverage(eof);
}

test "public comments are non-nesting and diagnose unterminated blocks" {
    const non_nesting = try idl.parse(testing.allocator, "node /* outer /* inner */ value=1\n");
    defer {
        non_nesting.destroy();
    }

    try testing.expect(!non_nesting.hasErrors());
    try testing.expectEqual(@as(usize, 1), non_nesting.nodes()[0].properties.len);
    try expectPublicCoverage(non_nesting);

    const trailing_line = try idl.parse(testing.allocator, "node // final comment");
    defer {
        trailing_line.destroy();
    }

    const eof = trailing_line.tokens()[trailing_line.tokens().len - 1];
    try testing.expectEqual(idl.TokenKind.end_of_file, eof.kind);
    try testing.expectEqual(idl.TriviaKind.line_comment, eof.leading_trivia[eof.leading_trivia.len - 1].kind);
    try expectPublicCoverage(trailing_line);

    const unterminated = try idl.parse(testing.allocator, "node /* never closed");
    defer {
        unterminated.destroy();
    }

    var comment_error_count: usize = 0;
    for (unterminated.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "unterminated_comment", diagnostic.code)) {
            comment_error_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), comment_error_count);
    try expectPublicCoverage(unterminated);
}

test "public header contexts preserve names keywords continuations and operator boundaries" {
    const input = "node-name value 10 -2 expr (10 - 2) flag !enabled call foo(1) spaced foo (1) cmp (left>'right') marked (left > >'fold') true=false _x=10\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    const node = document.nodes()[0];
    try testing.expectEqual(@as(usize, 2), node.properties.len);
    try testing.expectEqual(@as(usize, 16), node.arguments.len);
    try testing.expectEqualStrings("node-name", try document.source().slice(node.name_span));
    try testing.expectEqualStrings("true", try document.source().slice(node.properties[0].name_span));
    try testing.expectEqual(idl.BinaryOperator.subtract, node.arguments[4].data.group.expression.data.binary.operator);
    try testing.expectEqual(idl.UnaryOperator.logical_not, node.arguments[6].data.unary.operator);
    try testing.expectEqual(idl.StringStyle.ordinary, node.arguments[13].data.group.expression.data.binary.right.data.string.style);
    try testing.expectEqual(idl.StringStyle.folded, node.arguments[15].data.group.expression.data.binary.right.data.string.style);
    try testing.expect(!document.hasErrors());
    try expectPublicCoverage(document);
}

test "compact greater-than and folded-string marker match spaced syntax" {
    const compact_source = "node compact (left>>'right')\n";
    const spaced_source = "node spaced (left > >'right')\n";
    const compact = try idl.parse(testing.allocator, compact_source);
    defer {
        compact.destroy();
    }

    const spaced = try idl.parse(testing.allocator, spaced_source);
    defer {
        spaced.destroy();
    }

    const compact_binary = compact.nodes()[0].arguments[1].data.group.expression.data.binary;
    const spaced_binary = spaced.nodes()[0].arguments[1].data.group.expression.data.binary;
    try testing.expectEqual(idl.BinaryOperator.greater_than, compact_binary.operator);
    try testing.expectEqual(compact_binary.operator, spaced_binary.operator);
    try testing.expectEqual(idl.StringStyle.folded, compact_binary.right.data.string.style);
    try testing.expectEqual(compact_binary.right.data.string.style, spaced_binary.right.data.string.style);
    try testing.expect(!compact.hasErrors());
    try testing.expect(!spaced.hasErrors());
    try expectPublicCoverage(compact);
    try expectPublicCoverage(spaced);

    const invalid = try idl.parse(testing.allocator, "node value=(left>>='right')\n");
    defer {
        invalid.destroy();
    }

    try testing.expect(invalid.hasErrors());
    var invalid_operator_count: usize = 0;
    for (invalid.diagnostics()) |diagnostic| {
        if (mem.eql(u8, "invalid_operator", diagnostic.code)) {
            invalid_operator_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), invalid_operator_count);
    try expectPublicCoverage(invalid);
}

test "named call argument recovery preserves the element and following siblings" {
    const list_document = try idl.parse(testing.allocator, "node value=[a=,]\n");
    defer {
        list_document.destroy();
    }

    const list = list_document.nodes()[0].properties[0].value.data.list;
    try testing.expectEqual(@as(usize, 1), list.elements.len);
    try testing.expectEqual(idl.ExpressionData.symbol, meta.activeTag(list.elements[0].data));
    try testing.expectEqual(@as(usize, 1), countCode(list_document.diagnostics(), "invalid_expression"));
    try expectPublicCoverage(list_document);

    const call_document = try idl.parse(testing.allocator, "node value=f(a=,)\n");
    defer {
        call_document.destroy();
    }

    const call = call_document.nodes()[0].properties[0].value.data.call;
    try testing.expectEqual(@as(usize, 1), call.arguments.len);
    try testing.expectEqual(idl.ExpressionData.symbol, meta.activeTag(call.arguments[0].data));
    try testing.expectEqual(@as(usize, 1), countCode(call_document.diagnostics(), "invalid_expression"));
    try expectPublicCoverage(call_document);

    const nested_document = try idl.parse(testing.allocator, "node value=[f(a=,), 2]\n");
    defer {
        nested_document.destroy();
    }

    const nested = nested_document.nodes()[0].properties[0].value.data.list;
    try testing.expectEqual(@as(usize, 2), nested.elements.len);
    try testing.expectEqual(idl.ExpressionData.call, meta.activeTag(nested.elements[0].data));
    try testing.expectEqualStrings("2", try nested_document.source().slice(nested.elements[1].span));
    try expectPublicCoverage(nested_document);

    const repeated_comma = try idl.parse(testing.allocator, "node value=[a=,,2]\n");
    defer {
        repeated_comma.destroy();
    }

    const recovered_list = repeated_comma.nodes()[0].properties[0].value.data.list;
    try testing.expectEqual(@as(usize, 3), recovered_list.elements.len);
    try testing.expectEqual(idl.ExpressionData.missing, meta.activeTag(recovered_list.elements[1].data));
    try testing.expectEqualStrings("2", try repeated_comma.source().slice(recovered_list.elements[2].span));
    try testing.expectEqual(@as(usize, 1), countCode(repeated_comma.diagnostics(), "invalid_expression"));
    try testing.expectEqual(@as(usize, 1), countCode(repeated_comma.diagnostics(), "expected_value"));
    try expectPublicCoverage(repeated_comma);
}

test "deterministic malformed byte streams make progress and keep all spans bounded" {
    var random = DefaultPrng.init(0x41d1_00d5);
    const random_source = random.random();
    var bytes: [48]u8 = undefined;

    for (0..256) |_| {
        const length = random_source.uintLessThan(usize, bytes.len + 1);
        for (bytes[0..length]) |*byte| {
            byte.* = random_source.int(u8);
        }

        const document = try idl.parse(testing.allocator, bytes[0..length]);
        defer {
            document.destroy();
        }

        try expectPublicCoverage(document);
        try testing.expect(document.diagnostics().len <= length * 3 + 8);
    }
}

test "public parse accepts long flat lists and operator chains below nesting limit" {
    const element_count: usize = 400;
    const expression_count: usize = 400;
    const source_length = 13 + element_count * 2 + expression_count * 2;
    const source = try testing.allocator.alloc(u8, source_length);
    defer {
        testing.allocator.free(source);
    }

    var offset: usize = 0;
    @memcpy(source[offset .. offset + 6], "values");
    offset += 6;
    source[offset] = ' ';
    offset += 1;
    source[offset] = '[';
    offset += 1;
    for (0..element_count) |index| {
        source[offset] = '1';
        offset += 1;
        if (index + 1 < element_count) {
            source[offset] = ',';
            offset += 1;
        }
    }

    source[offset] = ']';
    offset += 1;
    source[offset] = ' ';
    offset += 1;
    source[offset] = '(';
    offset += 1;
    for (0..expression_count) |_| {
        source[offset] = 'x';
        offset += 1;
        source[offset] = '+';
        offset += 1;
    }

    source[offset] = 'x';
    offset += 1;
    source[offset] = ')';
    offset += 1;
    source[offset] = '\n';
    offset += 1;
    try testing.expectEqual(source_length, offset);

    const document = try idl.parse(testing.allocator, source);
    defer {
        document.destroy();
    }

    try testing.expect(!document.hasErrors());
    try testing.expectEqual(element_count, document.nodes()[0].arguments[0].data.list.elements.len);
    try testing.expectEqual(@as(usize, 0), document.diagnostics().len);
    try expectPublicCoverage(document);
}

test "body and expression nesting share the public 256-level limit" {
    const body_depth: usize = 128;
    const expression_depth: usize = 128;
    const accepted = try mixedNestingSource(testing.allocator, body_depth, expression_depth);
    defer {
        testing.allocator.free(accepted);
    }

    const document = try idl.parse(testing.allocator, accepted);
    defer {
        document.destroy();
    }

    try testing.expect(!document.hasErrors());
    try expectPublicCoverage(document);

    const rejected = try mixedNestingSource(testing.allocator, body_depth, expression_depth + 1);
    defer {
        testing.allocator.free(rejected);
    }

    try testing.expectError(error.NestingLimitExceeded, idl.parse(testing.allocator, rejected));
}

fn mixedNestingSource(allocator: Allocator, body_depth: usize, expression_depth: usize) ![]u8 {
    var source: ArrayList(u8) = .empty;

    errdefer {
        source.deinit(allocator);
    }

    for (0..body_depth) |_| {
        try source.appendSlice(allocator, "n {");
    }

    try source.appendSlice(allocator, "leaf ");
    for (0..expression_depth) |_| {
        try source.append(allocator, '(');
    }

    try source.append(allocator, 'x');
    for (0..expression_depth) |_| {
        try source.append(allocator, ')');
    }

    for (0..body_depth) |_| {
        try source.append(allocator, '}');
    }

    return source.toOwnedSlice(allocator);
}

fn requiredNode(document: *const idl.Document, expected_name: []const u8) !*const idl.Node {
    for (document.nodes()) |*node| {
        const actual_name = document.source().slice(node.name_span) catch {
            continue;
        };
        if (mem.eql(u8, actual_name, expected_name)) {
            return node;
        }
    }

    return error.TestUnexpectedResult;
}

fn requiredChild(nodes: []const idl.Node, source: idl.SourceText, expected_name: []const u8) !*const idl.Node {
    for (nodes) |*node| {
        const actual_name = source.slice(node.name_span) catch {
            continue;
        };
        if (mem.eql(u8, actual_name, expected_name)) {
            return node;
        }
    }

    return error.TestUnexpectedResult;
}

fn countChildrenNamed(nodes: []const idl.Node, source: idl.SourceText, expected_name: []const u8) usize {
    var count: usize = 0;
    for (nodes) |node| {
        const actual_name = source.slice(node.name_span) catch {
            continue;
        };
        if (mem.eql(u8, actual_name, expected_name)) {
            count += 1;
        }
    }

    return count;
}

fn requiredProperty(source: idl.SourceText, node: *const idl.Node, expected_name: []const u8) !*const idl.Property {
    for (node.properties) |*property| {
        const actual_name = source.slice(property.name_span) catch {
            continue;
        };
        if (mem.eql(u8, actual_name, expected_name)) {
            return property;
        }
    }

    return error.TestUnexpectedResult;
}

fn expectPublicCoverage(document: *const idl.Document) !void {
    const source = document.source();
    var covered_until: usize = 0;
    var saw_eof = false;

    for (document.tokens()) |token| {
        for (token.leading_trivia) |trivia| {
            try testing.expectEqual(covered_until, trivia.span.start);
            const covered_position_is_in_bounds = covered_until <= source.bytes.len;
            try testing.expect(covered_position_is_in_bounds);
            const remaining_source_len = source.bytes.len - covered_until;
            const trivia_span_is_in_bounds = trivia.span.len <= remaining_source_len;
            try testing.expect(trivia_span_is_in_bounds);
            covered_until = trivia.span.end();
        }

        if (token.kind == .end_of_file) {
            try testing.expect(!saw_eof);
            try testing.expectEqual(source.bytes.len, token.span.start);
            try testing.expectEqual(@as(usize, 0), token.span.len);
            saw_eof = true;
            continue;
        }

        try testing.expectEqual(covered_until, token.span.start);
        const covered_position_is_in_bounds = covered_until <= source.bytes.len;
        try testing.expect(covered_position_is_in_bounds);
        const remaining_source_len = source.bytes.len - covered_until;
        const token_span_is_in_bounds = token.span.len <= remaining_source_len;
        try testing.expect(token_span_is_in_bounds);
        covered_until = token.span.end();
    }

    try testing.expect(saw_eof);
    try testing.expectEqual(source.bytes.len, covered_until);
    for (document.diagnostics()) |diagnostic| {
        try expectSpanInBounds(source, diagnostic.span);
        if (diagnostic.related_span) |related_span| {
            try expectSpanInBounds(source, related_span);
        }
    }

    try expectTreeSpansInBounds(document);
}

fn expectTreeSpansInBounds(document: *const idl.Document) !void {
    var nodes: ArrayList(*const idl.Node) = .empty;
    defer {
        nodes.deinit(testing.allocator);
    }

    var expressions: ArrayList(*const idl.Expression) = .empty;
    defer {
        expressions.deinit(testing.allocator);
    }

    for (document.nodes()) |*node| {
        try nodes.append(testing.allocator, node);
    }

    while (nodes.items.len > 0) {
        const node = nodes.pop().?;
        try expectSpanInBounds(document.source(), node.name_span);
        try expectSpanInBounds(document.source(), node.span);

        for (node.annotations) |annotation| {
            try expectSpanInBounds(document.source(), annotation.name_span);
            try expectSpanInBounds(document.source(), annotation.span);
            for (annotation.arguments) |argument| {
                try expressions.append(testing.allocator, argument);
            }

            for (annotation.properties) |property| {
                try checkProperty(document, property, &expressions);
            }
        }

        for (node.arguments) |argument| {
            try expressions.append(testing.allocator, argument);
        }

        for (node.properties) |property| {
            try checkProperty(document, property, &expressions);
        }

        if (node.body) |body| {
            try checkSyntaxToken(document, body.open_token);
            try checkSyntaxToken(document, body.close_token);
            for (body.children) |*child| {
                try nodes.append(testing.allocator, child);
            }
        }
    }

    while (expressions.items.len > 0) {
        const expression = expressions.pop().?;
        try expectSpanInBounds(document.source(), expression.span);

        switch (expression.data) {
            .number => |number| {
                try expectSpanInBounds(document.source(), number.number_span);
            },
            .number_with_unit => |number| {
                try expectSpanInBounds(document.source(), number.number_span);
                try expectSpanInBounds(document.source(), number.unit_span);
            },
            .string => |string| {
                try expectSpanInBounds(document.source(), string.raw_span);
            },
            .symbol => |span| {
                try expectSpanInBounds(document.source(), span);
            },
            .list => |list| {
                try checkSyntaxToken(document, list.open_token);
                try checkSyntaxToken(document, list.close_token);
                for (list.elements) |element| {
                    try expressions.append(testing.allocator, element);
                }
            },
            .call => |call| {
                try expectSpanInBounds(document.source(), call.name_span);
                try checkSyntaxToken(document, call.open_token);
                try checkSyntaxToken(document, call.close_token);
                for (call.arguments) |argument| {
                    try expressions.append(testing.allocator, argument);
                }
            },
            .group => |group| {
                try checkSyntaxToken(document, group.open_token);
                try checkSyntaxToken(document, group.close_token);
                try expressions.append(testing.allocator, group.expression);
            },
            .unary => |unary| {
                try expectSpanInBounds(document.source(), unary.operator_span);
                try expressions.append(testing.allocator, unary.operand);
            },
            .binary => |binary| {
                try expectSpanInBounds(document.source(), binary.operator_span);
                try expressions.append(testing.allocator, binary.left);
                try expressions.append(testing.allocator, binary.right);
            },
            .missing => {
                try testing.expectEqual(@as(usize, 0), expression.span.len);
            },
            .boolean, .null_value, .invalid => {},
        }
    }
}

fn checkProperty(
    document: *const idl.Document,
    property: idl.Property,
    expressions: *ArrayList(*const idl.Expression),
) !void {
    try expectSpanInBounds(document.source(), property.name_span);
    try expectSpanInBounds(document.source(), property.span);
    try checkSyntaxToken(document, property.equals_token);
    try expressions.append(testing.allocator, property.value);
}

fn checkSyntaxToken(document: *const idl.Document, token: idl.Token) !void {
    try expectSpanInBounds(document.source(), token.span);
    if (token.missing) {
        try testing.expectEqual(@as(usize, 0), token.span.len);
    }
}

fn expectSpanInBounds(source: idl.SourceText, span: idl.TextSpan) !void {
    const span_start_is_in_bounds = span.start <= source.bytes.len;
    try testing.expect(span_start_is_in_bounds);

    const remaining_source_len = source.bytes.len - span.start;
    const span_is_in_bounds = span.len <= remaining_source_len;
    try testing.expect(span_is_in_bounds);
}

fn countCode(diagnostics: []const idl.Diagnostic, code: []const u8) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (mem.eql(u8, diagnostic.code, code)) {
            count += 1;
        }
    }

    return count;
}

fn countNestedNodes(nodes: []const idl.Node) usize {
    var count: usize = 0;
    for (nodes) |node| {
        if (node.body) |body| {
            count += body.children.len + countNestedNodes(body.children);
        }
    }

    return count;
}

test "bodies recover sibling nodes and preserve absent versus empty bodies" {
    const document = try idl.parse(testing.allocator, "listener port=\nroute '/users' {\n}\nfirst{} second{}\nempty {}\nabsent\n");
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 6), document.nodes().len);
    try testing.expect(document.nodes()[0].body == null);
    try testing.expectEqual(idl.ExpressionData.missing, meta.activeTag(document.nodes()[0].properties[0].value.data));
    try testing.expectEqual(@as(usize, 0), document.nodes()[1].body.?.children.len);
    try testing.expect(document.nodes()[2].body != null);
    try testing.expect(document.nodes()[3].body != null);
    try testing.expect(document.nodes()[4].body != null);
    try testing.expect(document.nodes()[5].body == null);
    try testing.expect(document.hasErrors());
}

test "unexpected header punctuation always makes progress and retains byte coverage" {
    const inputs = [_][]const u8{ "node ,\n", "node )\n", "node ]\n" };
    for (inputs) |input| {
        const document = try idl.parse(testing.allocator, input);
        defer {
            document.destroy();
        }

        try testing.expectEqual(@as(usize, 1), document.nodes().len);
        try testing.expect(document.hasErrors());
        var offset: usize = 0;
        for (document.tokens()) |token| {
            for (token.leading_trivia) |trivia| {
                try testing.expectEqual(offset, trivia.span.start);
                offset = trivia.span.end();
            }

            if (token.kind == .end_of_file) {
                continue;
            }

            try testing.expectEqual(offset, token.span.start);
            offset = token.span.end();
        }

        try testing.expectEqual(input.len, offset);
    }
}

test "recovery retains sibling nodes and a final EOF token with trailing trivia" {
    const input = "server {\n    listener port=\n    route '/users' {\n";
    const document = try idl.parse(testing.allocator, input);
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    const server = document.nodes()[0];
    try testing.expectEqual(@as(usize, 2), server.body.?.children.len);
    try testing.expect(server.body.?.close_token.missing);
    try testing.expect(server.body.?.children[1].body.?.close_token.missing);
    try testing.expectEqual(idl.TokenKind.end_of_file, document.tokens()[document.tokens().len - 1].kind);
}
