//! Byte-oriented transport contracts. Framing is defined separately.
//!
//! Callbacks borrow their byte slices only until the callback returns. An input
//! callback fills the caller's buffer and must not retain it. An output callback
//! consumes or copies the complete slice before returning; after `write` returns,
//! the caller may release or mutate the bytes, including when the callback errors.
//! The owner of each callback context keeps it alive for every call.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const Input = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,

    pub fn read(self: Input, buffer: []u8) anyerror!usize {
        return self.read_fn(self.context, buffer);
    }
};

pub const Output = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn write(self: Output, bytes: []const u8) anyerror!void {
        try self.write_fn(self.context, bytes);
    }
};

pub const ReaderContext = struct {
    reader: *Io.Reader,

    pub fn input(self: *ReaderContext) Input {
        const result: Input = .{
            .context = self,
            .read_fn = readFromIoReader,
        };

        return result;
    }

    fn readFromIoReader(context: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *ReaderContext = @ptrCast(@alignCast(context));
        return self.reader.readSliceShort(buffer);
    }
};

pub const WriterContext = struct {
    writer: *Io.Writer,

    pub fn output(self: *WriterContext) Output {
        const result: Output = .{
            .context = self,
            .write_fn = writeToIoWriter,
        };

        return result;
    }

    fn writeToIoWriter(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *WriterContext = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
        try self.writer.flush();
    }
};

test "output forwards bytes to the injected writer" {
    const Capture = struct {
        bytes: [32]u8 = undefined,
        len: usize = 0,

        fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
            const capture: *@This() = @ptrCast(@alignCast(context));

            const fits_capture_buffer = bytes.len <= capture.bytes.len;
            if (!fits_capture_buffer) {
                return error.CaptureBufferTooSmall;
            }

            @memcpy(capture.bytes[0..bytes.len], bytes);
            capture.len = bytes.len;
        }
    };

    var capture: Capture = .{};
    const output: Output = .{
        .context = &capture,
        .write_fn = Capture.write,
    };
    var message_buffer: [13]u8 = "message bytes".*;

    try output.write(message_buffer[0..]);
    message_buffer[0] = 'M';

    try testing.expectEqualSlices(u8, "message bytes", capture.bytes[0..capture.len]);
}
