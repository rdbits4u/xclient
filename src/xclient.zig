
const std = @import("std");
const nsrdpc_session = @import("rdpc_session.zig");
const posix = std.posix;
const c = @cImport(
{
    @cInclude("librdpc_gcc.h");
    @cInclude("librdpc_constants.h");
    @cInclude("librdpc.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

//*****************************************************************************
fn process_args(settings: *c.rdpc_settings_t) !void
{
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
    while (index < count)
    {
        std.debug.print("{s}\n", .{list.items[index]});
        index += 1;
    }
    settings.i1 = 3389;
}

//*****************************************************************************
fn create_rdpc_session() !*nsrdpc_session.rdp_session_t
{
    const settings: *c.rdpc_settings_t =
            try g_allocator.create(c.rdpc_settings_t);
    defer g_allocator.destroy(settings);
    settings.* = .{};
    try process_args(settings);
    return try nsrdpc_session.create(&g_allocator, settings);
}

//*****************************************************************************
fn term_sig(_: c_int) callconv(.C) void
{
    const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
    _ = posix.write(nsrdpc_session.g_term[1], msg[0..4]) catch
        return;
}

//*****************************************************************************
fn pipe_sig(_: c_int) callconv(.C) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
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
pub fn main() !void
{
    nsrdpc_session.g_term = try posix.pipe();
    defer
    {
        posix.close(nsrdpc_session.g_term[0]);
        posix.close(nsrdpc_session.g_term[1]);
    }
    try setup_signals();
    const rdpc_session = try create_rdpc_session();
    defer rdpc_session.delete();
    try rdpc_session.connect();
    try rdpc_session.loop();
}
