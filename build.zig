const std = @import("std");

pub fn build(b: *std.Build) void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // xclient
    const xclient = b.addExecutable(.{
        .name = "xclient",
        .root_source_file = b.path("src/xclient.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    xclient.linkLibC();
    xclient.addIncludePath(b.path("../common"));
    xclient.addIncludePath(b.path("../rdpc/include"));
    xclient.linkSystemLibrary("rdpc");
    xclient.addLibraryPath(.{.cwd_relative = "../rdpc/zig-out/lib"});
    xclient.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("../common/hexdump.zig"),
    }));
    b.installArtifact(xclient);
}
