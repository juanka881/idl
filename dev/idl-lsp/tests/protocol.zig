const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const json = std.json;
const mem = std.mem;
const testing = std.testing;
const idl_lsp = @import("idl_lsp");
const framing = idl_lsp.framing;
const Session = idl_lsp.session.Session;
const support = @import("support.zig");

test "framing reads fragmented and coalesced UTF-8 byte-length frames" {
    const allocator = testing.allocator;
    const first_body = "{\"text\":\"é😀\"}";
    const second_body = "{}";
    var wire_bytes: ArrayList(u8) = .empty;
    defer {
        wire_bytes.deinit(allocator);
    }

    try support.appendFrame(allocator, &wire_bytes, first_body);
    try support.appendFrame(allocator, &wire_bytes, second_body);

    var memory_input: support.MemoryInput = .{
        .bytes = wire_bytes.items,
        .max_read = 3,
    };
    const maybe_first_frame = try framing.readFrame(allocator, memory_input.input());
    if (maybe_first_frame == null) {
        return error.MissingFirstFrame;
    }
    const first_frame = maybe_first_frame.?;
    defer {
        allocator.free(first_frame);
    }
    const maybe_second_frame = try framing.readFrame(allocator, memory_input.input());
    if (maybe_second_frame == null) {
        return error.MissingSecondFrame;
    }
    const second_frame = maybe_second_frame.?;
    defer {
        allocator.free(second_frame);
    }
    const end_frame = try framing.readFrame(allocator, memory_input.input());

    try testing.expectEqualSlices(u8, first_body, first_frame);
    try testing.expectEqualSlices(u8, second_body, second_frame);
    try testing.expect(end_frame == null);
}

test "framing accepts clean EOF and empty bodies" {
    const allocator = testing.allocator;
    var empty_input: support.MemoryInput = .{
        .bytes = "",
    };
    const eof_frame = try framing.readFrame(allocator, empty_input.input());
    try testing.expect(eof_frame == null);

    var wire_bytes: ArrayList(u8) = .empty;
    defer {
        wire_bytes.deinit(allocator);
    }
    try support.appendFrame(allocator, &wire_bytes, "");

    var memory_input: support.MemoryInput = .{
        .bytes = wire_bytes.items,
    };
    const maybe_empty_body = try framing.readFrame(allocator, memory_input.input());
    if (maybe_empty_body == null) {
        return error.MissingFrame;
    }
    const empty_body = maybe_empty_body.?;
    defer {
        allocator.free(empty_body);
    }

    try testing.expectEqual(@as(usize, 0), empty_body.len);
}

test "framing rejects duplicate and malformed content lengths" {
    const invalid_headers = [_][]const u8{
        "Content-Length: 1\r\ncontent-length: 1\r\n\r\nx",
        "Content-Length: +1\r\n\r\nx",
        "Content-Length:\r\n\r\n",
        "Malformed\r\nContent-Length: 1\r\n\r\nx",
        "Content-Length: 1\n\r\n\r\nx",
    };

    for (invalid_headers) |header| {
        var memory_input: support.MemoryInput = .{
            .bytes = header,
            .max_read = 2,
        };
        try testing.expectError(error.InvalidHeader, framing.readFrame(testing.allocator, memory_input.input()));
    }
}

test "framing enforces header and body limits" {
    const allocator = testing.allocator;
    const oversized_header = try allocator.alloc(u8, framing.max_header_bytes + 1);
    defer {
        allocator.free(oversized_header);
    }
    @memset(oversized_header, 'x');

    var header_input: support.MemoryInput = .{
        .bytes = oversized_header,
        .max_read = 17,
    };
    try testing.expectError(error.HeaderTooLarge, framing.readFrame(allocator, header_input.input()));

    var body_input: support.MemoryInput = .{
        .bytes = "Content-Length: 16777217\r\n\r\n",
    };
    try testing.expectError(error.BodyTooLarge, framing.readFrame(allocator, body_input.input()));
}

