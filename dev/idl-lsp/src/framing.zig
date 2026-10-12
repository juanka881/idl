//! Content-Length framing for the synchronous stdio transport.
//!
//! A returned frame body is allocator-owned and remains valid until the caller
//! frees it. Output frames are assembled as one buffer and passed through the
//! borrowing contract defined by `transport.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const transport = @import("transport.zig");

pub const max_header_bytes: usize = 8 * 1024;
pub const max_body_bytes: usize = 16 * 1024 * 1024;

pub const ReadError = error{
    OutOfMemory,
    ReadFailed,
    InvalidHeader,
    HeaderTooLarge,
    BodyTooLarge,
    TruncatedFrame,
};

pub fn readFrame(allocator: Allocator, input: transport.Input) ReadError!?[]u8 {
    var header_bytes: ArrayList(u8) = .empty;
    defer {
        header_bytes.deinit(allocator);
    }

    while (true) {
        var byte: [1]u8 = undefined;
        const read_count = try readSome(input, &byte);
        if (read_count == 0) {
            const has_partial_header = header_bytes.items.len > 0;
            if (has_partial_header) {
                return error.TruncatedFrame;
            }

            return null;
        }

        try header_bytes.append(allocator, byte[0]);
        const is_header_within_limit = header_bytes.items.len <= max_header_bytes;
        if (!is_header_within_limit) {
            return error.HeaderTooLarge;
        }

        if (endsWithHeaderTerminator(header_bytes.items)) {
            break;
        }
    }

    const body_length = try parseContentLength(header_bytes.items);
    const is_body_within_limit = body_length <= max_body_bytes;
    if (!is_body_within_limit) {
        return error.BodyTooLarge;
    }

    const body = allocator.alloc(u8, body_length) catch {
        return error.OutOfMemory;
    };
    errdefer {
        allocator.free(body);
    }

    try readBody(input, body);

    return body;
}

pub fn writeFrame(allocator: Allocator, output: transport.Output, body: []const u8) anyerror!void {
    const is_body_within_limit = body.len <= max_body_bytes;
    if (!is_body_within_limit) {
        return error.BodyTooLarge;
    }

    var header_buffer: [64]u8 = undefined;
    const header = fmt.bufPrint(&header_buffer, "Content-Length: {d}\r\n\r\n", .{body.len}) catch {
        return error.OutOfMemory;
    };

    const frame_length = math.add(usize, header.len, body.len) catch {
        return error.OutOfMemory;
    };
    const frame = allocator.alloc(u8, frame_length) catch {
        return error.OutOfMemory;
    };
    defer {
        allocator.free(frame);
    }

    @memcpy(frame[0..header.len], header);
    @memcpy(frame[header.len..], body);

    try output.write(frame);
}

fn readBody(input: transport.Input, body: []u8) ReadError!void {
    var body_offset: usize = 0;

    while (body_offset < body.len) {
        const remaining_body = body[body_offset..];
        const read_count = try readSome(input, remaining_body);
        const has_more_body = read_count > 0;
        if (!has_more_body) {
            return error.TruncatedFrame;
        }

        body_offset += read_count;
    }
}

fn readSome(input: transport.Input, buffer: []u8) ReadError!usize {
    const read_count = input.read(buffer) catch {
        return error.ReadFailed;
    };
    const read_count_fits_buffer = read_count <= buffer.len;
    if (!read_count_fits_buffer) {
        return error.ReadFailed;
    }

    return read_count;
}

fn endsWithHeaderTerminator(bytes: []const u8) bool {
    if (bytes.len < 4) {
        return false;
    }

    return mem.eql(u8, bytes[bytes.len - 4 ..], "\r\n\r\n");
}

fn parseContentLength(header_bytes: []const u8) ReadError!usize {
    const header_end = header_bytes.len - 4;
    const header_lines = header_bytes[0..header_end];
    var line_iterator = mem.splitSequence(u8, header_lines, "\r\n");
    var content_length: ?usize = null;

    while (line_iterator.next()) |line| {
        const is_line_empty = line.len == 0;
        if (is_line_empty) {
            return error.InvalidHeader;
        }

        const colon_index = mem.indexOfScalar(u8, line, ':') orelse {
            return error.InvalidHeader;
        };
        const name = line[0..colon_index];
        const value = trimOptionalWhitespace(line[colon_index + 1 ..]);
        const has_header_name = name.len > 0;
        if (!has_header_name) {
            return error.InvalidHeader;
        }

        const has_control_character = hasInvalidHeaderCharacter(line);
        if (has_control_character) {
            return error.InvalidHeader;
        }

        if (ascii.eqlIgnoreCase(name, "Content-Length")) {
            const already_has_content_length = content_length != null;
            if (already_has_content_length) {
                return error.InvalidHeader;
            }

            content_length = try parseDecimalLength(value);
        }
    }

    if (content_length == null) {
        return error.InvalidHeader;
    }

    const parsed_length = content_length.?;
    return parsed_length;
}

fn hasInvalidHeaderCharacter(line: []const u8) bool {
    for (line) |byte| {
        const is_forbidden_control = byte == '\r' or byte == '\n' or byte == 0;
        if (is_forbidden_control) {
            return true;
        }
    }

    return false;
}

fn trimOptionalWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;

    while (start < end and isOptionalWhitespace(value[start])) {
        start += 1;
    }

    while (end > start and isOptionalWhitespace(value[end - 1])) {
        end -= 1;
    }

    return value[start..end];
}

fn isOptionalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn parseDecimalLength(value: []const u8) ReadError!usize {
    const has_digits = value.len > 0;
    if (!has_digits) {
        return error.InvalidHeader;
    }

    var length: usize = 0;
    for (value) |byte| {
        const is_decimal_digit = byte >= '0' and byte <= '9';
        if (!is_decimal_digit) {
            return error.InvalidHeader;
        }

        const digit: usize = byte - '0';
        const multiplied = math.mul(usize, length, 10) catch {
            return error.InvalidHeader;
        };
        length = math.add(usize, multiplied, digit) catch {
            return error.InvalidHeader;
        };
    }

    return length;
}
