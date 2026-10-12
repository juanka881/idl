const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;
const idl_lsp = @import("idl_lsp");
const transport = idl_lsp.transport;

pub const MemoryInput = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_read: usize = math.maxInt(usize),

    pub fn input(self: *MemoryInput) transport.Input {
        const result: transport.Input = .{
            .context = self,
            .read_fn = read,
        };

        return result;
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *MemoryInput = @ptrCast(@alignCast(context));
        const has_remaining_bytes = self.offset < self.bytes.len;
        if (!has_remaining_bytes) {
            return 0;
        }

        const remaining_bytes = self.bytes.len - self.offset;
        const read_count = @min(buffer.len, @min(self.max_read, remaining_bytes));
        @memcpy(buffer[0..read_count], self.bytes[self.offset .. self.offset + read_count]);
        self.offset += read_count;

        return read_count;
    }
};

pub const Capture = struct {
    allocator: Allocator,
    bytes: ArrayList(u8) = .empty,
    write_calls: usize = 0,

    pub fn init(allocator: Allocator) Capture {
        const capture: Capture = .{
            .allocator = allocator,
        };

        return capture;
    }

    pub fn deinit(self: *Capture) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn output(self: *Capture) transport.Output {
        const result: transport.Output = .{
            .context = self,
            .write_fn = write,
        };

        return result;
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.allocator, bytes);
        self.write_calls += 1;
    }
};

pub fn appendFrame(allocator: Allocator, list: *ArrayList(u8), body: []const u8) !void {
    var capture = Capture.init(allocator);
    defer {
        capture.deinit();
    }

    try idl_lsp.framing.writeFrame(allocator, capture.output(), body);
    try list.appendSlice(allocator, capture.bytes.items);
}

pub fn takeFrame(allocator: Allocator, bytes: []const u8) ![]u8 {
    var memory_input: MemoryInput = .{
        .bytes = bytes,
    };
    const body = try idl_lsp.framing.readFrame(allocator, memory_input.input());
    if (body == null) {
        return error.MissingFrame;
    }

    return body.?;
}
