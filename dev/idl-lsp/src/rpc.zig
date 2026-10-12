//! JSON-RPC validation helpers and standard error codes.
//!
//! JSON values borrow strings from the parsed message and must not outlive that
//! message's arena. A response received from a peer is validated and ignored;
//! request handling owns the only outbound requests in this stage.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const testing = std.testing;

pub const parse_error: i64 = -32700;
pub const invalid_request: i64 = -32600;
pub const method_not_found: i64 = -32601;
pub const invalid_params: i64 = -32602;
pub const server_not_initialized: i64 = -32002;

pub fn isValidRequestId(value: json.Value) bool {
    return switch (value) {
        .string, .integer => true,
        .number_string => |number| json.isNumberFormattedLikeAnInteger(number),
        else => false,
    };
}

pub fn hasValidParams(object: json.ObjectMap) bool {
    const maybe_params = object.get("params");
    if (maybe_params == null) {
        return true;
    }

    const params = maybe_params.?;
    const are_params_structured_or_null = params == .object or params == .array or params == .null;
    return are_params_structured_or_null;
}

pub fn isResponseCandidate(object: json.ObjectMap) bool {
    const has_result = object.get("result") != null;
    const has_error = object.get("error") != null;
    const has_response_field = has_result or has_error;

    return has_response_field;
}

pub fn isValidResponse(object: json.ObjectMap) bool {
    const version = object.get("jsonrpc");
    if (version == null) {
        return false;
    }

    const version_value = version.?;
    const has_supported_version = version_value == .string and
        mem.eql(u8, version_value.string, "2.0");
    if (!has_supported_version) {
        return false;
    }

    const has_method = object.get("method") != null;
    if (has_method) {
        return false;
    }

    const maybe_id = object.get("id");
    if (maybe_id == null) {
        return false;
    }
    const id = maybe_id.?;

    const has_result = object.get("result") != null;
    const response_error = object.get("error");
    const has_error = response_error != null;
    if (has_result == has_error) {
        return false;
    }

    if (response_error) |error_value| {
        if (error_value != .object) {
            return false;
        }

        const error_id_is_valid = id == .null or isValidRequestId(id);
        if (!error_id_is_valid) {
            return false;
        }

        const maybe_code = error_value.object.get("code");
        if (maybe_code == null) {
            return false;
        }
        const code = maybe_code.?;
        if (code != .integer) {
            return false;
        }

        const maybe_message = error_value.object.get("message");
        if (maybe_message == null) {
            return false;
        }
        const message = maybe_message.?;
        if (message != .string) {
            return false;
        }
    } else {
        const id_is_valid = isValidRequestId(id);
        if (!id_is_valid) {
            return false;
        }
    }

    return true;
}

test "request IDs accept strings and integers only" {
    const string_id: json.Value = .{
        .string = "id",
    };
    const integer_id: json.Value = .{
        .integer = 7,
    };
    const large_integer_id: json.Value = .{
        .number_string = "123456789012345678901234567890",
    };
    const null_id: json.Value = .null;
    const float_id: json.Value = .{
        .float = 2.5,
    };
    const decimal_id: json.Value = .{
        .number_string = "2.5",
    };
    const exponent_id: json.Value = .{
        .number_string = "2e3",
    };

    try testing.expect(isValidRequestId(string_id));
    try testing.expect(isValidRequestId(integer_id));
    try testing.expect(isValidRequestId(large_integer_id));
    try testing.expect(!isValidRequestId(null_id));
    try testing.expect(!isValidRequestId(float_id));
    try testing.expect(!isValidRequestId(decimal_id));
    try testing.expect(!isValidRequestId(exponent_id));
}
