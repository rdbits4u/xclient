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
    @cInclude("libsvc.h");
    @cInclude("libcliprdr.h");
    @cInclude("librdpsnd.h");
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
    SvcInit,
    SvcCreate,
    CliprdrInit,
    CliprdrCreate,
    RdpsndInit,
    RdpsndCreate,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: MyError) !void
{
    if (b) return err else return;
}

//*****************************************************************************
pub fn c_int_to_error(rv: c_int) !void
{
    switch (rv)
    {
        else => return,
    }
}

//*****************************************************************************
pub fn error_to_c_int(err: anyerror) c_int
{
    switch (err)
    {
        else => return c.LIBRDPC_ERROR_OTHER,
    }
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
    out_data_slice: []u8,
    next: ?*send_t = null,
};

pub const rdp_connect_t = struct
{
    server_name: [512]u8 = std.mem.zeroes([512]u8),
    server_port: [64]u8 = std.mem.zeroes([64]u8),
};

pub const rdp_session_t = struct
{
    allocator: *const std.mem.Allocator,
    rdp_connect: *rdp_connect_t,
    rdpc: *c.rdpc_t,
    svc: *c.svc_channels_t,
    cliprdr: *c.cliprdr_t,
    rdpsnd: *c.rdpsnd_t,
    connected: bool = false,
    sck: i32 = -1,
    recv_start: usize = 0,
    in_data_slice: []u8 = &.{},
    send_head: ?*send_t = null,
    send_tail: ?*send_t = null,
    rdp_x11: ?*rdpc_x11.rdp_x11_t = null,

    rfxdecoder: ?*anyopaque = null,
    ddata: []u8 = &.{},
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
        _ = c.svc_delete(self.svc);
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
        const out_data_slice = try self.allocator.alloc(u8, slice.len);
        errdefer self.allocator.free(out_data_slice);
        const send: *send_t = try self.allocator.create(send_t);
        errdefer self.allocator.destroy(send);
        send.* = .{.out_data_slice = out_data_slice};
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
    fn frame_marker(self: *rdp_session_t, frame_action: u16,
            frame_id: u32) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(),
                "frame_action {} frame_id {}", .{frame_action, frame_id});
        if (frame_action == c.SURFACECMD_FRAMEACTION_END)
        {
            const rv = c.rdpc_send_frame_ack(self.rdpc, frame_id);
            _ = rv;
            //try c_int_to_error(rv);
        }
    }

    //*************************************************************************
    fn pointer_update(self: *rdp_session_t, pointer: *c.pointer_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(), "bpp {}",
                .{pointer.xor_bpp});

        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.pointer_update(pointer);
        }

    }

    //*************************************************************************
    fn pointer_cached(self: *rdp_session_t, cache_index: u16) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(), "cache_index {}",
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
                var bp: u32 = 0;
                // bytes_in_buf
                const bib: u32 = @truncate(server_data_slice.len);
                const rv = c.rdpc_process_server_data(self.rdpc,
                        server_data_slice.ptr, bib, &bp);
                if (rv == c.LIBRDPC_ERROR_NONE)
                {
                    // copy any left over data up to front of in_data_slice
                    const slice = self.in_data_slice;
                    std.mem.copyForwards(u8, slice[0..], slice[bp..end]);
                    end -= bp;
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
        self.in_data_slice = try self.allocator.alloc(u8, 128 * 1024);
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

    //*************************************************************************
    fn cliprdr_ready(self: *rdp_session_t, channel_id: u16,
            version: u32, general_flags: u32) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "channel_id 0x{X} version {} general_flags 0x{X}",
            .{channel_id, version, general_flags});
        return c.cliprdr_send_capabilities(self.cliprdr, channel_id,
                version, general_flags);
    }

    //*************************************************************************
    fn cliprdr_format_list(self: *rdp_session_t, channel_id: u16,
            msg_flags: u16, num_formats: u32,
            formats: [*]c.cliprdr_format_t) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "channel_id 0x{X} num_formats {}",
            .{channel_id, num_formats});
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.cliprdr_format_list(channel_id, msg_flags,
                    num_formats, formats);
            return c.LIBCLIPRDR_ERROR_NONE;
        }
        return c.LIBCLIPRDR_ERROR_FORMAT_LIST;
    }

    //*************************************************************************
    fn cliprdr_format_list_response(self: *rdp_session_t, channel_id: u16,
            msg_flags: u16) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "msg_flags 0x{X}", .{msg_flags});
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.cliprdr_format_list_response(channel_id, msg_flags);
            return c.LIBCLIPRDR_ERROR_NONE;
        }
        return c.LIBCLIPRDR_ERROR_FORMAT_LIST;
    }

    //*************************************************************************
    fn cliprdr_data_request(self: *rdp_session_t, channel_id: u16,
            requested_format_id: u32) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "requested_format_id 0x{X}", .{requested_format_id});
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.cliprdr_data_request(channel_id, requested_format_id);
            return c.LIBCLIPRDR_ERROR_NONE;
        }
        return c.LIBCLIPRDR_ERROR_DATA_REQUEST;
    }

    //*************************************************************************
    fn cliprdr_data_response(self: *rdp_session_t, channel_id: u16,
            msg_flags: u16, requested_format_data: ?*anyopaque,
            requested_format_data_bytes: u32) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "msg_flags 0x{X} requested_format_data_bytes {}",
            .{msg_flags, requested_format_data_bytes});
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.cliprdr_data_response(channel_id, msg_flags,
                    requested_format_data, requested_format_data_bytes);
            return c.LIBCLIPRDR_ERROR_NONE;
        }
        return c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
    }

    //*************************************************************************
    fn rdpsnd_process_wave_slice(self: *rdp_session_t, channel_id: u16,
            time_stamp: u16, format_no: u16, block_no: u8, slice: []u8) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
                "channel_id 0x{X} time_stamp {} format_no {} " ++
                "block_no {} slice.len {}",
                .{channel_id, time_stamp, format_no, block_no, slice.len});
        return c.rdpsnd_send_waveconfirm(self.rdpsnd, channel_id,
                time_stamp, block_no);
    }

    //*************************************************************************
    fn rdpsnd_process_training(self: *rdp_session_t, channel_id: u16,
            time_stamp: u16, pack_size: u16,
            data: ?*anyopaque, bytes: u32) !c_int
    {
        try self.logln(log.LogLevel.info, @src(), "", .{});
        _ = data;
        _ = bytes;
        // doc says do not send data back in training confirm
        return c.rdpsnd_send_training(self.rdpsnd, channel_id,
                time_stamp, pack_size, null, 0);
    }

    //*************************************************************************
    fn rdpsnd_process_formats(self: *rdp_session_t, channel_id: u16,
            flags: u32, volume: u32, pitch: u32, dgram_port: u16,
            version: u16, block_no: u8,
            num_formats: u16, formats: [*]c.format_t) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
            "channel_id 0x{X} flags {} volume {} pitch {} dgram_port {} " ++
            "version {} block_no {} num_formats {}",
            .{channel_id, flags, volume, pitch, dgram_port, version,
            block_no, num_formats});
        var sformats = std.ArrayList(c.format_t).init(self.allocator.*);
        defer sformats.deinit();
        for (0..num_formats) |index|
        {
            const format = &formats[index];
            if (format.wFormatTag == 1)
            {
                try sformats.append(format.*);
            }
        }
        return c.rdpsnd_send_formats(self.rdpsnd, channel_id, flags,
                volume, pitch, dgram_port, version, block_no,
                @truncate(sformats.items.len), sformats.items.ptr);
    }

};