test "framing rejects truncated headers and bodies" {
    var header_input: support.MemoryInput = .{
        .bytes = "Content-L",
        .max_read = 1,
    };
    try testing.expectError(error.TruncatedFrame, framing.readFrame(testing.allocator, header_input.input()));

    var body_input: support.MemoryInput = .{
        .bytes = "Content-Length: 4\r\n\r\nxy",
        .max_read = 2,
    };
    try testing.expectError(error.TruncatedFrame, framing.readFrame(testing.allocator, body_input.input()));
}

test "writer emits a complete frame in one serialized write" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }

    try framing.writeFrame(allocator, capture.output(), "é");

    try testing.expectEqual(@as(usize, 1), capture.write_calls);
    try testing.expect(mem.startsWith(u8, capture.bytes.items, "Content-Length: 2\r\n\r\n"));
    try testing.expect(mem.endsWith(u8, capture.bytes.items, "é"));
}

test "initialize negotiates UTF-8 and advertises only implemented capabilities" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    try session.handleMessage(
        "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{\"processId\":1,\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\",\"utf-8\"]},\"textDocument\":{\"publishDiagnostics\":{\"relatedInformation\":true}}},\"unknownField\":true}}",
    );

    var response = try takeResponse(allocator, &capture);
    defer {
        response.deinit();
    }
    const root = response.value.object;
    const response_id = try requiredField(root, "id");
    try testing.expectEqualStrings("init", response_id.string);
    const result = (try requiredField(root, "result")).object;
    const capabilities = (try requiredField(result, "capabilities")).object;
    const encoding = try requiredField(capabilities, "positionEncoding");
    try testing.expectEqualStrings("utf-8", encoding.string);
    const text_sync = (try requiredField(capabilities, "textDocumentSync")).object;
    const open_close = try requiredField(text_sync, "openClose");
    const change = try requiredField(text_sync, "change");
    try testing.expect(open_close.bool);
    try testing.expectEqual(@as(i64, 2), change.integer);
    try testing.expect(session.related_information_supported);
    try testing.expectEqual(Session.State.await_initialized, session.state);
}

test "UTF-8 negotiation rejects missing and unsupported offers without retry" {
    const unsupported_initializations = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[]}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\"]}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-32\"]}}}}",
    };

    for (unsupported_initializations) |message| {
        const allocator = testing.allocator;
        var capture = support.Capture.init(allocator);
        defer {
            capture.deinit();
        }
        var session = Session.init(allocator, capture.output());

        try session.handleMessage(message);

        var response = try takeResponse(allocator, &capture);
        defer {
            response.deinit();
        }
        const response_object = response.value.object;
        const error_object = (try requiredField(response_object, "error")).object;
        const code = try requiredField(error_object, "code");
        const data = (try requiredField(error_object, "data")).object;
        const retry = try requiredField(data, "retry");
        try testing.expectEqual(@as(i64, -32002), code.integer);
        try testing.expect(!retry.bool);
        try testing.expectEqual(Session.State.pre_initialize, session.state);

        capture.bytes.clearRetainingCapacity();
        try session.handleMessage(
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}",
        );
        var second_response = try takeResponse(allocator, &capture);
        defer {
            second_response.deinit();
        }
        try expectErrorCode(second_response.value, -32600);
    }
}

test "JSON errors and invalid envelopes receive protocol errors" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    const invalid_messages = [_]struct {
        body: []const u8,
        expected_code: i64,
    }{
        .{
            .body = "{\"jsonrpc\":",
            .expected_code = -32700,
        },
        .{
            .body = "[]",
            .expected_code = -32600,
        },
        .{
            .body = "{\"jsonrpc\":\"1.0\",\"id\":\"x\",\"method\":\"test\"}",
            .expected_code = -32600,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"test\"}",
            .expected_code = -32600,
        },
        .{
            .body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"test\",\"params\":null}",
            .expected_code = -32002,
        },
    };

    for (invalid_messages) |invalid_message| {
        try session.handleMessage(invalid_message.body);
        var response = try takeResponse(allocator, &capture);
        defer {
            response.deinit();
        }
        try expectErrorCode(response.value, invalid_message.expected_code);
        capture.bytes.clearRetainingCapacity();
    }
}

