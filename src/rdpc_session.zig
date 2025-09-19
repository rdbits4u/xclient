const std = @import("std");
const log = @import("log");
const hexdump = @import("hexdump");
const rdpc_x11 = @import("rdpc_x11.zig");
const rdpc_x11_clip = @import("rdpc_x11_clip.zig");
const rdpc_pulse = @import("rdpc_pulse.zig");
const net = std.net;
const posix = std.posix;

pub const c = @cImport(
{
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
    @cInclude("pixman.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/extensions/Xfixes.h");
    @cInclude("X11/Xcursor/Xcursor.h");
    @cInclude("pulse/pulseaudio.h");
    @cInclude("librdpc.h");
    @cInclude("libsvc.h");
    @cInclude("libcliprdr.h");
    @cInclude("librdpsnd.h");
    @cInclude("rfxcodec_decode.h");
    @cInclude("rlecodec_decode.h");
    @cInclude("turbojpeg.h");
});

const SesError = error
{
    RegUnion,
    RegZero,
    RfxDecoderCreate,
    RfxDecode,
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
    BitmapUpdate,
    JpgDecode,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: SesError) !void
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
	ptr: ?[*]u8 = null,
};

const audio_t = struct
{
    played: usize = 0,
    channel_id: u16 = 0,
    time_stamp: u16 = 0,
    block_no: u8 = 0,
    slice: []u8 = &.{},
    next: ?*audio_t = null,
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

pub const rdpsnd_format_t = struct
{
    allocator: *const std.mem.Allocator,
    wFormatTag: u16 = 0,
    nChannels: u16 = 0,
    nSamplesPerSec: u32 = 0,
    nAvgBytesPerSec: u32 = 0,
    nBlockAlign: u16 = 0,
    wBitsPerSample: u16 = 0,
    data: []u8 = &.{},

    //*************************************************************************
    fn create(allocator: *const std.mem.Allocator) !*rdpsnd_format_t
    {
        const self = try allocator.create(rdpsnd_format_t);
        self.* = .{.allocator = allocator};
        return self;
    }

    //*************************************************************************
    fn create_from_format(allocator: *const std.mem.Allocator,
            format: *c.rdpsnd_format_t) !*rdpsnd_format_t
    {
        const self = try allocator.create(rdpsnd_format_t);
        self.* = .{.allocator = allocator,
                .wFormatTag = format.wFormatTag,
                .nChannels = format.nChannels,
                .nSamplesPerSec = format.nSamplesPerSec,
                .nAvgBytesPerSec = format.nAvgBytesPerSec,
                .nBlockAlign = format.nBlockAlign,
                .wBitsPerSample = format.wBitsPerSample};
        if (format.cbSize > 0)
        {
            if (format.data) |adata|
            {
                var lslice: []u8 = undefined;
                lslice.ptr = @ptrCast(adata);
                lslice.len = format.cbSize;
                self.data = try self.allocator.alloc(u8, format.cbSize);
                std.mem.copyForwards(u8, self.data, lslice);
            }
        }
        return self;
    }

    //*************************************************************************
    fn delete(self: *rdpsnd_format_t) void
    {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

};

const rdpsnd_formats_t = std.ArrayList(*rdpsnd_format_t);

pub const rdp_session_t = struct
{
    allocator: *const std.mem.Allocator,
    rdp_connect: *rdp_connect_t,
    rdpc: *c.rdpc_t,
    svc: *c.svc_channels_t,
    cliprdr: *c.cliprdr_t,
    rdpsnd: *c.rdpsnd_t,
    formats: rdpsnd_formats_t,
    connected: bool = false,
    sck: i32 = -1,
    recv_start: usize = 0,
    in_data_slice: []u8 = &.{},
    send_head: ?*send_t = null,
    send_tail: ?*send_t = null,
    audio_head: ?*audio_t = null,
    audio_tail: ?*audio_t = null,
    rdp_x11: ?*rdpc_x11.rdp_x11_t = null,
    pulse: ?*rdpc_pulse.rdp_pulse_t = null,

    // for set_surface_bits rfx
    rfx_decoder: ?*anyopaque = null,
    rfx_decoder_awidth: u32 = 0,
    rfx_decoder_aheight: u32 = 0,
    rfx_shm_info: shm_info_t = .{},

    // for set_surface_bits jpg
    jpg_decoder: ?*anyopaque = null,
    jpg_shm_info: shm_info_t = .{},

    // for bitmap_update
    rle_tdata: []u8 = &.{},
    rle_shm_info: shm_info_t = .{},

    //*************************************************************************
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
        rdpc.bitmap_update = cb_rdpc_bitmap_update;
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
        rdpsnd.process_close = cb_rdpsnd_process_close;
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
        const formats = rdpsnd_formats_t.init(allocator.*);

        // init self
        self.* = .{.allocator = allocator, .rdp_connect = rdp_connect,
                .rdpc = rdpc, .svc = svc, .cliprdr = cliprdr, .rdpsnd = rdpsnd,
                .formats = formats};
        return self;
    }

    //*************************************************************************
    pub fn delete(self: *rdp_session_t) void
    {
        self.cleanup_rle();
        self.cleanup_rfx();
        self.cleanup_jpg();
        if (self.rdp_x11) |ardp_x11|
        {
            ardp_x11.delete();
        }
        _ = c.rdpsnd_delete(self.rdpsnd);
        _ = c.cliprdr_delete(self.cliprdr);
        _ = c.svc_delete(self.svc);
        _ = c.rdpc_delete(self.rdpc);
        if (self.sck != -1)
        {
            posix.close(self.sck);
        }
        // free cached audio data
        self.cleanup_audio();
        if (self.pulse) |apulse|
        {
            apulse.delete();
        }
        for (self.formats.items) |ardpsnd_format|
        {
            ardpsnd_format.delete();
        }
        self.formats.deinit();
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
        if (slice.len < 1)
        {
            return;
        }
        if ((self.send_head == null) and try can_send(self.sck))
        {
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
    fn check_rle(self: *rdp_session_t, width: u16, height: u16) !void
    {
        const size: u32 = @as(u32, 4) *
                @as(u32, width) * @as(u32, height);
        if (size > self.rle_shm_info.bytes)
        {
            try self.logln(log.LogLevel.info, @src(),
                    "realloc shm and temp to {}", .{size});
            shm_info_deinit(&self.rle_shm_info);
            try shm_info_init(size, &self.rle_shm_info);
            if (self.rle_shm_info.ptr == null)
            {
                return SesError.BitmapUpdate;
            }
            self.allocator.free(self.rle_tdata);
            self.rle_tdata = try self.allocator.alloc(u8, size);
        }
    }

    //*************************************************************************
    fn cleanup_rle(self: *rdp_session_t) void
    {
        shm_info_deinit(&self.rle_shm_info);
        self.allocator.free(self.rle_tdata);
        self.rle_tdata = &.{};
    }

    //*************************************************************************
    fn bitmap_update(self: *rdp_session_t, bitmap_data: *c.bitmap_data_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(),
                "bits_per_pixel {}",
                .{bitmap_data.bits_per_pixel});
        try self.check_rle(bitmap_data.width, bitmap_data.height);
        if (bitmap_data.bitmap_data) |abitmap_data|
        {
            const rv = c.bitmap_decompress(abitmap_data, self.rle_shm_info.ptr,
                    bitmap_data.width, bitmap_data.height,
                    bitmap_data.bitmap_data_len,
                    bitmap_data.bits_per_pixel,
                    self.rle_tdata.ptr);
            try self.logln_devel(log.LogLevel.info, @src(), "rv {}", .{rv});
            try err_if(rv != 0, SesError.BitmapUpdate);
            if (self.rdp_x11) |ardp_x11|
            {
                // right and bottom are inclusive
                const dest_width = bitmap_data.dest_right -
                        bitmap_data.dest_left + 1;
                const dest_height = bitmap_data.dest_bottom -
                        bitmap_data.dest_top + 1;
                if (ardp_x11.got_xshm)
                {
                    try ardp_x11.draw_image_shm(
                            bitmap_data.width, bitmap_data.height,
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dest_width, dest_height,
                            self.rle_shm_info.shmid,
                            self.rle_shm_info.ptr,
                            null, 0);
                }
                else
                {
                    try ardp_x11.draw_image(
                            bitmap_data.width, bitmap_data.height,
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dest_width, dest_height,
                            self.rle_shm_info.ptr,
                            null, 0);
                }
            }
        }
    }

    //*************************************************************************
    fn check_rfx(self: *rdp_session_t, width: u16, height: u16) !void
    {
        const al: u16 = 63;
        const awidth: u16 = (width + al) & ~al;
        const aheight: u16 = (height + al) & ~al;
        if ((self.rfx_decoder == null) or
                (awidth > self.rfx_decoder_awidth) or
                (aheight > self.rfx_decoder_aheight))
        {
            _ = c.rfxcodec_decode_destroy(self.rfx_decoder);
            self.rfx_decoder = null;
            const rv = c.rfxcodec_decode_create_ex(awidth, aheight,
                    c.RFX_FORMAT_BGRA, c.RFX_FLAGS_SAFE, &self.rfx_decoder);
            errdefer self.cleanup_rfx();
            try self.logln_devel(log.LogLevel.info, @src(),
                    "rfxcodec_decode_create_ex rv {}", .{rv});
            try err_if(rv != 0, SesError.RfxDecoderCreate);
            const size = @as(u32, 4) * awidth * aheight;
            try self.logln(log.LogLevel.info, @src(),
                    "create awidth {} aheight {} size {} al {}",
                    .{awidth, aheight, size, al});
            if (size > self.rfx_shm_info.bytes)
            {
                shm_info_deinit(&self.rfx_shm_info);
                try shm_info_init(size, &self.rfx_shm_info);
                if (self.rfx_shm_info.ptr == null)
                {
                    return SesError.RfxDecoderCreate;
                }
            }
            self.rfx_decoder_awidth = awidth;
            self.rfx_decoder_aheight = aheight;
        }
    }

    //*************************************************************************
    fn cleanup_rfx(self: *rdp_session_t) void
    {
        if (self.rfx_decoder) |arfx_decoder|
        {
            _ = c.rfxcodec_decode_destroy(arfx_decoder);
            self.rfx_decoder = null;
        }
        shm_info_deinit(&self.rfx_shm_info);
    }

    //*************************************************************************
    fn set_surface_bits_rfx(self: *rdp_session_t,
            bitmap_data: *c.bitmap_data_ex_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(), "", .{});
        try self.check_rfx(bitmap_data.width, bitmap_data.height);
        if (self.rfx_decoder) |arfx_decoder|
        {
            var rects: ?[*]c.rfx_rect = null;
            var num_rects: i32 = 0;
            var tiles:  ?[*]c.rfx_tile = null;
            var num_tiles: i32 = 0;
            try self.logln_devel(log.LogLevel.info, @src(),
                    "decode width {} height {}",
                    .{bitmap_data.width, bitmap_data.height});
            const al: u16 = 63;
            const awidth: u16 = (bitmap_data.width + al) & ~al;
            const aheight: u16 = (bitmap_data.height + al) & ~al;
            const ddata_ptr: ?[*]u8 = @ptrCast(self.rfx_shm_info.ptr);
            const rv = c.rfxcodec_decode_ex(arfx_decoder,
                    @ptrCast(bitmap_data.bitmap_data),
                    @bitCast(bitmap_data.bitmap_data_len),
                    ddata_ptr, awidth, aheight,
                    awidth * 4, &rects, &num_rects,
                    &tiles, &num_tiles, 0);
            try self.logln_devel(log.LogLevel.info, @src(),
                    "rfxcodec_decode rv {} num_rects {} num_tiles {}",
                    .{rv, num_rects, num_tiles});
            try err_if(rv != 0, SesError.RfxDecode);
            if (self.rdp_x11) |ardp_x11|
            {
                const dst_width: u32 = bitmap_data.dest_right -
                        bitmap_data.dest_left;
                const dst_height: u32 = bitmap_data.dest_bottom -
                        bitmap_data.dest_top;
                if (ardp_x11.got_xshm)
                {
                    try ardp_x11.draw_image_shm(awidth, aheight,
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dst_width, dst_height,
                            self.rfx_shm_info.shmid,
                            self.rfx_shm_info.ptr,
                            rects, num_rects);
                }
                else
                {
                    try ardp_x11.draw_image(awidth, aheight,
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dst_width, dst_height,
                            self.rfx_shm_info.ptr,
                            rects, num_rects);
                }
            }
        }
    }

    //*************************************************************************
    fn check_jpg(self: *rdp_session_t, width: u16, height: u16) !void
    {
        if (self.jpg_decoder == null)
        {
            try self.logln(log.LogLevel.info, @src(), "tjInitDecompress", .{});
            self.jpg_decoder = c.tjInitDecompress();
            try err_if(self.jpg_decoder == null, SesError.JpgDecode);
        }
        const size: u32 = @as(u32, 4) *
                @as(u32, width) * @as(u32, height);
        if (size > self.jpg_shm_info.bytes)
        {
            try self.logln(log.LogLevel.info, @src(),
                    "realloc shm to {}", .{size});
            shm_info_deinit(&self.jpg_shm_info);
            try shm_info_init(size, &self.jpg_shm_info);
            try err_if(self.jpg_shm_info.ptr == null, SesError.JpgDecode);
        }
    }

    //*************************************************************************
    fn cleanup_jpg(self: *rdp_session_t) void
    {
        if (self.jpg_decoder) |ajpg_decoder|
        {
            _ = c.tjDestroy(ajpg_decoder);
            self.jpg_decoder = null;
        }
        shm_info_deinit(&self.jpg_shm_info);
    }

    //*************************************************************************
    fn set_surface_bits_jpg(self: *rdp_session_t,
            bitmap_data: *c.bitmap_data_ex_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(), "", .{});
        try self.check_jpg(bitmap_data.width, bitmap_data.height);
        if (self.jpg_decoder) |ajpg_decoder|
        {
            // get info about jpeg image
            var lwidth: i32 = 0;
            var lheight: i32 = 0;
            var jpeg_sub_samp: i32 = 0;
            const header_ptr: [*]u8 = @ptrCast(bitmap_data.bitmap_data);
            var header_bytes: usize = header_ptr[1];
            header_bytes = (header_bytes << 8) | header_ptr[0];
            const jpeg_ptr = header_ptr + header_bytes + 2;
            const jpeg_len: usize = bitmap_data.bitmap_data_len - header_bytes;
	        var rv = c.tjDecompressHeader2(ajpg_decoder,
                    jpeg_ptr, jpeg_len,
                    &lwidth, &lheight, &jpeg_sub_samp);
            try self.logln_devel(log.LogLevel.info, @src(),
                    "tjDecompressHeader2 rv {}", .{rv});
            try err_if(rv != 0, SesError.JpgDecode);
            try err_if(lwidth != bitmap_data.width, SesError.JpgDecode);
            try err_if(lheight != bitmap_data.height, SesError.JpgDecode);
            // decompress image
	        rv = c.tjDecompress2(ajpg_decoder,
                    jpeg_ptr, jpeg_len,
                    self.jpg_shm_info.ptr,
                    lwidth, lwidth * 4, lheight,
                    c.TJPF_BGRX, 0);
            try self.logln_devel(log.LogLevel.info, @src(),
                    "tjDecompress2 rv {}", .{rv});
            try err_if(rv != 0, SesError.JpgDecode);
            if (self.rdp_x11) |ardp_x11|
            {
                const dst_width: u32 = bitmap_data.dest_right -
                        bitmap_data.dest_left;
                const dst_height: u32 = bitmap_data.dest_bottom -
                        bitmap_data.dest_top;
                if (ardp_x11.got_xshm)
                {
                    try ardp_x11.draw_image_shm(
                            @bitCast(lwidth), @bitCast(lheight),
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dst_width, dst_height,
                            self.jpg_shm_info.shmid,
                            self.jpg_shm_info.ptr,
                            null, 0);
                }
                else
                {
                    try ardp_x11.draw_image(
                            @bitCast(lwidth), @bitCast(lheight),
                            bitmap_data.dest_left, bitmap_data.dest_top,
                            dst_width, dst_height,
                            self.jpg_shm_info.ptr,
                            null, 0);
                }
            }
        }
    }

    //*************************************************************************
    fn set_surface_bits(self: *rdp_session_t,
            bitmap_data: *c.bitmap_data_ex_t) !void
    {
        try self.logln_devel(log.LogLevel.info, @src(), "", .{});
        return switch (bitmap_data.codec_id)
        {
            c.CODEC_ID_JPEG => self.set_surface_bits_jpg(bitmap_data),
            c.CODEC_ID_REMOTEFX => self.set_surface_bits_rfx(bitmap_data),
            else => {},
        };
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
            try err_if(address_list.addrs.len < 1, SesError.LookupAddress);
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
        if (try can_recv(self.sck) == false)
        {
            return;
        }
        try self.logln_devel(log.LogLevel.info, @src(),
                "server sck is set", .{});
        const recv_slice = self.in_data_slice[self.recv_start..];
        const recv_rv = try posix.recv(self.sck, recv_slice, 0);
        try self.logln_devel(log.LogLevel.info, @src(),
                "recv_rv {} recv_start {}",
                .{recv_rv, self.recv_start});
        if (recv_rv > 0)
        {
            try err_if(!self.connected, SesError.Connect);
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
                    return SesError.RdpcProcessServerData;
                }
            }
        }
        else
        {
            return SesError.Connect;
        }
    }

    //*************************************************************************
    fn process_write_server_data(self: *rdp_session_t) !void
    {
        if (try can_send(self.sck) == false)
        {
            return;
        }
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
                return SesError.RdpcStart;
            }
            const width = self.rdpc.cgcc.core.desktopWidth;
            const height = self.rdpc.cgcc.core.desktopHeight;
            try self.logln(log.LogLevel.info, @src(), "width {} height {}",
                    .{width, height});
            self.rdp_x11 = try rdpc_x11.rdp_x11_t.create(self, self.allocator,
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
                return SesError.Connect;
            }
        }
    }

    //*************************************************************************
    fn get_audio_bytes_in_queue(self: *rdp_session_t) usize
    {
        var bytes: usize = 0;
        var audio = self.audio_head;
        while (audio) |aaudio|
        {
            bytes += aaudio.slice.len;
            audio = aaudio.next;
        }
        return bytes;
    }

    //*************************************************************************
    fn process_write_pulse_data(self: *rdp_session_t) !void
    {
        if (self.pulse) |apulse|
        {
            while (self.audio_head) |aaudio_head|
            {
                const audio = aaudio_head;
                const slice = audio.slice[audio.played..];
                const played = apulse.play_non_blocking(slice) catch 0;
                try self.logln_devel(log.LogLevel.info, @src(),
                        "bytes played {}", .{played});
                if (played > 0)
                {
                    audio.played += played;
                    if (audio.played >= audio.slice.len)
                    {
                        self.audio_head = audio.next;
                        if (self.audio_head == null)
                        {
                            // if audio_head is null, set audio_tail to null
                            self.audio_tail = null;
                        }
                        const bytes = self.get_audio_bytes_in_queue();
                        const mstime = apulse.get_latency(bytes) catch 0;
                        try self.logln_devel(log.LogLevel.debug, @src(),
                                "mstime {} bytes {}", .{mstime, bytes});
                        _ = c.rdpsnd_send_waveconfirm(self.rdpsnd,
                                audio.channel_id,
                                @truncate(audio.time_stamp + mstime),
                                audio.block_no);
                        self.allocator.free(audio.slice);
                        self.allocator.destroy(audio);
                    }
                }
                else
                {
                    try self.logln_devel(log.LogLevel.info, @src(),
                            "played zero", .{});
                    break;
                }
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
            var pulse_index: ?usize = null;
            if (self.pulse) |apulse|
            {
                if (self.audio_head != null)
                {
                    pulse_index = poll_count;
                    polls[poll_count].fd = apulse.play_fifo[0];
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
                if (pulse_index) |apulse_index|
                {
                    if ((active_polls[apulse_index].revents & posix.POLL.IN) != 0)
                    {
                        try self.process_write_pulse_data();
                    }
                }
            }
            else
            {
                return SesError.Connect;
            }
        }
    }

    //*************************************************************************
    fn log_msg_slice(self: *rdp_session_t, msg: []const u8) !void
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
        if (self.rdp_x11) |ardp_x11|
        {
            try ardp_x11.rdp_x11_clip.cliprdr_ready(channel_id,
                    version, general_flags);
        }

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
            try ardp_x11.rdp_x11_clip.cliprdr_format_list(channel_id,
                    msg_flags, num_formats, formats);
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
            try ardp_x11.rdp_x11_clip.cliprdr_format_list_response(channel_id,
                    msg_flags);
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
            try ardp_x11.rdp_x11_clip.cliprdr_data_request(channel_id,
                    requested_format_id);
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
            try ardp_x11.rdp_x11_clip.cliprdr_data_response(channel_id,
                    msg_flags, requested_format_data,
                    requested_format_data_bytes);
            return c.LIBCLIPRDR_ERROR_NONE;
        }
        return c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
    }

    //*************************************************************************
    fn cleanup_audio(self: *rdp_session_t) void
    {
        var audio = self.audio_head;
        while (audio) |aaudio|
        {
            const audio_next = aaudio.next;
            self.allocator.free(aaudio.slice);
            self.allocator.destroy(aaudio);
            audio = audio_next;
        }
        self.audio_head = null;
        self.audio_tail = null;
    }

    //*************************************************************************
    fn rdpsnd_process_close(self: *rdp_session_t, channel_id: u16) !c_int
    {
        try self.logln_devel(log.LogLevel.info, @src(),
                "channel_id 0x{X}", .{channel_id});
        if (self.pulse) |apulse|
        {
            const close_rv = apulse.stop();
            if (close_rv) |_|
            {
                try self.logln(log.LogLevel.info, @src(),
                        "pulse.close ok", .{});
            }
            else |err|
            {
                try self.logln(log.LogLevel.info, @src(),
                        "pulse.close err {}", .{err});
            }
        }
        // free cached audio data
        self.cleanup_audio();
        return c.LIBCLIPRDR_ERROR_NONE;
    }

    //*************************************************************************
    fn rdpsnd_process_wave_slice(self: *rdp_session_t, channel_id: u16,
            time_stamp: u16, format_no: u16, block_no: u8, slice: []u8) !c_int
    {
        try self.logln_devel(log.LogLevel.info, @src(),
                "channel_id 0x{X} time_stamp {} format_no {} " ++
                "block_no {} slice.len {}",
                .{channel_id, time_stamp, format_no, block_no, slice.len});
        if (self.pulse) |apulse|
        {
            if (apulse.pa_stream == null)
            {
                if (format_no < self.formats.items.len)
                {
                    const rdpsnd_format = self.formats.items[format_no];
                    const start_rv = apulse.start("xclient1", 250,
                            rdpsnd_format);
                    if (start_rv) |_|
                    {
                        try self.logln(log.LogLevel.info, @src(),
                                "pulse.start ok", .{});
                    }
                    else |err|
                    {
                        try self.logln(log.LogLevel.info, @src(),
                                "pulse.start err {}", .{err});
                    }
                }
            }
            if (apulse.pa_stream) |_|
            {
                const audio_slice = try self.allocator.alloc(u8, slice.len);
                errdefer self.allocator.free(audio_slice);
                const audio = try self.allocator.create(audio_t);
                errdefer self.allocator.destroy(audio);
                audio.* = .{.channel_id = channel_id,
                        .time_stamp = time_stamp, .block_no = block_no,
                        .slice = audio_slice};
                std.mem.copyForwards(u8, audio.slice, slice);
                if (self.audio_tail) |aaudio_tail|
                {
                    aaudio_tail.next = audio;
                    self.audio_tail = audio;
                }
                else
                {
                    self.audio_head = audio;
                    self.audio_tail = audio;
                }
            }
        }
        return c.LIBRDPSND_ERROR_NONE;
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
            num_formats: u16, formats: [*]c.rdpsnd_format_t) !c_int
    {
        try self.logln(log.LogLevel.info, @src(),
                "channel_id 0x{X} flags {} volume {} pitch {} " ++
                "dgram_port {} version {} block_no {} num_formats {}",
                .{channel_id, flags, volume, pitch, dgram_port, version,
                block_no, num_formats});
        var sformats = std.ArrayList(c.rdpsnd_format_t).init(self.allocator.*);
        defer sformats.deinit();
        if (self.pulse == null)
        {
            const pulse = rdpc_pulse.rdp_pulse_t.create(self,
                    self.allocator, "xclient");
            if (pulse) |apulse|
            {
                try self.logln(log.LogLevel.info, @src(),
                        "rdpc_pulse.create ok", .{});
                self.pulse = apulse;
            }
            else |err|
            {
                try self.logln(log.LogLevel.info, @src(),
                        "rdpc_pulse.create err {}", .{err});
            }
        }
        // clear formats
        for (self.formats.items) |ardpsnd_format|
        {
            ardpsnd_format.delete();
        }
        self.formats.clearRetainingCapacity();
        if (self.pulse) |apulse|
        {
            for (0..num_formats) |index|
            {
                const format = &formats[index];
                const rdpsnd_format = try rdpsnd_format_t.create_from_format(
                        self.allocator, format);
                errdefer rdpsnd_format.delete();
                const format_ok = try apulse.check_format(rdpsnd_format);
                if (format_ok)
                {
                    try sformats.append(format.*);
                    // make a copy
                    const aformat = try self.formats.addOne();
                    aformat.* = rdpsnd_format;
                }
                else
                {
                    rdpsnd_format.delete();
                }
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
    return SesError.RdpcCreate;
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
    return SesError.SvcCreate;
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
    return SesError.CliprdrCreate;
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
    return SesError.RdpsndCreate;
}

//*****************************************************************************
pub fn init() !void
{
    try err_if(c.rdpc_init() != c.LIBRDPC_ERROR_NONE, SesError.RdpcInit);
    try err_if(c.svc_init() != c.LIBSVC_ERROR_NONE, SesError.SvcInit);
    try err_if(c.cliprdr_init() != c.LIBCLIPRDR_ERROR_NONE, SesError.CliprdrInit);
    try err_if(c.rdpsnd_init() != c.LIBRDPSND_ERROR_NONE, SesError.RdpsndInit);
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
    shm_info.shmid = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o600);
    if (shm_info.shmid == -1) return error.shmget;
    errdefer _ = c.shmctl(shm_info.shmid, c.IPC_RMID, null);
    shm_info.ptr = @ptrCast(c.shmat(shm_info.shmid, null, 0));
    const err_ptr: ?[*]u8 = @ptrFromInt(std.math.maxInt(usize));
    if (shm_info.ptr == err_ptr) return error.shmat;
    errdefer _ = c.shmdt(shm_info.ptr);
    shm_info.bytes = @truncate(size);
    // call IPC_RMID now in case app crash
    _ = c.shmctl(shm_info.shmid, c.IPC_RMID, null);
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
        // IPC_RMID called in shm_info_init
        shm_info.shmid = -1;
    }
    shm_info.bytes = 0;
}