//*****************************************************************************
fn create_rdpc(settings: *c.rdpc_settings_t) !*c.rdpc_t
{
    var rdpc: ?*c.rdpc_t = null;
    const rv = c.rdpc_create(settings, &rdpc);
    if (rv == c.LIBRDPC_ERROR_NONE)
    {
        if (rdpc) |ardpc|
        {
            return ardpc;
        }
    }
    return MyError.RdpcCreate;
}

//*****************************************************************************
fn create_svc() !*c.svc_channels_t
{
    var svc: ?*c.svc_channels_t = null;
    const rv = c.svc_create(&svc);
    if (rv == c.LIBSVC_ERROR_NONE)
    {
        if (svc) |asvc|
        {
            return asvc;
        }
    }
    return MyError.SvcCreate;
}

//*****************************************************************************
fn create_cliprdr() !*c.cliprdr_t
{
    var cliprdr: ?*c.cliprdr_t = null;
    const rv = c.cliprdr_create(&cliprdr);
    if (rv == c.LIBCLIPRDR_ERROR_NONE)
    {
        if (cliprdr) |acliprdr|
        {
            return acliprdr;
        }
    }
    return MyError.CliprdrCreate;
}

//*****************************************************************************
fn create_rdpsnd() !*c.rdpsnd_t
{
    var rdpsnd: ?*c.rdpsnd_t = null;
    const rv = c.rdpsnd_create(&rdpsnd);
    if (rv == c.LIBRDPSND_ERROR_NONE)
    {
        if (rdpsnd) |ardpsnd|
        {
            return ardpsnd;
        }
    }
    return MyError.RdpsndCreate;
}