test "unknown methods get errors while notifications and responses stay silent" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":\"unknown\",\"method\":\"made/up\"}");
    var method_response = try takeResponse(allocator, &capture);
    defer {
        method_response.deinit();
    }
    try expectErrorCode(method_response.value, -32002);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"made/up\"}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":\"client\",\"result\":null}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-1,\"message\":\"peer\"}}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"peer parse error\"}}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"result\":null}");
    try session.handleMessage("{\"jsonrpc\":\"1.0\",\"id\":null,\"error\":{}}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":\"bad\",\"message\":1}}");
    try session.handleMessage("{\"jsonrpc\":\"malformed\",\"result\":\"peer\"}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":\"peer\",\"method\":\"invalid-response\",\"result\":null}");
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "lifecycle transitions validate method-specific params first" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":[]}");
    try testing.expectEqual(Session.State.await_initialized, session.state);
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{\"unknown\":true}}");
    try testing.expectEqual(Session.State.running, session.state);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":{}}");
    var object_params_response = try takeResponse(allocator, &capture);
    defer {
        object_params_response.deinit();
    }
    try expectErrorCode(object_params_response.value, -32602);
    try testing.expectEqual(Session.State.running, session.state);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\",\"params\":[]}");
    var array_params_response = try takeResponse(allocator, &capture);
    defer {
        array_params_response.deinit();
    }
    try expectErrorCode(array_params_response.value, -32602);
    try testing.expectEqual(Session.State.running, session.state);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\",\"params\":null}");
    var shutdown_response = try takeResponse(allocator, &capture);
    defer {
        shutdown_response.deinit();
    }
    const result = try requiredField(shutdown_response.value.object, "result");
    try testing.expect(result == .null);
    try testing.expectEqual(Session.State.shutdown, session.state);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":{}}");
    try testing.expectEqual(Session.State.shutdown, session.state);
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    try testing.expectEqual(Session.State.exited, session.state);
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "server lifecycle validates initialize, initialized, shutdown, and exit" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    try testing.expectEqual(Session.State.running, session.state);
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\"}");
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"missing/request\"}");
    var unknown_response = try takeResponse(allocator, &capture);
    defer {
        unknown_response.deinit();
    }
    try expectErrorCode(unknown_response.value, -32601);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}");
    var shutdown_response = try takeResponse(allocator, &capture);
    defer {
        shutdown_response.deinit();
    }
    const result = try requiredField(shutdown_response.value.object, "result");
    try testing.expect(result == .null);
    try testing.expectEqual(Session.State.shutdown, session.state);
    try testing.expectEqual(@as(u8, 0), session.exitStatus());
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"other\"}");
    var after_shutdown_response = try takeResponse(allocator, &capture);
    defer {
        after_shutdown_response.deinit();
    }
    try expectErrorCode(after_shutdown_response.value, -32600);
    try testing.expectEqual(@as(u8, 0), session.exitStatus());
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try testing.expectEqual(Session.State.exited, session.state);
    try testing.expectEqual(@as(u8, 0), session.exitStatus());
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "pre-initialize requests use server-not-initialized and exit fails without shutdown" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":\"early\",\"method\":\"textDocument/hover\"}");
    var response = try takeResponse(allocator, &capture);
    defer {
        response.deinit();
    }
    try expectErrorCode(response.value, -32002);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try testing.expectEqual(@as(u8, 1), session.exitStatus());
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "session continues after malformed JSON and exits with shutdown status" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var wire_bytes: ArrayList(u8) = .empty;
    defer {
        wire_bytes.deinit(allocator);
    }

    try support.appendFrame(allocator, &wire_bytes, "{");
    try support.appendFrame(
        allocator,
        &wire_bytes,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}",
    );
    try support.appendFrame(allocator, &wire_bytes, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    try support.appendFrame(allocator, &wire_bytes, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}");
    try support.appendFrame(allocator, &wire_bytes, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    var memory_input: support.MemoryInput = .{
        .bytes = wire_bytes.items,
        .max_read = 7,
    };
    var session = Session.init(allocator, capture.output());
    const exit_code = try session.run(memory_input.input());

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 3), capture.write_calls);
}

