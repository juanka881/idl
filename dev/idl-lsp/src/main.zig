//! Standard input/output composition for the synchronous server.

const std = @import("std");
const File = std.Io.File;
const Init = std.process.Init;
const idl_lsp = @import("idl_lsp");
const Session = idl_lsp.session.Session;
const transport = idl_lsp.transport;

pub fn main(init: Init) anyerror!u8 {
    var input_buffer: [8192]u8 = undefined;
    var file_reader = File.stdin().readerStreaming(init.io, &input_buffer);
    var reader_context: transport.ReaderContext = .{
        .reader = &file_reader.interface,
    };

    var output_buffer: [8192]u8 = undefined;
    var file_writer = File.stdout().writerStreaming(init.io, &output_buffer);
    var writer_context: transport.WriterContext = .{
        .writer = &file_writer.interface,
    };

    var session = Session.init(init.gpa, writer_context.output());
    defer {
        session.deinit();
    }
    const exit_code = try session.run(reader_context.input());

    return exit_code;
}
