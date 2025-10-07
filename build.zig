const std = @import("std");
const builtin = @import("builtin");

//*****************************************************************************
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
    const xclient = myAddExecutable(b, "xclient", target,optimize, do_strip);
    xclient.root_module.root_source_file = b.path("src/xclient.zig");
    xclient.linkLibC();
    xclient.addIncludePath(b.path("../common"));
    xclient.addIncludePath(b.path("../rdpc/include"));
    xclient.addIncludePath(b.path("../svc/include"));
    xclient.addIncludePath(b.path("../drvynvc/include"));
    xclient.addIncludePath(b.path("../cliprdr/include"));
    xclient.addIncludePath(b.path("../rdpsnd/include"));
    xclient.addIncludePath(b.path("../librfxcodec/include/"));
    xclient.addIncludePath(b.path("../librlecodec/include/"));
    xclient.linkSystemLibrary("x11");
    xclient.linkSystemLibrary("xext");
    xclient.linkSystemLibrary("xcursor");
    xclient.linkSystemLibrary("xfixes");
    xclient.linkSystemLibrary("pixman-1");
    xclient.linkSystemLibrary("libpulse");
    xclient.linkSystemLibrary("turbojpeg");
    xclient.addObjectFile(b.path("../librfxcodec/zig-out/lib/librfxdecode.a"));
    xclient.addObjectFile(b.path("../librlecodec/zig-out/lib/librledecode.a"));
    xclient.addObjectFile(b.path("../rdpc/zig-out/lib/librdpc.a"));
    xclient.addObjectFile(b.path("../svc/zig-out/lib/libsvc.a"));
    xclient.addObjectFile(b.path("../drvynvc/zig-out/lib/libdrvynvc.a"));
    xclient.addObjectFile(b.path("../cliprdr/zig-out/lib/libcliprdr.a"));
    xclient.addObjectFile(b.path("../rdpsnd/zig-out/lib/librdpsnd.a"));
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

//*****************************************************************************
fn setExtraLibraryPaths(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void
{
    if (target.result.cpu.arch == std.Target.Cpu.Arch.x86)
    {
        // zig seems to use /usr/lib/x86-linux-gnu instead
        // of /usr/lib/i386-linux-gnu
        compile.addLibraryPath(.{.cwd_relative = "/usr/lib/i386-linux-gnu/"});
    }
}

//*****************************************************************************
fn myAddExecutable(b: *std.Build, name: []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        do_strip: bool) *std.Build.Step.Compile
{
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 15))
    {
        return b.addExecutable(.{
            .name = name,
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
    }
    return b.addExecutable(.{
        .name = name,
        .root_module = b.addModule(name, .{
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        }),
    });
}
