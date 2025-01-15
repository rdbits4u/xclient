const std = @import("std");
const log = @import("log.zig");
const rdpc_session = @import("rdpc_session.zig");
const posix = std.posix;
const c = @cImport(
{
    @cInclude("librdpc.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

//*****************************************************************************
fn process_args(settings: *c.rdpc_settings_t) !void
{
    settings.width = 800;
    settings.height = 600;
    settings.dpix = 96;
    settings.dpiy = 96;
    settings.keyboard_layout = 0x0409;
    settings.cliprdr = 1;
    settings.rdpsnd = 1;
    settings.rail = 1;
    settings.rdpdr = 1;
    @memcpy(settings.username[0..3], "jay");

    const arg_iterator = std.process.ArgIterator;
    var args_iterator = try arg_iterator.initWithAllocator(g_allocator);
    defer args_iterator.deinit();
    var list = std.ArrayList([]const u8).init(g_allocator);
    defer list.deinit();
    while (args_iterator.next()) |item|
    {
        try list.append(item);
    }
    var index: usize = 0;
    const count: usize = list.items.len;
    while (index < count) : (index += 1)
    {
        try log.logln(log.LogLevel.info, @src(), "{s}",
                .{list.items[index]});
    }
}

//*****************************************************************************
fn create_rdpc_session() !*rdpc_session.rdp_session_t
{
    const settings: *c.rdpc_settings_t =
            try g_allocator.create(c.rdpc_settings_t);
    defer g_allocator.destroy(settings);
    settings.* = .{};
    try process_args(settings);
    return try rdpc_session.create(&g_allocator, settings);
}

//*****************************************************************************
fn term_sig(_: c_int) callconv(.C) void
{
    const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
    _ = posix.write(rdpc_session.g_term[1], msg[0..4]) catch
        return;
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
    try setup_signals();
    defer cleanup_signals();
    try rdpc_session.init();
    defer rdpc_session.deinit();
    const session = try create_rdpc_session();
    defer session.delete();
    try session.connect("205.5.60.2", "3389");
    try session.loop();
}
