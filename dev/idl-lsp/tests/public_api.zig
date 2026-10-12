const idl = @import("idl");
const testing = @import("std").testing;

test "server package can use the public core parser module" {
    const document = try idl.parse(testing.allocator, "server {}");
    defer {
        document.destroy();
    }

    try testing.expectEqual(@as(usize, 1), document.nodes().len);
    try testing.expectEqualStrings("server", document.source().slice(document.nodes()[0].name_span) catch unreachable);
}