//*****************************************************************************
pub fn fifo_is_set(fifo: *[2]i32) !bool
{
    var polls: [1]posix.pollfd = undefined;
    polls[0].fd = fifo[0];
    polls[0].events = posix.POLL.IN;
    polls[0].revents = 0;
    const active_polls = polls[0..1];
    if (try posix.poll(active_polls, 0) > 0)
    {
        if ((active_polls[0].revents & posix.POLL.IN) != 0)
        {
            return true;
        }
    }
    return false;
}

//*****************************************************************************
pub fn fifo_set(fifo: *[2]i32) !void
{
    if (try fifo_is_set(fifo))
    {
        return;
    }
    var buf: [4]u8 = .{'i', 'n', 't', 0};
    _ = try posix.write(fifo[1], &buf);
}

//*****************************************************************************
pub fn fifo_clear(fifo: *[2]i32) !void
{
    while (try fifo_is_set(fifo))
    {
        var buf: [4]u8 = undefined;
        _ = try posix.read(fifo[0], &buf);
    }
}

//*****************************************************************************
fn can_recv(asck: i32) !bool
{
    var polfds: [1]posix.pollfd = undefined;
    polfds[0].fd = asck;
    polfds[0].events = posix.POLL.IN;
    polfds[0].revents = 0;
    const poll_rv = try posix.poll(&polfds, 0);
    if (poll_rv > 0)
    {
        if ((polfds[0].revents & posix.POLL.IN) != 0)
        {
            return true;
        }
    }
    return false;
}

