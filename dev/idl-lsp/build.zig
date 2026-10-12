const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const idl_module = b.dependency("idl_lib", .{
        .target = target,
        .optimize = optimize,
    }).module("idl");

    const library_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "idl",
                .module = idl_module,
            },
        },
    });
    const server_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "idl_lsp",
                .module = library_module,
            },
        },
    });
    const server = b.addExecutable(.{
        .name = "idl-lsp",
        .root_module = server_module,
    });
    b.installArtifact(server);

    const module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "idl",
                    .module = idl_module,
                },
            },
        }),
    });
    const public_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/public_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "idl",
                    .module = idl_module,
                },
            },
        }),
    });
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "idl_lsp",
                    .module = library_module,
                },
            },
        }),
    });
    const test_step = b.step("test", "Run the LSP tests");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    test_step.dependOn(&b.addRunArtifact(public_api_tests).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
}
