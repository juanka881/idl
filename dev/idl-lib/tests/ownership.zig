const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FailingAllocator = std.testing.FailingAllocator;
const testing = std.testing;
const idl = @import("idl");

test "parse copies caller bytes" {
    var input = [_]u8{ 'a', 'b', 'c' };
    const document = try idl.parse(testing.allocator, &input);
    defer {
        document.destroy();
    }

    @memset(&input, 'x');
    try testing.expectEqualSlices(u8, "abc", document.source().bytes);
}

test "repeated parse and destroy cycles release their storage" {
    for (0..20) |_| {
        const document = try idl.parse(testing.allocator, "node\r\nnext\n");
        try testing.expectEqual(@as(usize, 3), document.source().line_starts.len);
        document.destroy();

        const malformed = try idl.parse(testing.allocator, "node value='\\q'\rnext\n");
        try testing.expect(malformed.hasErrors());
        malformed.destroy();
    }
}

test "allocation failures clean up the owner and arena" {
    const input = "a\r\nb";
    var successful_allocator = FailingAllocator.init(testing.allocator, .{});
    const successful_document = try idl.parse(successful_allocator.allocator(), input);
    const allocation_count = successful_allocator.allocations;
    successful_document.destroy();
    try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

    for (0..allocation_count) |fail_index| {
        var failing = FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = idl.parse(failing.allocator(), input);
        try testing.expectError(error.OutOfMemory, result);

        try testing.expectEqual(failing.allocations, failing.deallocations);
    }
}

test "decoded strings and syntax views survive caller input overwrite" {
    const original = "@meta label='café'\nserver 'api' value=[1,2,3] text='hello\\nworld' { child enabled=true }\n";
    const caller_bytes = try testing.allocator.dupe(u8, original);
    defer {
        testing.allocator.free(caller_bytes);
    }

    const document = try idl.parse(testing.allocator, caller_bytes);
    defer {
        document.destroy();
    }

    @memset(caller_bytes, 'x');

    try testing.expectEqualStrings(original, document.source().bytes);
    const server = document.nodes()[0];
    try testing.expectEqual(@as(usize, 1), server.annotations.len);
    try testing.expectEqualStrings("café", server.annotations[0].properties[0].value.data.string.decoded.?);
    try testing.expectEqual(@as(usize, 1), server.body.?.children.len);
    try testing.expectEqual(@as(usize, 3), server.properties[0].value.data.list.elements.len);
    try testing.expectEqualStrings("hello\nworld", server.properties[1].value.data.string.decoded.?);
    try testing.expect(document.tokens().len > 10);
}

test "allocation failures clean up rich valid and malformed documents" {
    const inputs = [_][]const u8{
        "@meta label='café'\nserver 'api' value=[1,2,3] text='hello\\nworld' { child enabled=true }\n",
        "server { listener port=\nroute value='bad\\q' list=[1,,2] {\n",
    };

    for (inputs) |input| {
        var successful_allocator = FailingAllocator.init(testing.allocator, .{});
        const successful_document = try idl.parse(successful_allocator.allocator(), input);
        const allocation_count = successful_allocator.alloc_index;
        if (input[0] == 's') {
            try testing.expect(successful_document.hasErrors());
        }

        successful_document.destroy();
        try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

        var induced_failures: usize = 0;
        for (0..allocation_count) |fail_index| {
            var failing = FailingAllocator.init(testing.allocator, .{
                .fail_index = fail_index,
            });

            const result = idl.parse(failing.allocator(), input);
            if (result) |unexpected_document| {
                const did_fail_allocation = failing.has_induced_failure;
                unexpected_document.destroy();
                try testing.expect(!did_fail_allocation);
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expect(failing.has_induced_failure);
                induced_failures += 1;
            }

            try testing.expectEqual(failing.allocations, failing.deallocations);
        }

        try testing.expect(induced_failures > 0);
    }
}

test "allocation failures clean up documents that grow parser and diagnostic storage" {
    const valid_source = try repeatedDocumentSource(
        testing.allocator,
        "  @meta label='child'\n  child key='ok' list=[1,2,3] text='hello\\nworld' { leaf enabled=true }\n",
        256,
    );
    defer {
        testing.allocator.free(valid_source);
    }

    const malformed_source = try repeatedDocumentSource(
        testing.allocator,
        "  @meta label='bad\\q'\n  child key='bad\\q' list=[1,,2] { leaf value= }\n",
        256,
    );
    defer {
        testing.allocator.free(malformed_source);
    }

    try exerciseAllocationFailures(valid_source, false);
    try exerciseAllocationFailures(malformed_source, true);
}

fn exerciseAllocationFailures(source: []const u8, expect_errors: bool) !void {
    var successful_allocator = FailingAllocator.init(testing.allocator, .{});
    const successful_document = try idl.parse(successful_allocator.allocator(), source);
    const allocation_count = successful_allocator.alloc_index;
    try testing.expectEqual(expect_errors, successful_document.hasErrors());
    try testing.expect(successful_document.nodes()[0].body != null);
    successful_document.destroy();
    try testing.expectEqual(successful_allocator.allocations, successful_allocator.deallocations);

    var induced_failures: usize = 0;
    for (0..allocation_count) |fail_index| {
        var failing = FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const result = idl.parse(failing.allocator(), source);
        if (result) |document| {
            const did_fail_allocation = failing.has_induced_failure;
            document.destroy();
            try testing.expect(!did_fail_allocation);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            induced_failures += 1;
        }

        try testing.expectEqual(failing.allocations, failing.deallocations);
    }

    try testing.expect(induced_failures > 0);
}

fn repeatedDocumentSource(allocator: Allocator, line: []const u8, count: usize) ![]u8 {
    var source: ArrayList(u8) = .empty;

    errdefer {
        source.deinit(allocator);
    }

    try source.appendSlice(allocator, "server {\n");
    for (0..count) |_| {
        try source.appendSlice(allocator, line);
    }

    try source.appendSlice(allocator, "}\n");

    return source.toOwnedSlice(allocator);
}