//*****************************************************************************
pub fn create(allocator: *const std.mem.Allocator,
        settings: *c.rdpc_settings_t,
        rdp_connect: *rdp_connect_t) !*rdp_session_t
{
    const self = try allocator.create(rdp_session_t);
    errdefer allocator.destroy(self);
    // setup rdpc
    var rdpc = try create_rdpc(settings);
    errdefer _ = c.rdpc_delete(rdpc);
    rdpc.user = self;
    rdpc.log_msg = cb_rdpc_log_msg;
    rdpc.send_to_server = cb_rdpc_send_to_server;
    rdpc.set_surface_bits = cb_rdpc_set_surface_bits;
    rdpc.frame_marker = cb_rdpc_frame_marker;
    rdpc.pointer_update = cb_rdpc_pointer_update;
    rdpc.pointer_cached = cb_rdpc_pointer_cached;
    rdpc.channel = cb_rdpc_channel;

    // setup svc
    var svc = try create_svc();
    errdefer _ = c.svc_delete(svc);
    svc.user = self;
    svc.log_msg = cb_svc_log_msg;
    svc.send_data = cb_svc_send_data;

    // setup channels
    const gcc_net = &rdpc.cgcc.net;

    // setup cliprdr
    var cliprdr = try create_cliprdr();
    errdefer _ = c.cliprdr_delete(cliprdr);
    cliprdr.user = self;
    cliprdr.log_msg = cb_cliprdr_log_msg;
    cliprdr.send_data = cb_cliprdr_send_data;
    cliprdr.ready = cb_cliprdr_ready;
    cliprdr.format_list = cb_cliprdr_format_list;
    cliprdr.format_list_response = cb_cliprdr_format_list_response;
    cliprdr.data_request = cb_cliprdr_data_request;
    cliprdr.data_response = cb_cliprdr_data_response;
    var chan_index = gcc_net.channelCount;
    var chan = &gcc_net.channelDefArray[chan_index];
    std.mem.copyForwards(u8, &chan.name, "CLIPRDR");
    chan.options = 0;
    svc.channels[chan_index].user = self;
    svc.channels[chan_index].process_data = cb_svc_cliprdr_process_data;
    gcc_net.channelCount += 1;

    // setup rdpsnd
    var rdpsnd = try create_rdpsnd();
    errdefer _ = c.rdpsnd_delete(rdpsnd);
    rdpsnd.user = self;
    rdpsnd.log_msg = cb_rdpsnd_log_msg;
    rdpsnd.send_data = cb_rdpsnd_send_data;
    rdpsnd.process_wave = cb_rdpsnd_process_wave;
    rdpsnd.process_training = cb_rdpsnd_process_training;
    rdpsnd.process_formats = cb_rdpsnd_process_formats;
    chan_index = gcc_net.channelCount;
    chan = &gcc_net.channelDefArray[chan_index];
    std.mem.copyForwards(u8, &chan.name, "RDPSND");
    chan.options = 0;
    svc.channels[chan_index].user = self;
    svc.channels[chan_index].process_data = cb_svc_rdpsnd_process_data;
    gcc_net.channelCount += 1;

    // init self
    self.* = .{.allocator = allocator, .rdp_connect = rdp_connect,
            .rdpc = rdpc, .svc = svc, .cliprdr = cliprdr, .rdpsnd = rdpsnd};
    return self;
}