test "document notifications publish clears and recover after transactional failure" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());
    defer {
        session.deinit();
    }

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"languageId\":\"idl\",\"version\":1,\"text\":\"abc\"}}}");
    var opened_diagnostics = try takeResponse(allocator, &capture);
    defer {
        opened_diagnostics.deinit();
    }
    try expectNotification(opened_diagnostics.value, "textDocument/publishDiagnostics");
    try testing.expectEqual(@as(i64, 1), (try requiredField((try requiredField(opened_diagnostics.value.object, "params")).object, "version")).integer);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"languageId\":\"idl\",\"version\":90,\"text\":\"duplicate\"}}}");
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
    const original_document = session.document_store.get("file:///work.idl").?;
    try testing.expectEqualStrings("abc", original_document.text);
    try testing.expectEqual(@as(i32, 1), original_document.committed_version);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"version\":4},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":2}},\"rangeLength\":999,\"text\":\"X\"}]}}");
    var changed_diagnostics = try takeResponse(allocator, &capture);
    defer {
        changed_diagnostics.deinit();
    }
    try expectNotification(changed_diagnostics.value, "textDocument/publishDiagnostics");
    const changed_document = session.document_store.get("file:///work.idl").?;
    try testing.expectEqualStrings("aXc", changed_document.text);
    try testing.expectEqual(@as(i32, 4), changed_document.committed_version);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"version\":7},\"contentChanges\":[{\"range\":{\"start\":{\"line\":8,\"character\":0},\"end\":{\"line\":8,\"character\":1}},\"text\":\"bad\"}]}}");
    var cleared_diagnostics = try takeResponse(allocator, &capture);
    defer {
        cleared_diagnostics.deinit();
    }
    try expectNotification(cleared_diagnostics.value, "textDocument/publishDiagnostics");
    const cleared_params = (try requiredField(cleared_diagnostics.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 7), (try requiredField(cleared_params, "version")).integer);
    const empty_diagnostics = (try requiredField(cleared_params, "diagnostics")).array;
    try testing.expectEqual(@as(usize, 0), empty_diagnostics.items.len);

    var synchronization_error = try takeResponse(allocator, &capture);
    defer {
        synchronization_error.deinit();
    }
    try expectNotification(synchronization_error.value, "window/showMessage");
    const error_params = (try requiredField(synchronization_error.value.object, "params")).object;
    const error_message = try requiredField(error_params, "message");
    try testing.expect(mem.indexOf(u8, error_message.string, "file:///work.idl") != null);
    try testing.expect(mem.indexOf(u8, error_message.string, "Close and reopen") != null);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"version\":6},\"contentChanges\":null}}");
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
    const unsynchronized_document = session.document_store.get("file:///work.idl").?;
    try testing.expectEqualStrings("aXc", unsynchronized_document.text);
    try testing.expectEqual(@as(i32, 7), unsynchronized_document.highest_observed_version);
    try testing.expect(!unsynchronized_document.is_synchronized);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\",\"version\":10},\"contentChanges\":[{\"text\":\"fresh\"}]}}");
    var recovery_diagnostics = try takeResponse(allocator, &capture);
    defer {
        recovery_diagnostics.deinit();
    }
    try expectNotification(recovery_diagnostics.value, "textDocument/publishDiagnostics");
    const recovered_document = session.document_store.get("file:///work.idl").?;
    try testing.expectEqualStrings("fresh", recovered_document.text);
    try testing.expect(recovered_document.is_synchronized);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\"}}}");
    var closed_diagnostics = try takeResponse(allocator, &capture);
    defer {
        closed_diagnostics.deinit();
    }
    try expectNotification(closed_diagnostics.value, "textDocument/publishDiagnostics");
    const closed_params = (try requiredField(closed_diagnostics.value.object, "params")).object;
    try testing.expect(closed_params.get("version") == null);
    const closed_items = (try requiredField(closed_params, "diagnostics")).array;
    try testing.expectEqual(@as(usize, 0), closed_items.items.len);
    try testing.expect(session.document_store.get("file:///work.idl") == null);
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///work.idl\"}}}");
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "malformed known changes mark newer versions unsynchronized" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());
    defer {
        session.deinit();
    }

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///bad.idl\",\"languageId\":\"idl\",\"version\":1,\"text\":\"initial\"}}}");
    var opened_diagnostics = try takeResponse(allocator, &capture);
    defer {
        opened_diagnostics.deinit();
    }
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///bad.idl\",\"version\":2},\"contentChanges\":[{\"text\":17}]}}");
    var diagnostics_clear = try takeResponse(allocator, &capture);
    defer {
        diagnostics_clear.deinit();
    }
    try expectNotification(diagnostics_clear.value, "textDocument/publishDiagnostics");
    var synchronization_error = try takeResponse(allocator, &capture);
    defer {
        synchronization_error.deinit();
    }
    try expectNotification(synchronization_error.value, "window/showMessage");
    capture.bytes.clearRetainingCapacity();

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///bad.idl\",\"version\":\"invalid\"},\"contentChanges\":[{\"text\":\"possibly divergent\"}]}}");
    var invalid_version_clear = try takeResponse(allocator, &capture);
    defer {
        invalid_version_clear.deinit();
    }
    try expectNotification(invalid_version_clear.value, "textDocument/publishDiagnostics");
    const clear_params = (try requiredField(invalid_version_clear.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 2), (try requiredField(clear_params, "version")).integer);
    var invalid_version_error = try takeResponse(allocator, &capture);
    defer {
        invalid_version_error.deinit();
    }
    try expectNotification(invalid_version_error.value, "window/showMessage");

    const document = session.document_store.get("file:///bad.idl").?;
    try testing.expectEqualStrings("initial", document.text);
    try testing.expectEqual(@as(i32, 2), document.highest_observed_version);
    try testing.expect(!document.is_synchronized);
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "published core diagnostics preserve ranges metadata and related locations" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());
    defer {
        session.deinit();
    }

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]},\"textDocument\":{\"publishDiagnostics\":{\"relatedInformation\":true}}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");

    const source = "node title='é😀'\r\nnode key=1 key=2";
    const open_message = try didOpenMessage(allocator, "file:///diagnostic.idl", 3, source);
    defer {
        allocator.free(open_message);
    }
    try session.handleMessage(open_message);

    var published_diagnostics = try takeResponse(allocator, &capture);
    defer {
        published_diagnostics.deinit();
    }
    try expectNotification(published_diagnostics.value, "textDocument/publishDiagnostics");
    const params = (try requiredField(published_diagnostics.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 3), (try requiredField(params, "version")).integer);
    const items = (try requiredField(params, "diagnostics")).array.items;
    try testing.expectEqual(@as(usize, 1), items.len);

    const diagnostic = items[0].object;
    try testing.expectEqual(@as(i64, 1), (try requiredField(diagnostic, "severity")).integer);
    try testing.expectEqualStrings("duplicate_property", (try requiredField(diagnostic, "code")).string);
    try testing.expectEqualStrings("idl", (try requiredField(diagnostic, "source")).string);
    try testing.expectEqualStrings("Property is repeated in this header.", (try requiredField(diagnostic, "message")).string);
    const range = (try requiredField(diagnostic, "range")).object;
    const start = (try requiredField(range, "start")).object;
    const end = (try requiredField(range, "end")).object;
    try testing.expectEqual(@as(i64, 1), (try requiredField(start, "line")).integer);
    try testing.expectEqual(@as(i64, 11), (try requiredField(start, "character")).integer);
    try testing.expectEqual(@as(i64, 1), (try requiredField(end, "line")).integer);
    try testing.expectEqual(@as(i64, 14), (try requiredField(end, "character")).integer);

    const related_values = (try requiredField(diagnostic, "relatedInformation")).array.items;
    try testing.expectEqual(@as(usize, 1), related_values.len);
    const related = related_values[0].object;
    try testing.expectEqualStrings("Related location", (try requiredField(related, "message")).string);
    const location = (try requiredField(related, "location")).object;
    try testing.expectEqualStrings("file:///diagnostic.idl", (try requiredField(location, "uri")).string);
    const related_range = (try requiredField(location, "range")).object;
    const related_start = (try requiredField(related_range, "start")).object;
    try testing.expectEqual(@as(i64, 5), (try requiredField(related_start, "character")).integer);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///diagnostic.idl\",\"version\":4},\"contentChanges\":[]}}");
    var empty_batch_diagnostics = try takeResponse(allocator, &capture);
    defer {
        empty_batch_diagnostics.deinit();
    }
    const empty_batch_params = (try requiredField(empty_batch_diagnostics.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 4), (try requiredField(empty_batch_params, "version")).integer);
    try testing.expectEqual(@as(usize, 1), (try requiredField(empty_batch_params, "diagnostics")).array.items.len);
    try testing.expectEqual(@as(i32, 4), session.document_store.get("file:///diagnostic.idl").?.committed_version);
}

