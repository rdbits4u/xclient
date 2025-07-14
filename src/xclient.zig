const std = @import("std");
const builtin = @import("builtin");
const hexdump = @import("hexdump");
const strings = @import("strings");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");
const posix = std.posix;

const c = rdpc_session.c;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

const MyError = error
{
    ShowCommandLine,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: MyError) !void
{
    if (b) return err else return;
}

//*****************************************************************************
fn show_command_line_args() !void
{
    const app_name = std.mem.sliceTo(std.os.argv[0], 0);
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    const vstr = builtin.zig_version_string;
    try writer.print("{s} - A sample application for librdpc\n", .{app_name});
    try writer.print("built with zig version {s}\n", .{vstr});
    try writer.print("Usage: xclient [options] server[:port]\n", .{});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -u: username\n", .{});
    try writer.print("  -d: domain\n", .{});
    try writer.print("  -s: set startup-shell\n", .{});
    try writer.print("  -c: initial working directory\n", .{});
    try writer.print("  -p: password\n", .{});
    try writer.print("  -n: hostname\n", .{});
    try writer.print("  -g: set geometry, using format WxH, default is 1024x768\n", .{});
    try writer.print("server:port examples\n", .{});
    try writer.print("  {s} 192.168.1.1\n", .{app_name});
    try writer.print("  {s} 192.168.1.1:3390\n", .{app_name});
    try writer.print("  {s} [aa:bb:cc:dd]\n", .{app_name});
    try writer.print("  {s} [aa:bb:cc:dd]:3390\n", .{app_name});
    try writer.print("  {s} /tmp/xrdp.socket\n", .{app_name});
}

//*****************************************************************************
fn process_server_port(rdp_connect: *rdpc_session.rdp_connect_t,
        slice_arg: []u8) void
{
    if (slice_arg.len < 1)
    {
        return;
    }
    // look for /tmp/xrdp.socket
    const dst: []u8 = if (slice_arg[0] == '/')
            &rdp_connect.server_port else &rdp_connect.server_name;
    strings.copyZ(dst, slice_arg);
    const sep1 = std.mem.lastIndexOfLinear(u8, slice_arg, ":");
    const sep2 = std.mem.lastIndexOfLinear(u8, slice_arg, "]");
    const sep3 = std.mem.lastIndexOfLinear(u8, slice_arg, "[");
    while (true) : (break)
    {
        if (sep1) |asep1| // look for [aaaa:bbbb:cccc:dddd]:3389
        {
            if (sep2) |asep2|
            {
                if (sep3) |asep3|
                {
                    if (asep1 > asep2)
                    {
                        const s = slice_arg[asep3 + 1..asep2];
                        const p = slice_arg[asep1 + 1..];
                        strings.copyZ(&rdp_connect.server_name, s);
                        strings.copyZ(&rdp_connect.server_port, p);
                        break;
                    }
                }
            }
        }
        if (sep2) |asep2| // look for [aaaa:bbbb:cccc:dddd]
        {
            if (sep3) |asep3|
            {
                const s = slice_arg[asep3 + 1..asep2];
                strings.copyZ(&rdp_connect.server_name, s);
                break;
            }
        }
        if (sep1) |asep1| // look for 127.0.0.1:3389
        {
            const s = slice_arg[0..asep1];
            const p = slice_arg[asep1 + 1..];
            strings.copyZ(&rdp_connect.server_name, s);
            strings.copyZ(&rdp_connect.server_port, p);
            break;
        }
    }
}

//*****************************************************************************
fn process_args(settings: *c.rdpc_settings_t,
        rdp_connect: *rdpc_session.rdp_connect_t) !void
{
    // default some stuff
    strings.copyZ(&rdp_connect.server_port, "3389");
    settings.bpp = 32;
    settings.width = 1024;
    settings.height = 768;
    settings.dpix = 96;
    settings.dpiy = 96;
    settings.keyboard_layout = 0x0409;
    settings.rfx = 1;
    settings.jpg = 0;
    settings.use_frame_ack = 1;
    settings.frames_in_flight = 5;
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
    if (count < 2)
    {
        try log.logln(log.LogLevel.info, @src(),
                "not enough parameters", .{});
        return MyError.ShowCommandLine;
    }
    while (index < count) : (index += 1)
    {
        slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
        try log.logln(log.LogLevel.info, @src(), "{} {} {s}",
                .{index, count, slice_arg});
        if (std.mem.eql(u8, slice_arg, "-h"))
        {
            return MyError.ShowCommandLine;
        }
        else if (std.mem.eql(u8, slice_arg, "-u"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.username, slice_arg);
            try hexdump.printHexDump(0, &settings.username);
        }
        else if (std.mem.eql(u8, slice_arg, "-d"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.domain, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-s"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.altshell, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-c"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.workingdir, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-p"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.password, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-n"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            strings.copyZ(&settings.clientname, slice_arg);
        }
        else if (std.mem.eql(u8, slice_arg, "-g"))
        {
            if (index + 1 >= count)
            {
                return MyError.ShowCommandLine;
            }
            index += 1;
            slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
            var seq = std.mem.tokenizeSequence(u8, slice_arg, "x");
            if (seq.next()) |chunk0|
            {
                settings.width = try std.fmt.parseInt(c_int, chunk0, 10);
                if (seq.next()) |chunk1|
                {
                    settings.height = try std.fmt.parseInt(c_int, chunk1, 10);
                }
                else
                {
                    return MyError.ShowCommandLine;
                }
            }
            else
            {
                return MyError.ShowCommandLine;
            }
        }
        else
        {
            process_server_port(rdp_connect, slice_arg);
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
    settings.* = .{};
    const result = process_args(settings, rdp_connect);
    if (result) |_| { } else |err|
    {
        if (err == MyError.ShowCommandLine)
        {
            try show_command_line_args();
        }
        return err;
    }
    return try rdpc_session.rdp_session_t.create(&g_allocator,
            settings, rdp_connect);
}

//*****************************************************************************
fn term_sig(_: c_int) callconv(.C) void
{
    rdpc_session.fifo_set(&rdpc_session.g_term) catch return;
}

//*****************************************************************************
fn pipe_sig(_: c_int) callconv(.C) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
    rdpc_session.g_term = try posix.pipe();
    errdefer posix.close(rdpc_session.g_term[0]);
    errdefer posix.close(rdpc_session.g_term[1]);
    var sa: posix.Sigaction = undefined;
    sa.mask = posix.empty_sigset;
    sa.flags = 0;
    sa.handler = .{ .handler = term_sig };
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor == 13))
    {
        try posix.sigaction(posix.SIG.INT, &sa, null);
        try posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        try posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
    else
    {
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
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
    rdp_connect.* = .{};
    const session = create_rdpc_session(rdp_connect) catch |err|
            if (err == MyError.ShowCommandLine) return else return err;
    defer session.delete();
    try session.connect();
    try session.loop();
}