//*****************************************************************************
pub fn init() !void
{
    try err_if(c.rdpc_init() != c.LIBRDPC_ERROR_NONE, MyError.RdpcInit);
    try err_if(c.svc_init() != c.LIBSVC_ERROR_NONE, MyError.SvcInit);
    try err_if(c.cliprdr_init() != c.LIBCLIPRDR_ERROR_NONE, MyError.CliprdrInit);
    try err_if(c.rdpsnd_init() != c.LIBRDPSND_ERROR_NONE, MyError.RdpsndInit);
}

//*****************************************************************************
pub fn deinit() void
{
    _ = c.rdpc_deinit();
    _ = c.svc_deinit();
    _ = c.cliprdr_deinit();
    _ = c.rdpsnd_deinit();
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

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpc_t* rdpc, const char* msg);
fn cb_rdpc_log_msg(rdpc: ?*c.rdpc_t, msg: ?[*:0]const u8) callconv(.C) c_int
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
                        @alignCast(@ptrCast(ardpc.user));
                if (session) |asession|
                {
                    // alloc for copy
                    const lmsg: []u8 = asession.allocator.alloc(u8,
                            count) catch return c.LIBRDPC_ERROR_MEMORY;
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
    return c.LIBRDPC_ERROR_NONE;
}

//*****************************************************************************
// callback
// int (*send_to_server)(struct rdpc_t* rdpc, void* data, int bytes);
fn cb_rdpc_send_to_server(rdpc: ?*c.rdpc_t,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (data) |adata|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                var slice: []u8 = undefined;
                slice.ptr = @ptrCast(adata);
                slice.len = bytes;
                rv = c.LIBRDPC_ERROR_NONE;
                asession.send_slice_to_server(slice) catch
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
fn cb_rdpc_set_surface_bits(rdpc: ?*c.rdpc_t,
        bitmap_data: ?*c.bitmap_data_t) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (bitmap_data) |abitmap_data|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.set_surface_bits(abitmap_data) catch
                        return c.LIBRDPC_ERROR_PARSE;
                rv = 0;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*set_surface_bits)(struct rdpc_t* rdpc,
//                         uint16_t frame_action, uint32_t frame_id);
fn cb_rdpc_frame_marker(rdpc: ?*c.rdpc_t,
        frame_action: u16, frame_id: u32) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpc.user));
        if (session) |asession|
        {
            asession.frame_marker(frame_action, frame_id)
                    catch |err| return error_to_c_int(err);
            rv = c.LIBRDPC_ERROR_NONE;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*pointer_update)(struct rdpc_t* rdpc,
//                       struct pointer_t* pointer);
fn cb_rdpc_pointer_update(rdpc: ?*c.rdpc_t,
        pointer: ?*c.pointer_t) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        if (pointer) |apointer|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.pointer_update(apointer) catch
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
fn cb_rdpc_pointer_cached(rdpc: ?*c.rdpc_t, cache_index: u16) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_PARSE;
    if (rdpc) |ardpc|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpc.user));
        if (session) |asession|
        {
            asession.pointer_cached(cache_index) catch
                    return c.LIBRDPC_ERROR_PARSE;
            rv = 0;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*channel)(struct rdpc_t* rdpc, uint16_t channel_id,
//                void* data, uint32_t bytes);
fn cb_rdpc_channel(rdpc: ?*c.rdpc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    var rv: c_int = c.LIBRDPC_ERROR_CHANNEL;
    if (rdpc) |ardpc|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpc.user));
        if (session) |asession|
        {
            if (c.svc_process_data(asession.svc, channel_id,
                    data, bytes) == c.LIBSVC_ERROR_NONE)
            {
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct svc_channels_t* svc, const char* msg);
fn cb_svc_log_msg(svc: ?*c.svc_channels_t,
        msg: ?[*:0]const u8) callconv(.C) c_int
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
            if (svc) |asvc|
            {
                const session: ?*rdp_session_t =
                        @alignCast(@ptrCast(asvc.user));
                if (session) |asession|
                {
                    // alloc for copy
                    const lmsg: []u8 = asession.allocator.alloc(u8,
                            count) catch return c.LIBSVC_ERROR_MEMORY;
                    defer asession.allocator.free(lmsg);
                    // make a copy
                    var index: usize = 0;
                    while (index < count)
                    {
                        lmsg[index] = amsg[index];
                        index += 1;
                    }
                    asession.log_msg_slice(lmsg) catch
                            return c.LIBSVC_ERROR_MEMORY;
                    return c.LIBSVC_ERROR_NONE;
                }
            }
        }
    }
    return c.LIBSVC_ERROR_NONE;
}

