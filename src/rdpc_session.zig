const std = @import("std");
const hexdump = @import("hexdump");
const log = @import("log.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("librdpc.h");
});

pub var g_term: [2]i32 = .{-1, -1};

// for storing left over data for server
const send_t = struct
{
    sent: usize = 0,
    out_data_slice: []u8 = undefined,
    next: ?*send_t = null,
};

pub const rdp_session_t = struct
{
    allocator: *const std.mem.Allocator = undefined,
    rdpc: *c.rdpc_t = undefined,
    connected: bool = false,
    sck: i32 = -1,
    recv_start: usize = 0,
    in_data_slice: []u8 = undefined,
    send_head: ?*send_t = null,
    send_tail: ?*send_t = null,

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
    pub fn logln(self: *rdp_session_t, lv: log.LogLevel,
            src: std.builtin.SourceLocation,
            comptime fmt: []const u8, args: anytype) !void
    {
        _ = self;
        try log.logln(lv, src, fmt, args);
    }

    //*************************************************************************
    // data to the rdp server
    fn send_slice_to_server(self: *rdp_session_t, data: []u8) !void
    {
        var slice = data;
        // try to send
        const result = posix.send(self.sck, slice, 0);
        if (result) |aresult|
        {
            try self.logln(log.LogLevel.debug, @src(), "hexdump len {}",
                    .{aresult});
            try hexdump.printHexDump(0, slice[0..aresult]);
            if (aresult >= slice.len)
            {
                // all sent, ok
                return;
            }
            slice = slice[aresult..];
        }
        else |err|
        {
            if (err != error.WouldBlock)
            {
                return err;
            }
        }
        // save any left over data to send later
        const send: *send_t = try self.allocator.create(send_t);
        send.* = .{};
        send.out_data_slice = try self.allocator.alloc(u8, slice.len);
        @memcpy(send.out_data_slice, slice);
        if (self.send_tail) |asend_tail|
        {
            asend_tail.next = send;
            self.send_tail = send;
        }
        else
        {
            self.send_head = send;
            self.send_tail = send;
        }
    }

    //*************************************************************************
    pub fn connect(self: *rdp_session_t) !void
    {
        const address = try net.Address.parseIp("127.0.0.1", 3389);
        //const address = try net.Address.parseIp("205.5.60.19", 3389);
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
        const result = posix.connect(self.sck, &address.any,
                @sizeOf(net.Address));
        if (result) |_|
        { // no error
        }
        else |err|
        {
            if (err != error.WouldBlock)
            {
                return err;
            }
        }
    }

    //*************************************************************************
    // data from the rdp server
    fn read_process_server_data(self: *rdp_session_t) !void
    {
        try self.logln(log.LogLevel.debug, @src(), "server sck is set", .{});
        const recv_slice = self.in_data_slice[self.recv_start..];
        const recv_rv = try posix.recv(self.sck, recv_slice, 0);
        try self.logln(log.LogLevel.debug, @src(), "recv_rv {} recv_start {}",
                .{recv_rv, self.recv_start});
        if (recv_rv > 0)
        {
            if (!self.connected)
            {
                return error.Unexpected;
            }
            const end = self.recv_start + recv_rv;
            const server_data_slice = self.in_data_slice[0..end];
            try self.logln(log.LogLevel.debug, @src(), "hexdump len {}",
                    .{server_data_slice.len});
            try hexdump.printHexDump(0, server_data_slice);
            // bytes_processed
            var bp_c_int: c_int = 0;
            // bytes_in_buf
            const bib_u32: u32 = @truncate(server_data_slice.len);
            const bib_c_int: c_int = @bitCast(bib_u32);
            const rv = c.rdpc_process_server_data(self.rdpc,
                    server_data_slice.ptr, bib_c_int, &bp_c_int);
            if (rv == c.LIBRDPC_ERROR_NONE)
            {
                const bp_u32: u32 = @bitCast(bp_c_int);
                // copy any left over data up to front of in_data_slice
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
                try self.logln(log.LogLevel.debug, @src(),
                        "rdpc_process_server_data error {}",
                        .{rv});
                return;
            }
        }
    }

    //*************************************************************************
    fn process_write_server_data(self: *rdp_session_t) !void
    {
        if (!self.connected)
        {
            self.connected = true;
            try self.logln(log.LogLevel.debug, @src(), "connected set", .{});
            // connected complete, lets start
            const rv = c.rdpc_start(self.rdpc);
            if (rv != c.LIBRDPC_ERROR_NONE)
            {
                try self.logln(log.LogLevel.debug,
                        @src(), "rdpc_start failed error {}",
                        .{rv});
                return;
            }
        }
        if (self.send_head) |asend_head|
        {
            const send = asend_head;
            const slice = send.out_data_slice[send.sent..];
            send.sent += try posix.send(self.sck, slice, 0);
            if (send.sent >= send.out_data_slice.len)
            {
                try self.logln(log.LogLevel.debug, @src(), "hexdump len {}",
                        .{send.out_data_slice.len});
                try hexdump.printHexDump(0, send.out_data_slice);
                self.send_head = send.next;
                if (self.send_head == null)
                {
                    // if send_head is null, set send_tail to null
                    self.send_tail = null;
                }
                self.allocator.free(send.out_data_slice);
                self.allocator.destroy(send);
            }
        }                    
    }

    //*************************************************************************
    pub fn loop(self: *rdp_session_t) !void
    {
        self.in_data_slice = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(self.in_data_slice);
        var polls: [16]posix.pollfd = undefined;
        var poll_count: usize = undefined;
        while (true)
        {
            try self.logln(log.LogLevel.debug, @src(), "loop", .{});
            poll_count = 0;
            polls[poll_count].fd = self.sck;
            polls[poll_count].events = posix.POLL.IN;
            if (!self.connected)
            {
                polls[poll_count].events |= posix.POLL.OUT;
            }
            if (self.send_head != null)
            {
                polls[poll_count].events |= posix.POLL.OUT;
            }
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
            try self.logln(log.LogLevel.debug, @src(), "poll_rv {} revents {}",
                    .{poll_rv, active[ssck_index].revents});
            if (poll_rv > 0)
            {
                if ((active[ssck_index].revents & posix.POLL.IN) != 0)
                {
                    try self.read_process_server_data();
                }
                if ((active[ssck_index].revents & posix.POLL.OUT) != 0)
                {
                    try self.process_write_server_data();
                }
                if ((active[term_index].revents & posix.POLL.IN) != 0)
                {
                    try self.logln(log.LogLevel.debug, @src(), "{s}",
                            .{"term set shutting down"});
                    break;
                }
            }
        }
    }

    //*************************************************************************
    fn log_msg_slice(self: *rdp_session_t, msg: []u8) !void
    {
        try self.logln(log.LogLevel.debug, @src(), "[{s}]", .{msg});
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
                if (session) |asession|
                {
                    // alloc for copy
                    const lmsg: []u8 = asession.allocator.alloc(u8,
                            count) catch
                        return c.LIBRDPC_ERROR_MEMORY;
                    defer asession.allocator.free(lmsg);
                    // make a copy
                    var index: usize = 0;
                    while (index < count)
                    {
                        lmsg[index] = amsg[index];
                        index += 1;
                    }
                    asession.log_msg_slice(lmsg) catch
                        return c.LIBRDPC_ERROR_MEMORY;
                    return c.LIBRDPC_ERROR_NONE;
                }
            }
        }
    }
    log.logln(log.LogLevel.debug, @src(), "nil", .{}) catch
        return c.LIBRDPC_ERROR_MEMORY;
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
                rv = c.LIBRDPC_ERROR_NONE;
                ardp_session.send_slice_to_server(slice) catch
                    return c.LIBRDPC_ERROR_PARSE;
            }
        }
    }
    return rv;
}