test "fatal parse publishes a clear and ranged edit recovers the document" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());
    defer {
        session.deinit();
    }

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");

    const source = try nestedSource(allocator, 257);
    defer {
        allocator.free(source);
    }
    const open_message = try didOpenMessage(allocator, "file:///nested.idl", 1, source);
    defer {
        allocator.free(open_message);
    }
    try session.handleMessage(open_message);

    var clear = try takeResponse(allocator, &capture);
    defer {
        clear.deinit();
    }
    try expectNotification(clear.value, "textDocument/publishDiagnostics");
    const clear_params = (try requiredField(clear.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 1), (try requiredField(clear_params, "version")).integer);
    try testing.expectEqual(@as(usize, 0), (try requiredField(clear_params, "diagnostics")).array.items.len);

    var parse_error = try takeResponse(allocator, &capture);
    defer {
        parse_error.deinit();
    }
    try expectNotification(parse_error.value, "window/showMessage");
    const parse_error_params = (try requiredField(parse_error.value.object, "params")).object;
    try testing.expectEqual(@as(i64, 1), (try requiredField(parse_error_params, "type")).integer);
    try testing.expect(mem.indexOf(u8, (try requiredField(parse_error_params, "message")).string, "file:///nested.idl") != null);

    const fatal_document = session.document_store.get("file:///nested.idl").?;
    try testing.expect(fatal_document.is_synchronized);
    try testing.expect(fatal_document.tree == null);

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///nested.idl\",\"version\":2},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":6}},\"text\":\"\"}]}}");
    var recovered_diagnostics = try takeResponse(allocator, &capture);
    defer {
        recovered_diagnostics.deinit();
    }
    try expectNotification(recovered_diagnostics.value, "textDocument/publishDiagnostics");
    const recovered_document = session.document_store.get("file:///nested.idl").?;
    try testing.expect(recovered_document.is_synchronized);
    try testing.expect(recovered_document.tree != null);
    try testing.expectEqual(@as(i32, 2), recovered_document.committed_version);
    try testing.expectEqual(@as(usize, 0), capture.bytes.items.len);
}

