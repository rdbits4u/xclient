const std = @import("std");

pub fn build(b: *std.Build) void
{
    // build options
    const do_strip = b.option(
        bool,
        "strip",
        "Strip the executabes"
    ) orelse false;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // xclient
    const xclient = b.addExecutable(.{
        .name = "xclient",
        .root_source_file = b.path("src/xclient.zig"),
        .target = target,
        .optimize = optimize,
        .strip = do_strip,
    });
    xclient.linkLibC();
    xclient.addIncludePath(b.path("../common"));
    xclient.addIncludePath(b.path("../rdpc/include"));
    xclient.addIncludePath(b.path("../svc/include"));
    xclient.addIncludePath(b.path("../cliprdr/include"));
    xclient.addIncludePath(b.path("../rdpsnd/include"));
    xclient.addIncludePath(b.path("../librfxcodec/include/"));
    xclient.linkSystemLibrary("x11");
    xclient.linkSystemLibrary("xext");
    xclient.linkSystemLibrary("xcursor");
    xclient.linkSystemLibrary("pixman-1");
    xclient.linkSystemLibrary("libpulse");
    xclient.addObjectFile(b.path("../librfxcodec/src/.libs/librfxdecode.a"));
    xclient.addObjectFile(b.path("../rdpc/zig-out/lib/librdpc.so"));
    xclient.addObjectFile(b.path("../svc/zig-out/lib/libsvc.so"));
    xclient.addObjectFile(b.path("../cliprdr/zig-out/lib/libcliprdr.so"));
    xclient.addObjectFile(b.path("../rdpsnd/zig-out/lib/librdpsnd.so"));
    xclient.addLibraryPath(.{.cwd_relative = "../rdpc/zig-out/lib"});
    xclient.addLibraryPath(.{.cwd_relative = "../svc/zig-out/lib"});
    xclient.addLibraryPath(.{.cwd_relative = "../cliprdr/zig-out/lib"});
    xclient.addLibraryPath(.{.cwd_relative = "../rdpsnd/zig-out/lib"});
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