//*****************************************************************************
// callback
// int (*send_data)(struct svc_channels_t* svc, uint16_t channel_id,
//                  uint32_t total_bytes, uint32_t flags,
//                  void* data, uint32_t bytes);
fn cb_svc_send_data(svc: ?*c.svc_channels_t, channel_id: u16,
        total_bytes: u32, flags: u32, data: ?*anyopaque,
        bytes: u32) callconv(.C) c_int
{
    if (svc) |asvc|
    {
        const session: ?*rdp_session_t = @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            asession.logln_devel(log.LogLevel.info, @src(),
                    "total_bytes {} bytes {} flags {}",
                    .{total_bytes, bytes, flags})
                    catch return c.LIBSVC_ERROR_SEND_DATA;
            const rv = c.rdpc_channel_send_data(asession.rdpc, channel_id,
                    total_bytes, flags, data, bytes);
            if (rv == c.LIBRDPC_ERROR_NONE)
            {
                return c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return c.LIBSVC_ERROR_SEND_DATA;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct cliprdr_t* cliprdr, const char* msg);
fn cb_cliprdr_log_msg(cliprdr: ?*c.cliprdr_t,
        msg: ?[*:0]const u8) callconv(.C) c_int
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
            if (cliprdr) |acliprdr|
            {
                const session: ?*rdp_session_t =
                        @alignCast(@ptrCast(acliprdr.user));
                if (session) |asession|
                {
                    // alloc for copy
                    const lmsg: []u8 = asession.allocator.alloc(u8,
                            count) catch return c.LIBCLIPRDR_ERROR_MEMORY;
                    defer asession.allocator.free(lmsg);
                    // make a copy
                    var index: usize = 0;
                    while (index < count)
                    {
                        lmsg[index] = amsg[index];
                        index += 1;
                    }
                    asession.log_msg_slice(lmsg) catch
                            return c.LIBCLIPRDR_ERROR_MEMORY;
                    return c.LIBCLIPRDR_ERROR_NONE;
                }
            }
        }
    }
    return c.LIBCLIPRDR_ERROR_NONE;
}

//*****************************************************************************
// callback
// int (*send_data)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                  void* data, uint32_t bytes);
fn cb_cliprdr_send_data(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            asession.logln(log.LogLevel.info, @src(), "bytes {}", .{bytes})
                    catch return c.LIBCLIPRDR_ERROR_SEND_DATA;
            const rv = c.svc_send_data(asession.svc, channel_id, data, bytes);
            if (rv == c.LIBSVC_ERROR_NONE)
            {
                return c.LIBCLIPRDR_ERROR_NONE;
            }
        }
    }
    return c.LIBCLIPRDR_ERROR_SEND_DATA;
}

