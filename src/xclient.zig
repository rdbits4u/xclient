const std = @import("std");
const hexdump = @import("hexdump");
const strings = @import("strings");
const log = @import("log.zig");
const rdpc_session = @import("rdpc_session.zig");
const posix = std.posix;
const c = @cImport(
{
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("librdpc.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

//*****************************************************************************
fn show_command_line_args() !void
{
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    try writer.print("xclient - A sample application for librdpc\n", .{});
    try writer.print("Usage: xclient [options] server[:port]\n", .{});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -u: username\n", .{});
    try writer.print("  -d: domain\n", .{});
    try writer.print("  -s: set startup-shell\n", .{});
    try writer.print("  -c: initial working directory\n", .{});
    try writer.print("  -p: password\n", .{});
    try writer.print("  -n: hostname\n", .{});
}

//*****************************************************************************
fn process_args(settings: *c.rdpc_settings_t,
        rdp_connect: *rdpc_session.rdp_connect_t) !void
{
    // default some stuff
    strings.copyZ(&rdp_connect.server_port, "3389");
    settings.width = 800;
    settings.height = 600;
    settings.dpix = 96;
    settings.dpiy = 96;
    settings.keyboard_layout = 0x0409;
    settings.cliprdr = 1;
    settings.rdpsnd = 1;
    settings.rail = 1;
    settings.rdpdr = 1;
    // get some info from os
    if (std.posix.getenv("USER")) |auser_env|
    {
        strings.copyZ(&settings.username, auser_env);
    }
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 =
            std.mem.zeroes([std.posix.HOST_NAME_MAX]u8);
    const hostname = try std.posix.gethostname(&hostname_buf);
    strings.copyZ(&settings.clientname, hostname);
    // process command line args
    var slice_arg: []u8 = undefined;
    var index: usize = 1;
    const count = std.os.argv.len;
    while (index < count) : (index += 1)
    {
        slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
        try log.logln(log.LogLevel.info, @src(), "{} {} {s}",
                .{index, count, slice_arg});
        if (std.mem.eql(u8, slice_arg, "-h"))
        {
            return error.ShowCommandLine;
        }
        else if (std.mem.eql(u8, slice_arg, "-u"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            try log.logln(log.LogLevel.info, @src(), "{} {} {s}",
                    .{index, count, slice_arg});
            strings.copyZ(&settings.username, slice_arg);
            try hexdump.printHexDump(0, &settings.username);
        }
        else if (std.mem.eql(u8, slice_arg, "-d"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.domain, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-s"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.altshell, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-c"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.workingdir, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-p"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.password, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-n"))
        {
            if (index + 1 >= count)
            {
                return error.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.clientname, slice_arg);
        }
        else
        {
            strings.copyZ(&rdp_connect.server_name, slice_arg);
            const sep = std.mem.lastIndexOfLinear(u8, slice_arg, ":");
            if (sep) |asep|
            {
                if (slice_arg.len - asep > 4)
                {
                    strings.copyZ(&rdp_connect.server_name, slice_arg[0..asep]);
                    strings.copyZ(&rdp_connect.server_port, slice_arg[asep + 1..]);
                }
            }
        }
    }
    // print summary
    try log.logln(log.LogLevel.info, @src(), "domain [{s}]",
            .{std.mem.sliceTo(&settings.domain, 0)});
    try log.logln(log.LogLevel.info, @src(), "username [{s}]",
            .{std.mem.sliceTo(&settings.username, 0)});
    try log.logln(log.LogLevel.info, @src(), "altshell [{s}]",
            .{std.mem.sliceTo(&settings.altshell, 0)});
    try log.logln(log.LogLevel.info, @src(), "workingdir [{s}]",
            .{std.mem.sliceTo(&settings.workingdir, 0)});
    try log.logln(log.LogLevel.info, @src(), "hostname [{s}]",
            .{std.mem.sliceTo(&settings.clientname, 0)});
    try log.logln(log.LogLevel.info, @src(), "server name [{s}]",
            .{std.mem.sliceTo(&rdp_connect.server_name, 0)});
    try log.logln(log.LogLevel.info, @src(), "server port [{s}]",
            .{std.mem.sliceTo(&rdp_connect.server_port, 0)});
}

//*****************************************************************************
fn create_rdpc_session(rdp_connect: *rdpc_session.rdp_connect_t)
        !*rdpc_session.rdp_session_t
{
    const settings = try g_allocator.create(c.struct_rdpc_settings_t);
    defer g_allocator.destroy(settings);
    settings.* = std.mem.zeroInit(c.struct_rdpc_settings_t, .{});
    const result = process_args(settings, rdp_connect);
    if (result) |_| { } else |err|
    {
        if (err == error.ShowCommandLine)
        {
            try show_command_line_args();
        }
        return err;
    }
    return try rdpc_session.create(&g_allocator, settings, rdp_connect);
}

//*****************************************************************************
fn term_sig(_: c_int) callconv(.C) void
{
    const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
    _ = posix.write(rdpc_session.g_term[1], msg[0..4]) catch return;
}

//*****************************************************************************
fn pipe_sig(_: c_int) callconv(.C) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
    rdpc_session.g_term = try posix.pipe();
    var sa: posix.Sigaction = undefined;
    sa.mask = posix.empty_sigset;
    sa.flags = 0;
    sa.handler = .{ .handler = term_sig };
    try posix.sigaction(posix.SIG.INT, &sa, null);
    try posix.sigaction(posix.SIG.TERM, &sa, null);
    sa.handler = .{ .handler = pipe_sig };
    try posix.sigaction(posix.SIG.PIPE, &sa, null);
}

//*****************************************************************************
fn cleanup_signals() void
{
    posix.close(rdpc_session.g_term[0]);
    posix.close(rdpc_session.g_term[1]);
}

//*****************************************************************************
pub fn main() !void
{
    try log.init(&g_allocator, log.LogLevel.debug);
    defer log.deinit();
    try log.logln(log.LogLevel.info, @src(),
            "starting up, pid {}",
            .{std.os.linux.getpid()});
    try setup_signals();
    defer cleanup_signals();
    try rdpc_session.init();
    defer rdpc_session.deinit();
    const rdp_connect = try g_allocator.create(rdpc_session.rdp_connect_t);
    defer g_allocator.destroy(rdp_connect);
    rdp_connect.* = std.mem.zeroInit(rdpc_session.rdp_connect_t, .{});
    const session = create_rdpc_session(rdp_connect) catch |err|
            if (err == error.ShowCommandLine) return else return err;
    defer session.delete();
    try session.connect();
    try session.loop();
}
