
const std = @import("std");
const hexdump = @import("hexdump");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("librdpc.h");
});

pub var g_term: [2]i32 = .{-1, -1};

pub const rdp_session_t = struct
{
    allocator: *const std.mem.Allocator = undefined,
    rdpc: *c.rdpc_t = undefined,
    sck: c_int = -1,
    recv_start: usize = 0,
    in_data_slice: []u8 = undefined,

    //*************************************************************************
    pub fn delete(self: *rdp_session_t) void
    {
        _ = c.rdpc_delete(self.rdpc);
        if (self.sck != -1)
        {
            posix.close(self.sck);
        }
        self.allocator.destroy(self);
    }

    //*************************************************************************
    // data to the rdp server
    fn send_slice_to_server(self: *rdp_session_t, data: []u8) i32
    {
        hexdump.printHexDump(0, data) catch
            return c.LIBRDPC_ERROR_MEMORY;
        const sent = posix.send(self.sck, data, 0) catch
            return c.LIBRDPC_ERROR_PARSE;
        std.debug.print("{s}: sent {}\n", .{@src().fn_name, sent});
        if (sent != data.len)
        {
            std.debug.print("{s}: send failed sent {} data.len {}\n",
                    .{@src().fn_name, sent, data.len});
        }
        return c.LIBRDPC_ERROR_NONE;
    }

    //*************************************************************************
    pub fn connect(self: *rdp_session_t) !void
    {
        const address = try net.Address.parseIp("192.168.1.1", 3389);
        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        self.sck = try posix.socket(address.any.family, tpe, protocol);
        // set non blocking
        var val1 = try posix.fcntl(self.sck, posix.F.GETFL, 0);
        if ((val1 & posix.SOCK.NONBLOCK) == 0)
        {
            val1 = val1 | posix.SOCK.NONBLOCK;
            _ = try posix.fcntl(self.sck, posix.F.SETFL, val1);
        }
        // connect
        posix.connect(self.sck, &address.any, @sizeOf(net.Address)) catch |err|
        {
            if (err != error.WouldBlock)
            {
                return err;
            }
            // wait for socket to become writable(connected), timeout, or term
            var count_down: usize = 5; // 5 seconds
            while (true)
            {
                std.debug.print("{s}: loop\n", .{@src().fn_name});
                if (count_down < 1)
                {
                    return err;
                }
                var polls: [2]posix.pollfd = undefined;
                polls[0].fd = self.sck;
                polls[0].events = posix.POLL.OUT;
                polls[0].revents = 0;
                polls[1].fd = g_term[0];
                polls[1].events = posix.POLL.IN;
                polls[1].revents = 0;
                const poll_rv = try posix.poll(polls[0..2], 1000);
                if (poll_rv > 0)
                {
                    if ((polls[0].revents & posix.POLL.OUT) != 0)
                    {
                        std.debug.print("{s}: ok\n", .{@src().fn_name});
                        break;
                    }
                    if ((polls[1].revents & posix.POLL.IN) != 0)
                    {
                        var term_data: [4]u8 = undefined;
                        const readed = try posix.read(g_term[0],
                                term_data[0..4]);
                        std.debug.print("{s}: {s} {}\n",
                                .{@src().fn_name,
                                "term set shutting down readed",
                                readed});
                        return err;
                    }
                }
                count_down -= 1;
            }
        };
    }

    //*************************************************************************
    // data from the rdp server
    fn read_process_server_data(self: *rdp_session_t) !void
    {
        std.debug.print("{s}: server sck is set\n", .{@src().fn_name});
        const recv_slice = self.in_data_slice[self.recv_start..];
        const recv_rv = try posix.recv(self.sck, recv_slice, 0);
        std.debug.print("{s}: recv_rv {} recv_start {}\n",
                .{@src().fn_name, recv_rv, self.recv_start});
        if (recv_rv > 0)
        {
            const end = self.recv_start + recv_rv;
            const server_data_slice = self.in_data_slice[0..end];
            // bytes_processed
            var bp_c_int: c_int = 0;
            // bytes_in_buf
            const bib_u32: u32 = @truncate(server_data_slice.len);
            const bib_c_int: c_int = @bitCast(bib_u32);
            const rv = c.rdpc_process_server_data(self.rdpc,
                    server_data_slice.ptr, bib_c_int, &bp_c_int);
            if (rv == c.LIBRDPC_ERROR_NONE)
            {
                // copy any left over data up to front of in_data_slice
                const bp_u32: u32 = @bitCast(bp_c_int);
                const slice = self.in_data_slice;
                var start: u32 = 0;
                while (bp_u32 + start < recv_rv)
                {
                    slice[start] = slice[bp_u32 + start];
                    start += 1;
                }
                self.recv_start = start;
            }
            else if (rv == c.LIBRDPC_ERROR_NEED_MORE)
            {
                self.recv_start = recv_rv;
            }
            else
            {
                std.debug.print("{s}: rdpc_process_server_data error {}\n",
                        .{@src().fn_name, rv});
                return;
            }
        }
    }

    //*************************************************************************
    pub fn loop(self: *rdp_session_t) !void
    {
        const rv = c.rdpc_start(self.rdpc);
        if (rv != c.LIBRDPC_ERROR_NONE)
        {
            std.debug.print("{s}: rdpc_start failed error {}\n",
                    .{@src().fn_name, rv});
            return;
        }
        self.in_data_slice = try self.allocator.alloc(u8,
                64 * 1024);
        defer self.allocator.free(self.in_data_slice);
        var polls: [16]posix.pollfd = undefined;
        var poll_count: usize = undefined;
        while (true)
        {
            std.debug.print("{s}: loop\n", .{@src().fn_name});
            poll_count = 0;
            polls[poll_count].fd = self.sck;
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            const ssck_index = poll_count;
            poll_count += 1;
            polls[poll_count].fd = g_term[0];
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            const term_index = poll_count;
            poll_count += 1;
            const active = polls[0..poll_count];
            const poll_rv = try posix.poll(active, -1);
            std.debug.print("{s}: poll_rv {} revents {}\n",
                    .{@src().fn_name, poll_rv, active[ssck_index].revents});
            if (poll_rv > 0)
            {
                if ((active[ssck_index].revents & posix.POLL.IN) != 0)
                {
                    try self.read_process_server_data();
                }
                if ((active[term_index].revents & posix.POLL.IN) != 0)
                {
                    var term_data: [4]u8 = undefined;
                    const readed = try posix.read(g_term[0], term_data[0..4]);
                    std.debug.print("{s}: term set shutting down readed {}\n",
                            .{@src().fn_name, readed});
                    break;
                }
            }
        }
    }

    //*************************************************************************
    fn log_msg(self: *rdp_session_t, msg: []u8) !void
    {
        _ = self;
        std.debug.print("{s}: msg [{s}]\n", .{@src().fn_name, msg});
    }

};