//*****************************************************************************
// callback
// int (*ready)(struct cliprdr_t* cliprdr, uint32_t version,
//              uint32_t general_flags);
fn cb_cliprdr_ready(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        version: u32, general_flags: u32) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            return asession.cliprdr_ready(channel_id,
                    version, general_flags) catch c.LIBCLIPRDR_ERROR_READY;
        }
    }
    return c.LIBCLIPRDR_ERROR_READY;
}

//*****************************************************************************
// callback
// int (*format_list)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                    uint16_t msg_flags, uint32_t num_formats,
//                    struct cliprdr_format_t* formats);
fn cb_cliprdr_format_list(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        msg_flags: u16, num_formats: u32,
        formats: ?[*]c.cliprdr_format_t) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        if (formats) |aformats|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                return asession.cliprdr_format_list(channel_id, msg_flags,
                        num_formats, aformats) catch
                        c.LIBCLIPRDR_ERROR_FORMAT_LIST;
            }
        }
    }
    return c.LIBCLIPRDR_ERROR_FORMAT_LIST;
}

//*****************************************************************************
// callback
// int (*format_list_response)(struct cliprdr_t* cliprdr,
//                             uint16_t channel_id, uint16_t msg_flags);
fn cb_cliprdr_format_list_response(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        msg_flags: u16) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            return asession.cliprdr_format_list_response(channel_id,
                    msg_flags) catch c.LIBCLIPRDR_ERROR_FORMAT_LIST_RESPONSE;
        }
    }
    return c.LIBCLIPRDR_ERROR_FORMAT_LIST_RESPONSE;
}

//*****************************************************************************
// callback
// int (*data_request)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                     uint32_t requested_format_id);
fn cb_cliprdr_data_request(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        requested_format_id: u32) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            return asession.cliprdr_data_request(channel_id,
                    requested_format_id) catch
                    c.LIBCLIPRDR_ERROR_DATA_REQUEST;
        }
    }
    return c.LIBCLIPRDR_ERROR_DATA_REQUEST;
}

//*****************************************************************************
// callback
// int (*data_response)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                      uint16_t msg_flags, void* requested_format_data,
//                      uint32_t requested_format_data_bytes);
fn cb_cliprdr_data_response(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        msg_flags: u16, requested_format_data: ?*anyopaque,
        requested_format_data_bytes: u32) callconv(.C) c_int
{
    if (cliprdr) |acliprdr|
    {
        if (requested_format_data) |arequested_format_data|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                return asession.cliprdr_data_response(channel_id, msg_flags,
                        arequested_format_data,
                        requested_format_data_bytes) catch
                        c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
            }
        }
    }
    return c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
}

//*****************************************************************************
// callback
// int (*process_data)(struct svc_t* svc, uint16_t channel_id,
//                     void* data, uint32_t bytes);
fn cb_svc_cliprdr_process_data(svc: ?*c.svc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (svc) |asvc|
    {
        const session: ?*rdp_session_t = @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            const rv = c.cliprdr_process_data(asession.cliprdr, channel_id,
                    data, bytes);
            if (rv == c.LIBCLIPRDR_ERROR_NONE)
            {
                return c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return c.LIBSVC_ERROR_PROCESS_DATA;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpsnd_t* rdpsnd, const char* msg);
fn cb_rdpsnd_log_msg(rdpsnd: ?*c.rdpsnd_t,
        msg: ?[*:0]const u8) callconv(.C) c_int
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
            if (rdpsnd) |ardpsnd|
            {
                const session: ?*rdp_session_t =
                        @alignCast(@ptrCast(ardpsnd.user));
                if (session) |asession|
                {
                    // alloc for copy
                    const lmsg: []u8 = asession.allocator.alloc(u8,
                            count) catch return c.LIBRDPSND_ERROR_MEMORY;
                    defer asession.allocator.free(lmsg);
                    // make a copy
                    var index: usize = 0;
                    while (index < count)
                    {
                        lmsg[index] = amsg[index];
                        index += 1;
                    }
                    asession.log_msg_slice(lmsg) catch
                            return c.LIBRDPSND_ERROR_MEMORY;
                    return c.LIBRDPSND_ERROR_NONE;
                }
            }
        }
    }
    return c.LIBRDPSND_ERROR_NONE;
}