test "related information is omitted when the client did not opt in" {
    const allocator = testing.allocator;
    var capture = support.Capture.init(allocator);
    defer {
        capture.deinit();
    }
    var session = Session.init(allocator, capture.output());
    defer {
        session.deinit();
    }

    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}}}}");
    var initialize_response = try takeResponse(allocator, &capture);
    defer {
        initialize_response.deinit();
    }
    capture.bytes.clearRetainingCapacity();
    try session.handleMessage("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");

    const open_message = try didOpenMessage(
        allocator,
        "file:///diagnostic.idl",
        1,
        "node key=1 key=2",
    );
    defer {
        allocator.free(open_message);
    }
    try session.handleMessage(open_message);

    var published_diagnostics = try takeResponse(allocator, &capture);
    defer {
        published_diagnostics.deinit();
    }
    const params = (try requiredField(published_diagnostics.value.object, "params")).object;
    const items = (try requiredField(params, "diagnostics")).array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(items[0].object.get("relatedInformation") == null);
}

fn didOpenMessage(allocator: Allocator, uri: []const u8, version: i64, text: []const u8) Allocator.Error![]u8 {
    var text_document: json.ObjectMap = .empty;
    defer {
        text_document.deinit(allocator);
    }
    text_document.put(allocator, "uri", .{
        .string = uri,
    }) catch {
        return error.OutOfMemory;
    };
    text_document.put(allocator, "languageId", .{
        .string = "idl",
    }) catch {
        return error.OutOfMemory;
    };
    text_document.put(allocator, "version", .{
        .integer = version,
    }) catch {
        return error.OutOfMemory;
    };
    text_document.put(allocator, "text", .{
        .string = text,
    }) catch {
        return error.OutOfMemory;
    };

    var params: json.ObjectMap = .empty;
    defer {
        params.deinit(allocator);
    }
    params.put(allocator, "textDocument", .{
        .object = text_document,
    }) catch {
        return error.OutOfMemory;
    };

    var message: json.ObjectMap = .empty;
    defer {
        message.deinit(allocator);
    }
    message.put(allocator, "jsonrpc", .{
        .string = "2.0",
    }) catch {
        return error.OutOfMemory;
    };
    message.put(allocator, "method", .{
        .string = "textDocument/didOpen",
    }) catch {
        return error.OutOfMemory;
    };
    message.put(allocator, "params", .{
        .object = params,
    }) catch {
        return error.OutOfMemory;
    };

    const message_value: json.Value = .{
        .object = message,
    };
    const serialized = json.Stringify.valueAlloc(allocator, message_value, .{}) catch {
        return error.OutOfMemory;
    };

    return serialized;
}