//*****************************************************************************
fn can_send(asck: i32) !bool
{
    var polfds: [1]posix.pollfd = undefined;
    polfds[0].fd = asck;
    polfds[0].events = posix.POLL.OUT;
    polfds[0].revents = 0;
    const poll_rv = try posix.poll(&polfds, 0);
    if (poll_rv > 0)
    {
        if ((polfds[0].revents & posix.POLL.OUT) != 0)
        {
            return true;
        }
    }
    return false;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpc_t* rdpc, const char* msg);
fn cb_rdpc_log_msg(rdpc: ?*c.rdpc_t, msg: ?[*:0]const u8) callconv(.C) c_int
{
    if (msg) |amsg|
    {
        if (rdpc) |ardpc|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBRDPC_ERROR_MEMORY;
                return c.LIBRDPC_ERROR_NONE;
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
// int (*bitmap_update)(struct rdpc_t* rdpc,
//                      struct bitmap_data_t* bitmap_data);
fn cb_rdpc_bitmap_update(rdpc: ?*c.rdpc_t,
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
                asession.bitmap_update(abitmap_data) catch
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
//                         struct bitmap_data_ex_t* bitmap_data);
fn cb_rdpc_set_surface_bits(rdpc: ?*c.rdpc_t,
        bitmap_data: ?*c.bitmap_data_ex_t) callconv(.C) c_int
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
        if (svc) |asvc|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(asvc.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBSVC_ERROR_MEMORY;
                return c.LIBSVC_ERROR_NONE;
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
        if (cliprdr) |acliprdr|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBCLIPRDR_ERROR_MEMORY;
                return c.LIBCLIPRDR_ERROR_NONE;
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
        if (rdpsnd) |ardpsnd|
        {
            const session: ?*rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBRDPSND_ERROR_MEMORY;
                return c.LIBRDPSND_ERROR_NONE;
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
// int (*process_close)(struct rdpsnd_t* rdpsnd, uint16_t channel_id);
fn cb_rdpsnd_process_close(rdpsnd: ?*c.rdpsnd_t,
        channel_id: u16) callconv(.C) c_int
{
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            return asession.rdpsnd_process_close(channel_id) catch
                    c.LIBRDPSND_ERROR_PROCESS_CLOSE;
        }
    }
    return c.LIBRDPSND_ERROR_PROCESS_CLOSE;
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
        formats: ?[*]c.rdpsnd_format_t) callconv(.C) c_int
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