//*****************************************************************************
// callback
// int (*send_data)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                  void* data, uint32_t bytes);
fn cb_rdpsnd_send_data(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            asession.logln_devel(log.LogLevel.info, @src(),
                    "bytes {}", .{bytes})
                    catch return c.LIBRDPSND_ERROR_SEND_DATA;
            const rv = c.svc_send_data(asession.svc, channel_id, data, bytes);
            if (rv == c.LIBSVC_ERROR_NONE)
            {
                return c.LIBRDPSND_ERROR_NONE;
            }
        }
    }
    return c.LIBRDPSND_ERROR_SEND_DATA;
}

//*****************************************************************************
// callback
// int (*process_wave)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                     uint16_t time_stamp, uint16_t format_no,
//                     uint8_t block_no, void* data, uint32_t bytes);
fn cb_rdpsnd_process_wave(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        time_stamp: u16, format_no: u16, block_no: u8,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (rdpsnd) |ardpsnd|
    {
        if (data) |adata|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                var slice: []u8 = undefined;
                slice.ptr = @ptrCast(adata);
                slice.len = bytes;
                return asession.rdpsnd_process_wave_slice(channel_id,
                        time_stamp, format_no, block_no, slice) catch
                        c.LIBRDPSND_ERROR_PROCESS_WAVE;
            }
        }
    }
    return c.LIBRDPSND_ERROR_PROCESS_WAVE;
}

//*****************************************************************************
// callback
// int (*process_training)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                         uint16_t time_stamp, uint16_t pack_size,
//                         void* data, uint32_t bytes);
fn cb_rdpsnd_process_training(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        time_stamp: u16, pack_size: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            return asession.rdpsnd_process_training(channel_id, time_stamp,
                    pack_size, data, bytes) catch
                    c.LIBRDPSND_ERROR_PROCESS_TRAINING;
        }
    }
    return c.LIBRDPSND_ERROR_PROCESS_TRAINING;
}

//*****************************************************************************
// callback
// int (*process_formats)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                        uint32_t flags, uint32_t volume,
//                        uint32_t pitch, uint16_t dgram_port,
//                        uint16_t version, uint8_t block_no,
//                        uint16_t num_formats, struct format_t* formats);
fn cb_rdpsnd_process_formats(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        flags: u32, volume: u32, pitch: u32, dgram_port: u16,
        version: u16, block_no: u8, num_formats: u16,
        formats: ?[*]c.format_t) callconv(.C) c_int
{
    if (rdpsnd) |ardpsnd|
    {
        if (formats) |aformats|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                return asession.rdpsnd_process_formats(channel_id, flags,
                        volume, pitch, dgram_port, version, block_no,
                        num_formats, aformats) catch
                        c.LIBRDPSND_ERROR_PROCESS_FORMATS;
            }
        }
    }
    return c.LIBRDPSND_ERROR_PROCESS_FORMATS;
}

//*****************************************************************************
// callback
// int (*process_data)(struct svc_t* svc, uint16_t channel_id,
//                     void* data, uint32_t bytes);
fn cb_svc_rdpsnd_process_data(svc: ?*c.svc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) callconv(.C) c_int
{
    if (svc) |asvc|
    {
        const session: ?*rdp_session_t = @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            const rv = c.rdpsnd_process_data(asession.rdpsnd, channel_id,
                    data, bytes);
            asession.logln_devel(log.LogLevel.info, @src(), "rv {}", .{rv})
                    catch return c.LIBSVC_ERROR_PROCESS_DATA;
            if (rv == c.LIBRDPSND_ERROR_NONE)
            {
                return c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return c.LIBSVC_ERROR_PROCESS_DATA;
}