//*****************************************************************************
pub fn create(allocator: *const std.mem.Allocator,
        settings: *c.rdpc_settings_t) !*rdp_session_t
{
    const self: *rdp_session_t = try allocator.create(rdp_session_t);
    errdefer allocator.destroy(self);
    self.* = .{};
    self.allocator = allocator;
    var rdpc: ?*c.rdpc_t = null;
    const rv = c.rdpc_create(settings, &rdpc);
    if (rv == c.LIBRDPC_ERROR_NONE)
    {
        if (rdpc) |ardpc|
        {
            ardpc.user[0] = self;
            ardpc.log_msg = cb_log_msg;
            ardpc.send_to_server = cb_send_to_server;
            self.rdpc = ardpc;
            return self;
        }
    }
    return error.OutOfMemory;
}

//*****************************************************************************
pub fn init() !void
{
    if (c.rdpc_init() != c.LIBRDPC_ERROR_NONE)
    {
        return  error.OutOfMemory;
    }
}

//*****************************************************************************
pub fn deinit() void
{
    _ = c.rdpc_deinit();
}

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpc_t* rdpc, const char* msg);
fn cb_log_msg(rdpc: ?*c.rdpc_t, msg: ?[*:0]const u8) callconv(.C) c_int
{
    if (msg) |amsg|
    {
        // get string length with max
        var count: usize = 0;
        while (amsg[count] != 0)
        {
            count += 1;
            if (count >= 8192)
            {
                break;
            }
        }
        if (count > 0)
        {
            if (rdpc) |ardpc|
            {
                const session: ?*rdp_session_t =
                        @alignCast(@ptrCast(ardpc.user[0]));
                if (session) |ardp_session|
                {
                    // alloc for copy
                    const lmsg: []u8 = ardp_session.allocator.alloc(u8,
                            count) catch
                        return c.LIBRDPC_ERROR_MEMORY;
                    defer ardp_session.allocator.free(lmsg);
                    // make a copy
                    var index: usize = 0;
                    while (index < count)
                    {
                        lmsg[index] = amsg[index];
                        index += 1;
                    }
                    try ardp_session.log_msg(lmsg);
                    return c.LIBRDPC_ERROR_NONE;
                }
            }
        }
    }
    std.debug.print("{s}: nil\n", .{@src().fn_name});
    return c.LIBRDPC_ERROR_NONE;
}

//*****************************************************************************
// callback
// int (*send_to_server)(struct rdpc_t* rdpc, void* data, int bytes);
fn cb_send_to_server(rdpc: ?*c.rdpc_t,
        data: ?*anyopaque, bytes: c_int) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (data) |adata|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user[0]));
            if (session) |ardp_session|
            {
                var slice: []u8 = undefined;
                slice.ptr = @ptrCast(adata);
                slice.len = @intCast(bytes);
                rv = ardp_session.send_slice_to_server(slice);
            }
        }
    }
    return rv;
}
