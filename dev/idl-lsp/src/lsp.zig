//! Typed LSP document-sync values and JSON decoding helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const math = std.math;
const testing = std.testing;
const unicode = std.unicode;

pub const DecodeError = error{
    InvalidValue,
    InvalidText,
    OutOfMemory,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Change = struct {
    range: ?Range,
    text: []const u8,
};

pub const DidOpen = struct {
    uri: []const u8,
    version: i32,
    text: []const u8,
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i32,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?u32,
    code: ?[]const u8,
    source: ?[]const u8,
    message: []const u8,
    related_information: ?RelatedInformation,
};

pub const RelatedInformation = struct {
    uri: []const u8,
    range: Range,
    message: []const u8,
};

pub fn decodeUri(params: json.Value) DecodeError![]const u8 {
    const params_object = try requireObject(params);
    const text_document_value = try requireField(params_object, "textDocument");
    const text_document = try requireObject(text_document_value);
    const uri_value = try requireField(text_document, "uri");
    if (uri_value != .string) {
        return error.InvalidValue;
    }

    const uri = uri_value.string;
    return uri;
}

pub fn decodeVersion(params: json.Value) DecodeError!i32 {
    const params_object = try requireObject(params);
    const text_document_value = try requireField(params_object, "textDocument");
    const text_document = try requireObject(text_document_value);
    const version_value = try requireField(text_document, "version");
    if (version_value != .integer) {
        return error.InvalidValue;
    }

    const version = version_value.integer;
    const version_is_in_range = version >= math.minInt(i32) and version <= math.maxInt(i32);
    if (!version_is_in_range) {
        return error.InvalidValue;
    }

    const result: i32 = @intCast(version);
    return result;
}

pub fn decodeDidOpen(params: json.Value) DecodeError!DidOpen {
    const params_object = try requireObject(params);
    const text_document_value = try requireField(params_object, "textDocument");
    const text_document = try requireObject(text_document_value);
    const uri_value = try requireField(text_document, "uri");
    const language_id_value = try requireField(text_document, "languageId");
    const version_value = try requireField(text_document, "version");
    const text_value = try requireField(text_document, "text");

    if (uri_value != .string or language_id_value != .string or text_value != .string) {
        return error.InvalidValue;
    }

    const version = try decodeIntegerVersion(version_value);
    const text = text_value.string;
    if (!unicode.utf8ValidateSlice(text)) {
        return error.InvalidText;
    }

    const result: DidOpen = .{
        .uri = uri_value.string,
        .version = version,
        .text = text,
    };

    return result;
}

pub fn decodeChanges(allocator: Allocator, params: json.Value) DecodeError![]Change {
    const params_object = try requireObject(params);
    const changes_value = try requireField(params_object, "contentChanges");
    if (changes_value != .array) {
        return error.InvalidValue;
    }

    const source_changes = changes_value.array.items;
    const changes = allocator.alloc(Change, source_changes.len) catch {
        return error.OutOfMemory;
    };
    errdefer {
        allocator.free(changes);
    }

    for (source_changes, 0..) |source_change, index| {
        changes[index] = try decodeChange(source_change);
    }

    return changes;
}

pub fn decodePosition(value: json.Value) DecodeError!Position {
    const position_object = try requireObject(value);
    const line_value = try requireField(position_object, "line");
    const character_value = try requireField(position_object, "character");
    const line = try decodeNonnegativePositionValue(line_value);
    const character = try decodeNonnegativePositionValue(character_value);

    const position: Position = .{
        .line = line,
        .character = character,
    };

    return position;
}

pub fn decodeRange(value: json.Value) DecodeError!Range {
    const range_object = try requireObject(value);
    const start_value = try requireField(range_object, "start");
    const end_value = try requireField(range_object, "end");
    const start = try decodePosition(start_value);
    const end = try decodePosition(end_value);

    const range: Range = .{
        .start = start,
        .end = end,
    };

    return range;
}

fn decodeChange(value: json.Value) DecodeError!Change {
    const change_object = try requireObject(value);
    const text_value = try requireField(change_object, "text");
    if (text_value != .string) {
        return error.InvalidValue;
    }

    const text = text_value.string;
    if (!unicode.utf8ValidateSlice(text)) {
        return error.InvalidText;
    }

    var maybe_range: ?Range = null;
    if (change_object.get("range")) |range_value| {
        maybe_range = try decodeRange(range_value);
    }

    const change: Change = .{
        .range = maybe_range,
        .text = text,
    };

    return change;
}

fn decodeIntegerVersion(value: json.Value) DecodeError!i32 {
    if (value != .integer) {
        return error.InvalidValue;
    }

    const version = value.integer;
    const version_is_in_range = version >= math.minInt(i32) and version <= math.maxInt(i32);
    if (!version_is_in_range) {
        return error.InvalidValue;
    }

    const result: i32 = @intCast(version);
    return result;
}

fn decodeNonnegativePositionValue(value: json.Value) DecodeError!u32 {
    if (value != .integer) {
        return error.InvalidValue;
    }

    const integer = value.integer;
    const integer_is_in_range = integer >= 0 and integer <= math.maxInt(i32);
    if (!integer_is_in_range) {
        return error.InvalidValue;
    }

    const result: u32 = @intCast(integer);
    return result;
}

fn requireObject(value: json.Value) DecodeError!json.ObjectMap {
    if (value != .object) {
        return error.InvalidValue;
    }

    const object = value.object;
    return object;
}

fn requireField(object: json.ObjectMap, key: []const u8) DecodeError!json.Value {
    const maybe_value = object.get(key);
    if (maybe_value == null) {
        return error.InvalidValue;
    }

    const value = maybe_value.?;
    return value;
}

test "content change decoding uses UTF-8 positions and ignores rangeLength" {
    const allocator = testing.allocator;
    const parsed = try json.parseFromSlice(
        json.Value,
        allocator,
        "{\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"rangeLength\":\"ignored\",\"text\":\"é\"},{\"text\":\"whole\"}]}",
        .{},
    );
    defer {
        parsed.deinit();
    }

    const changes = try decodeChanges(allocator, parsed.value);
    defer {
        allocator.free(changes);
    }

    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expect(changes[0].range != null);
    try testing.expectEqual(@as(u32, 3), changes[0].range.?.end.character);
    try testing.expectEqualStrings("é", changes[0].text);
    try testing.expect(changes[1].range == null);
    try testing.expectEqualStrings("whole", changes[1].text);
}

test "position and version decoding enforce signed i32 protocol bounds" {
    const parsed = try json.parseFromSlice(
        json.Value,
        testing.allocator,
        "{\"line\":0,\"character\":2147483647}",
        .{},
    );
    defer {
        parsed.deinit();
    }
    const position = try decodePosition(parsed.value);
    try testing.expectEqual(@as(u32, 2147483647), position.character);

    const oversized = try json.parseFromSlice(
        json.Value,
        testing.allocator,
        "{\"line\":0,\"character\":2147483648}",
        .{},
    );
    defer {
        oversized.deinit();
    }
    try testing.expectError(error.InvalidValue, decodePosition(oversized.value));

    const negative_version = try json.parseFromSlice(
        json.Value,
        testing.allocator,
        "{\"textDocument\":{\"uri\":\"file:///a.idl\",\"version\":-2147483648}}",
        .{},
    );
    defer {
        negative_version.deinit();
    }
    try testing.expectEqual(@as(i32, -2147483648), try decodeVersion(negative_version.value));

    const oversized_version = try json.parseFromSlice(
        json.Value,
        testing.allocator,
        "{\"textDocument\":{\"uri\":\"file:///a.idl\",\"version\":2147483648}}",
        .{},
    );
    defer {
        oversized_version.deinit();
    }
    try testing.expectError(error.InvalidValue, decodeVersion(oversized_version.value));
}
