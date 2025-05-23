const std = @import("std");
const log = @import("log");
const hexdump = @import("hexdump");
const rdpc_x11 = @import("rdpc_x11.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/Xcursor/Xcursor.h");
    @cInclude("librdpc.h");
    @cInclude("pixman.h");
    @cInclude("rfxcodec_decode.h");
});

const MyError = error
{
    RegUnion,
    RegZero,
    RfxDecoderCreate,
    LookupAddress,
    Connect,
    RdpcProcessServerData,
    RdpcStart,
    RdpcCreate,
    RdpcInit,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: MyError) !void
{
    if (b) return err else return;
}

pub var g_term: [2]i32 = .{-1, -1};

const shm_info_t = struct
{
	shmid: c_int = -1,
	bytes: u32 = 0,
	ptr: ?*anyopaque = null,
};

// for storing left over data for server
const send_t = struct
{
    sent: usize = 0,
    out_data_slice: []u8 = undefined,
    next: ?*send_t = null,
};

pub const rdp_connect_t = struct
{
    server_name: [512]u8 = std.mem.zeroes([512]u8),
    server_port: [64]u8 = std.mem.zeroes([64]u8),
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
    rdp_connect: *rdp_connect_t = undefined,
    rdp_x11: ?*rdpc_x11.rdp_x11_t = null,

    rfxdecoder: ?*anyopaque = null,
    ddata: []u8 = undefined,
    shm_info: shm_info_t = .{},

    //*************************************************************************
    pub fn delete(self: *rdp_session_t) void
    {
        shm_info_deinit(&self.shm_info);
        self.cleanup_rfxdecoder();
        if (self.rdp_x11) |ardp_x11|
        {
            ardp_x11.delete();
        }
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
    pub fn logln_devel(self: *rdp_session_t, lv: log.LogLevel,
            src: std.builtin.SourceLocation,
            comptime fmt: []const u8, args: anytype) !void
    {
        _ = self;
        try log.logln_devel(lv, src, fmt, args);
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
        std.mem.copyForwards(u8, send.out_data_slice, slice);
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
    fn setup_rfxdecoder(self: *rdp_session_t, width: u16, height: u16) !void
    {
        const al: u16 = 63;
        const awidth: u16 = (width + al) & ~al;
        const aheight: u16 = (height + al) & ~al;
        const rv = c.rfxcodec_decode_create_ex(awidth, aheight,
                c.RFX_FORMAT_BGRA, c.RFX_FLAGS_SAFE, &self.rfxdecoder);
        errdefer self.cleanup_rfxdecoder();
        try self.logln_devel(log.LogLevel.info, @src(),
                "rfxcodec_decode_create_ex rv {}", .{rv});
        if (rv != 0)
        {
            return MyError.RfxDecoderCreate;
        }
        const size = @as(u32, 4) * awidth * aheight;
        try self.logln_devel(log.LogLevel.info, @src(),
                "create awidth {} aheight {} size {} {} al {}",
                .{awidth, aheight, size, @TypeOf(size), al});
        if (size > self.shm_info.bytes)
        {
            shm_info_deinit(&self.shm_info);
            try shm_info_init(size, &self.shm_info);
        }
        if (self.shm_info.ptr) |aptr|
        {
            self.ddata.ptr = @ptrCast(aptr);
            self.ddata.len = self.shm_info.bytes;
        }
        else
        {
            return MyError.RfxDecoderCreate;
        }
    }

    //*************************************************************************
    fn cleanup_rfxdecoder(self: *rdp_session_t) void
    {
        if (self.rfxdecoder) |arfxdecoder|
        {
            _ = c.rfxcodec_decode_destroy(arfxdecoder);
            self.rfxdecoder = null;
        }
    }

    //*************************************************************************
    fn get_rect_reg(self: *rdp_session_t,
            rects: ?[*]c.rfx_rect, num_rects: i32) !*c.pixman_region16_t
    {
        const reg = try self.allocator.create(c.pixman_region16_t);
        errdefer self.allocator.destroy(reg);
        reg.* = .{};
        if (num_rects < 1)
        {
            return MyError.RegZero;
        }
        if (rects) |arects|
        {
            try self.logln_devel(log.LogLevel.info, @src(),
                    "index 0 x {} y {} cx {} cy {}",
                    .{arects[0].x, arects[0].y,
                    arects[0].cx, arects[0].cy});
            c.pixman_region_init_rect(reg,
                    arects[0].x, arects[0].y,
                    @bitCast(arects[0].cx),
                    @bitCast(arects[0].cy));
            errdefer c.pixman_region_fini(reg);
            const count: usize = @intCast(num_rects);
            for (1..count) |index|
            {
                try self.logln_devel(log.LogLevel.info, @src(),
                        "index {} x {} y {} cx {} cy {}",
                        .{index, arects[index].x, arects[index].y,
                        arects[index].cx, arects[index].cy});
                const pixman_bool = c.pixman_region_union_rect(reg, reg,
                        arects[index].x, arects[index].y,
                        @bitCast(arects[index].cx),
                        @bitCast(arects[index].cy));
                if (pixman_bool == 0)
                {
                    return MyError.RegUnion;
                }
            }
        }
        return reg;
    }

    //*************************************************************************
    fn get_tile_reg(self: *rdp_session_t,
            tiles: ?[*]c.rfx_tile, num_tiles: i32) !*c.pixman_region16_t
    {
        const reg = try self.allocator.create(c.pixman_region16_t);
        errdefer self.allocator.destroy(reg);
        reg.* = .{};
        if (num_tiles < 1)
        {
            return MyError.RegZero;
        }
        if (tiles) |atiles|
        {
            try self.logln_devel(log.LogLevel.info, @src(),
                    "index 0 x {} y {} cx {} cy {}",
                    .{atiles[0].x, atiles[0].y,
                    atiles[0].cx, atiles[0].cy});
            c.pixman_region_init_rect(reg,
                    atiles[0].x, atiles[0].y,
                    @bitCast(atiles[0].cx),
                    @bitCast(atiles[0].cy));
            errdefer c.pixman_region_fini(reg);
            const count: usize = @intCast(num_tiles);
            for (1..count) |index|
            {
                try self.logln_devel(log.LogLevel.info, @src(),
                        "index {} x {} y {} cx {} cy {}",
                        .{index, atiles[index].x, atiles[index].y,
                        atiles[index].cx, atiles[index].cy});
                const pixman_bool = c.pixman_region_union_rect(reg, reg,
                        atiles[index].x, atiles[index].y,
                        @bitCast(atiles[index].cx),
                        @bitCast(atiles[index].cy));
                if (pixman_bool == 0)
                {
                    return MyError.RegUnion;
                }
            }
        }
        return reg;
    }

    //*************************************************************************
    fn cleanup_reg(self: *rdp_session_t, reg: *c.pixman_region16_t) void
    {
        c.pixman_region_fini(reg);
        self.allocator.destroy(reg);
    }

    //*************************************************************************
    fn get_clips_from_reg(self: *rdp_session_t, width: u16, height: u16,
            reg: *c.pixman_region16_t) ![]c.XRectangle
    {
        var clips: []c.XRectangle = &.{};
        var box: c.pixman_box16_t = .{.x1 = 0, .y1 = 0,
                .x2 = @bitCast(width), .y2 = @bitCast(height)};
        const reg_overlap = c.pixman_region_contains_rectangle(reg, &box);
        var num_clip_rects: c_int = 0;
        const clip_rects = c.pixman_region_rectangles(reg, &num_clip_rects);
        if ((clip_rects != null) and (num_clip_rects > 0) and
                (reg_overlap == c.PIXMAN_REGION_PART))
        {
            const unum_clip_rects: usize = @intCast(num_clip_rects);
            clips = try self.allocator.alloc(c.XRectangle, unum_clip_rects);
            errdefer self.allocator.free(clips);
            for (0..unum_clip_rects) |index|
            {
                const x = clip_rects[index].x1;
                const y = clip_rects[index].y1;
                const w = clip_rects[index].x2 - x;
                const h = clip_rects[index].y2 - y;
                clips[index].x = x;
                clips[index].y = y;
                clips[index].width = @bitCast(w);
                clips[index].height = @bitCast(h);
            }
        }
        return clips;
    }

    //*************************************************************************
    fn set_surface_bits(self: *rdp_session_t,
            bitmap_data: *c.bitmap_data_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(),
                "bits_per_pixel {}",
                .{bitmap_data.bits_per_pixel});
        if (self.rfxdecoder == null)
        {
            try self.setup_rfxdecoder(bitmap_data.width, bitmap_data.height);
        }
        if (self.rfxdecoder) |arfxdecoder|
        {
            var rects: ?[*]c.rfx_rect = null;
            var num_rects: i32 = 0;
            var tiles:  ?[*]c.rfx_tile = null;
            var num_tiles: i32 = 0;
            try self.logln_devel(log.LogLevel.info, @src(),
                    "decode width {} height {} self.ddata.ptr {*}",
                    .{bitmap_data.width, bitmap_data.height, self.ddata.ptr});
            const al: u16 = 63;
            const awidth: u16 = (bitmap_data.width + al) & ~al;
            const aheight: u16 = (bitmap_data.height + al) & ~al;
            const rv = c.rfxcodec_decode_ex(arfxdecoder,
                    @ptrCast(bitmap_data.bitmap_data),
                    @bitCast(bitmap_data.bitmap_data_len),
                    self.ddata.ptr, awidth, aheight,
                    awidth * 4, &rects, &num_rects,
                    &tiles, &num_tiles, 0);
            try self.logln_devel(log.LogLevel.info, @src(),
                    "rfxcodec_decode rv {} num_rects {} num_tiles {}",
                    .{rv, num_rects, num_tiles});
            if (rv == 0)
            {
                if (self.rdp_x11) |ardp_x11|
                {
                    const rect_reg = try get_rect_reg(self, rects, num_rects);
                    defer self.cleanup_reg(rect_reg);
                    const tile_reg = try get_tile_reg(self, tiles, num_tiles);
                    defer self.cleanup_reg(tile_reg);
                    var reg: c.pixman_region16_t = .{};
                    c.pixman_region_init(&reg);
                    defer c.pixman_region_fini(&reg);
                    var clips: []c.XRectangle = &.{};
                    defer self.allocator.free(clips);
                    const pixman_bool = c.pixman_region_intersect(&reg,
                            rect_reg, tile_reg);
                    if (pixman_bool != 0)
                    {
                        clips = try get_clips_from_reg(self,
                                bitmap_data.width, bitmap_data.height, &reg);
                    }
                    try ardp_x11.draw_image(awidth, aheight,
                            bitmap_data.width, bitmap_data.height,
                            self.ddata, clips);
                }
            }
        }
    }

    //*************************************************************************
    fn pointer_update(self: *rdp_session_t, pointer: *c.pointer_t) !void
    {
        try self.logln(log.LogLevel.info, @src(), "bpp {}",
                .{pointer.xor_bpp});

        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.pointer_update(pointer);
        }

    }

    //*************************************************************************
    fn pointer_cached(self: *rdp_session_t, cache_index: u16) !void
    {
        try self.logln(log.LogLevel.info, @src(), "cache_index {}",
                .{cache_index});
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.pointer_cached(cache_index);
        }
    }

    //*************************************************************************
    pub fn connect(self: *rdp_session_t) !void
    {
        const server = std.mem.sliceTo(&self.rdp_connect.server_name, 0);
        const port = std.mem.sliceTo(&self.rdp_connect.server_port, 0);
        var address: net.Address = undefined;
        const tpe: u32 = posix.SOCK.STREAM;
        if ((port.len > 0) and (port[0] == '/'))
        {
            try self.logln(log.LogLevel.info, @src(),
                    "connecting to uds {s}", .{port});
            address = try net.Address.initUnix(port);
        }
        else
        {
            try self.logln(log.LogLevel.info, @src(),
                    "connecting to tcp {s} {s}", .{server, port});
            const port_u16: u16 = try std.fmt.parseInt(u16, port, 10);
            const address_list = try std.net.getAddressList(self.allocator.*,
                    server, port_u16);
            defer address_list.deinit();
            if (address_list.addrs.len < 1)
            {
                return MyError.LookupAddress;
            }
            address = address_list.addrs[0];
        }
        try self.logln(log.LogLevel.info, @src(), "connecting to {}",
                .{address});
        self.sck = try posix.socket(address.any.family, tpe, 0);
        // set non blocking
        var val1 = try posix.fcntl(self.sck, posix.F.GETFL, 0);
        if ((val1 & posix.SOCK.NONBLOCK) == 0)
        {
            val1 = val1 | posix.SOCK.NONBLOCK;
            _ = try posix.fcntl(self.sck, posix.F.SETFL, val1);
        }
        // connect
        const address_len = address.getOsSockLen();
        const result = posix.connect(self.sck, &address.any, address_len);
        if (result) |_| { } else |err|
        {
            // WouldBlock is ok
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
        try self.logln_devel(log.LogLevel.info, @src(),
                "server sck is set", .{});
        const recv_slice = self.in_data_slice[self.recv_start..];
        const recv_rv = try posix.recv(self.sck, recv_slice, 0);
        try self.logln_devel(log.LogLevel.info, @src(),
                "recv_rv {} recv_start {}",
                .{recv_rv, self.recv_start});
        if (recv_rv > 0)
        {
            if (!self.connected)
            {
                return MyError.Connect;
            }
            var end = self.recv_start + recv_rv;
            while (end > 0)
            {
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
                    const bp_u32: u32 = @bitCast(bp_c_int);
                    // copy any left over data up to front of in_data_slice
                    const slice = self.in_data_slice;
                    for (bp_u32..end) |index|
                    {
                        slice[index - bp_u32] = slice[index];
                    }
                    end -= bp_u32;
                    self.recv_start = end;
                }
                else if (rv == c.LIBRDPC_ERROR_NEED_MORE)
                {
                    self.recv_start = end;
                    break;
                }
                else
                {
                    try self.logln(log.LogLevel.debug, @src(),
                            "rdpc_process_server_data error {}",
                            .{rv});
                    return MyError.RdpcProcessServerData;
                }
            }
        }
        else
        {
            return MyError.Connect;
        }
    }

    //*************************************************************************
    fn process_write_server_data(self: *rdp_session_t) !void
    {
        if (!self.connected)
        {
            self.connected = true;
            try self.logln(log.LogLevel.info, @src(), "connected set", .{});
            // connected complete, lets start
            const rv = c.rdpc_start(self.rdpc);
            if (rv != c.LIBRDPC_ERROR_NONE)
            {
                try self.logln(log.LogLevel.err,
                        @src(), "rdpc_start failed error {}",
                        .{rv});
                return MyError.RdpcStart;
            }
            const width = self.rdpc.cgcc.core.desktopWidth;
            const height = self.rdpc.cgcc.core.desktopHeight;
            try self.logln(log.LogLevel.info, @src(), "width {} height {}",
                    .{width, height});
            self.rdp_x11 = try rdpc_x11.create(self, self.allocator,
                    width, height);
        }
        if (self.send_head) |asend_head|
        {
            const send = asend_head;
            const slice = send.out_data_slice[send.sent..];
            const sent = try posix.send(self.sck, slice, 0);
            if (sent > 0)
            {
                send.sent += sent;
                if (send.sent >= send.out_data_slice.len)
                {
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
            else
            {
                return MyError.Connect;
            }
        }
    }

    //*************************************************************************
    pub fn loop(self: *rdp_session_t) !void
    {
        self.in_data_slice = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(self.in_data_slice);
        const max_polls = 32;
        const max_fds = 16;
        var fds: [max_fds]i32 = undefined;
        var timeout: i32 = undefined;
        var polls: [max_polls]posix.pollfd = undefined;
        var poll_count: usize = undefined;
        while (true)
        {
            try self.logln_devel(log.LogLevel.debug, @src(), "loop", .{});
            timeout = -1;
            poll_count = 0;
            // setup terminate fd
            polls[poll_count].fd = g_term[0];
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            const term_index = poll_count;
            poll_count += 1;
            // setup server fd
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
            // setup x11 fds
            if (self.rdp_x11) |ardp_x11|
            {
                const active_fds = try ardp_x11.get_fds(&fds, &timeout);
                for (active_fds) |fd|
                {
                    polls[poll_count].fd = fd;
                    polls[poll_count].events = posix.POLL.IN;
                    polls[poll_count].revents = 0;
                    poll_count += 1;
                    if (poll_count >= max_polls)
                    {
                        break;
                    }
                }
            }
            const active_polls = polls[0..poll_count];
            const poll_rv = try posix.poll(active_polls, timeout);
            try self.logln_devel(log.LogLevel.debug, @src(),
                    "poll_rv {} revents {}",
                    .{poll_rv, active_polls[ssck_index].revents});
            if (poll_rv > 0)
            {
                if ((active_polls[term_index].revents & posix.POLL.IN) != 0)
                {
                    try self.logln(log.LogLevel.info, @src(), "{s}",
                            .{"term set shutting down"});
                    break;
                }
                if ((active_polls[ssck_index].revents & posix.POLL.IN) != 0)
                {
                    try self.read_process_server_data();
                }
                if ((active_polls[ssck_index].revents & posix.POLL.OUT) != 0)
                {
                    try self.process_write_server_data();
                }
                if (self.rdp_x11) |ardp_x11|
                {
                    try ardp_x11.check_fds();
                }
            }
        }
    }

    //*************************************************************************
    fn log_msg_slice(self: *rdp_session_t, msg: []u8) !void
    {
        try self.logln(log.LogLevel.info, @src(), "[{s}]", .{msg});
    }

};

//*****************************************************************************
pub fn create(allocator: *const std.mem.Allocator,
        settings: *c.rdpc_settings_t,
        rdp_connect: *rdp_connect_t) !*rdp_session_t
{
    const self = try allocator.create(rdp_session_t);
    errdefer allocator.destroy(self);
    self.* = .{};
    self.allocator = allocator;
    self.rdp_connect = rdp_connect;
    try self.logln(log.LogLevel.debug, @src(), "rdp_session_t", .{});
    var rdpc: ?*c.rdpc_t = null;
    const rv = c.rdpc_create(settings, &rdpc);
    errdefer _ = c.rdpc_delete(rdpc);
    if (rv != c.LIBRDPC_ERROR_NONE)
    {
        return MyError.RdpcCreate;
    }
    if (rdpc) |ardpc|
    {
        ardpc.user[0] = self;
        ardpc.log_msg = cb_log_msg;
        ardpc.send_to_server = cb_send_to_server;
        ardpc.set_surface_bits = cb_set_surface_bits;
        ardpc.pointer_update = cb_pointer_update;
        ardpc.pointer_cached = cb_pointer_cached;
        self.rdpc = ardpc;
    }
    else
    {
        return MyError.RdpcCreate;
    }
    return self;
}

//*****************************************************************************
pub fn init() !void
{
    if (c.rdpc_init() != c.LIBRDPC_ERROR_NONE)
    {
        return  MyError.RdpcInit;
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

//*****************************************************************************
// callback
// int (*set_surface_bits)(struct rdpc_t* rdpc,
//                         struct bitmap_data_t* bitmap_data);
fn cb_set_surface_bits(rdpc: ?*c.rdpc_t,
        bitmap_data: ?*c.bitmap_data_t) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (bitmap_data) |abitmap_data|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user[0]));
            if (session) |ardp_session|
            {
                ardp_session.set_surface_bits(abitmap_data) catch
                        return c.LIBRDPC_ERROR_PARSE;
                rv = 0;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*pointer_update)(struct rdpc_t* rdpc,
//                       struct pointer_t* pointer);
fn cb_pointer_update(rdpc: ?*c.rdpc_t,
        pointer: ?*c.pointer_t) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (pointer) |apointer|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user[0]));
            if (session) |ardp_session|
            {
                ardp_session.pointer_update(apointer) catch
                        return c.LIBRDPC_ERROR_PARSE;
                rv = 0;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*pointer_cached)(struct rdpc_t* rdpc,
//                       uint16_t cache_index);
fn cb_pointer_cached(rdpc: ?*c.rdpc_t, cache_index: u16) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpc.user[0]));
        if (session) |ardp_session|
        {
            ardp_session.pointer_cached(cache_index) catch
                    return c.LIBRDPC_ERROR_PARSE;
            rv = 0;
        }
    }
    return rv;
}

//*****************************************************************************
fn shm_info_init(size: usize, shm_info: *shm_info_t) !void
{
    shm_info.shmid = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o777);
    if (shm_info.shmid == -1) return error.shmget;
    errdefer _ = c.shmctl(shm_info.shmid, c.IPC_RMID, null);
    shm_info.ptr = c.shmat(shm_info.shmid, null, 0);
    const err_ptr: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
    if (shm_info.ptr == err_ptr) return error.shmat;
    errdefer _ = c.shmdt(shm_info.ptr);
    shm_info.bytes = @truncate(size);
}

//*****************************************************************************
fn shm_info_deinit(shm_info: *shm_info_t) void
{
    if (shm_info.ptr) |aptr|
    {
        _ = c.shmdt(aptr);
        shm_info.ptr = null;
    }
    if (shm_info.shmid != -1)
    {
        _ = c.shmctl(shm_info.shmid, c.IPC_RMID, null);
        shm_info.shmid = -1;
    }
    shm_info.bytes = 0;
}
