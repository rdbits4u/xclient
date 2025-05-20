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
    xclient.addIncludePath(b.path("../librfxcodec/include/"));
    xclient.linkSystemLibrary("x11");
    xclient.linkSystemLibrary("xext");
    xclient.linkSystemLibrary("pixman-1");
    xclient.addObjectFile(b.path("../librfxcodec/src/.libs/librfxdecode.a"));
    xclient.addObjectFile(b.path("../rdpc/zig-out/lib/librdpc.so"));
    xclient.addLibraryPath(.{.cwd_relative = "../rdpc/zig-out/lib"});
    xclient.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("../common/hexdump.zig"),
    }));
    xclient.root_module.addImport("strings", b.createModule(.{
        .root_source_file = b.path("../common/strings.zig"),
    }));
    xclient.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("../common/log.zig"),
    }));
    setExtraLibraryPaths(xclient, target);
    b.installArtifact(xclient);
}

fn setExtraLibraryPaths(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void
{
    if (target.result.cpu.arch == std.Target.Cpu.Arch.x86)
    {
        // zig seems to use /usr/lib/x86-linux-gnu instead
        // of /usr/lib/i386-linux-gnu
        compile.addLibraryPath(.{.cwd_relative = "/usr/lib/i386-linux-gnu/"});
    }
}
