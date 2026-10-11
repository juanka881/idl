const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const idl_module = b.addModule("idl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "idl",
                .module = idl_module,
            }},
        }),
    });
    const ownership_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ownership.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "idl",
                .module = idl_module,
            }},
        }),
    });

    const test_step = b.step("test", "Run the core test suites");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    test_step.dependOn(&b.addRunArtifact(conformance_tests).step);
    test_step.dependOn(&b.addRunArtifact(ownership_tests).step);
}