fn nestedSource(allocator: Allocator, level_count: usize) Allocator.Error![]u8 {
    var source: ArrayList(u8) = .empty;
    defer {
        source.deinit(allocator);
    }

    for (0..level_count) |_| {
        source.appendSlice(allocator, "node {\n") catch {
            return error.OutOfMemory;
        };
    }
    for (0..level_count) |_| {
        source.appendSlice(allocator, "}\n") catch {
            return error.OutOfMemory;
        };
    }

    const owned_source = source.toOwnedSlice(allocator) catch {
        return error.OutOfMemory;
    };

    return owned_source;
}

fn takeResponse(allocator: Allocator, capture: *support.Capture) !json.Parsed(json.Value) {
    const body = try support.takeFrame(allocator, capture.bytes.items);
    defer {
        allocator.free(body);
    }

    const separator = mem.indexOf(u8, capture.bytes.items, "\r\n\r\n") orelse {
        return error.MissingFrameSeparator;
    };
    const consumed_length = separator + 4 + body.len;
    if (consumed_length > capture.bytes.items.len) {
        return error.TruncatedCapturedFrame;
    }
    const remaining_length = capture.bytes.items.len - consumed_length;
    mem.copyForwards(
        u8,
        capture.bytes.items[0..remaining_length],
        capture.bytes.items[consumed_length..],
    );
    capture.bytes.items = capture.bytes.items[0..remaining_length];

    return try json.parseFromSlice(json.Value, allocator, body, .{});
}

fn expectErrorCode(response: json.Value, expected_code: i64) !void {
    const response_object = response.object;
    const error_value = try requiredField(response_object, "error");
    const error_object = error_value.object;
    const code = try requiredField(error_object, "code");
    try testing.expectEqual(expected_code, code.integer);
}

fn expectNotification(response: json.Value, expected_method: []const u8) !void {
    const response_object = response.object;
    const method = try requiredField(response_object, "method");
    try testing.expectEqualStrings(expected_method, method.string);
    try testing.expect(response_object.get("id") == null);
}

fn requiredField(object: json.ObjectMap, key: []const u8) error{MissingField}!json.Value {
    const maybe_value = object.get(key);
    if (maybe_value == null) {
        return error.MissingField;
    }

    const value = maybe_value.?;
    return value;
}
