
const std = @import("std");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");

const c = rdpc_session.c;

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpc_t* rdpc, const char* msg);
pub export fn cb_rdpc_log_msg(rdpc: ?*c.rdpc_t, msg: ?[*:0]const u8) c_int
{
    var rv = c.LIBRDPC_ERROR_LOG;
    if (msg) |amsg|
    {
        if (rdpc) |ardpc|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBRDPC_ERROR_LOG;
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*send_to_server)(struct rdpc_t* rdpc, void* data, int bytes);
pub export fn cb_rdpc_send_to_server(rdpc: ?*c.rdpc_t,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBRDPC_ERROR_SEND_TO_SERVER;
    if (rdpc) |ardpc|
    {
        if (data) |adata|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                var slice: []u8 = undefined;
                slice.ptr = @ptrCast(adata);
                slice.len = bytes;
                asession.send_slice_to_server(slice) catch
                        return c.LIBRDPC_ERROR_SEND_TO_SERVER;
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*bitmap_update)(struct rdpc_t* rdpc,
//                      struct bitmap_data_t* bitmap_data);
pub export fn cb_rdpc_bitmap_update(rdpc: ?*c.rdpc_t,
        bitmap_data: ?*c.bitmap_data_t) c_int
{
    var rv = c.LIBRDPC_ERROR_BITMAP_UPDATE;
    if (rdpc) |ardpc|
    {
        if (bitmap_data) |abitmap_data|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.bitmap_update(abitmap_data) catch
                        return c.LIBRDPC_ERROR_BITMAP_UPDATE;
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*set_surface_bits)(struct rdpc_t* rdpc,
//                         struct bitmap_data_ex_t* bitmap_data);
pub export fn cb_rdpc_set_surface_bits(rdpc: ?*c.rdpc_t,
        bitmap_data: ?*c.bitmap_data_ex_t) c_int
{
    var rv = c.LIBRDPC_ERROR_SET_SURFACE_BITS;
    if (rdpc) |ardpc|
    {
        if (bitmap_data) |abitmap_data|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.set_surface_bits(abitmap_data) catch
                        return c.LIBRDPC_ERROR_SET_SURFACE_BITS;
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*set_surface_bits)(struct rdpc_t* rdpc,
//                         uint16_t frame_action, uint32_t frame_id);
pub export fn cb_rdpc_frame_marker(rdpc: ?*c.rdpc_t,
        frame_action: u16, frame_id: u32) c_int
{
    var rv = c.LIBRDPC_ERROR_FRAME_MARKER;
    if (rdpc) |ardpc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(ardpc.user));
        if (session) |asession|
        {
            asession.frame_marker(frame_action, frame_id) catch
                    return c.LIBRDPC_ERROR_FRAME_MARKER;
            rv = c.LIBRDPC_ERROR_NONE;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*pointer_update)(struct rdpc_t* rdpc,
//                       struct pointer_t* pointer);
pub export fn cb_rdpc_pointer_update(rdpc: ?*c.rdpc_t,
        pointer: ?*c.pointer_t) c_int
{
    var rv = c.LIBRDPC_ERROR_POINTER_UPDATE;
    if (rdpc) |ardpc|
    {
        if (pointer) |apointer|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpc.user));
            if (session) |asession|
            {
                asession.pointer_update(apointer) catch
                        return c.LIBRDPC_ERROR_POINTER_UPDATE;
                rv = c.LIBRDPC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*pointer_cached)(struct rdpc_t* rdpc,
//                       uint16_t cache_index);
pub export fn cb_rdpc_pointer_cached(rdpc: ?*c.rdpc_t, cache_index: u16) c_int
{
    var rv = c.LIBRDPC_ERROR_POINTER_CACHED;
    if (rdpc) |ardpc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(ardpc.user));
        if (session) |asession|
        {
            asession.pointer_cached(cache_index) catch
                    return c.LIBRDPC_ERROR_POINTER_CACHED;
            rv = c.LIBRDPC_ERROR_NONE;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*channel)(struct rdpc_t* rdpc, uint16_t channel_id,
//                void* data, uint32_t bytes);
pub export fn cb_rdpc_channel(rdpc: ?*c.rdpc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBRDPC_ERROR_CHANNEL;
    if (rdpc) |ardpc|
    {
        const session: ?*rdpc_session.rdp_session_t =
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
pub export fn cb_svc_log_msg(svc: ?*c.svc_channels_t,
        msg: ?[*:0]const u8) c_int
{
    var rv = c.LIBSVC_ERROR_LOG;
    if (msg) |amsg|
    {
        if (svc) |asvc|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(asvc.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBSVC_ERROR_LOG;
                rv = c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*send_data)(struct svc_channels_t* svc, uint16_t channel_id,
//                  uint32_t total_bytes, uint32_t flags,
//                  void* data, uint32_t bytes);
pub export fn cb_svc_send_data(svc: ?*c.svc_channels_t, channel_id: u16,
        total_bytes: u32, flags: u32, data: ?*anyopaque,
        bytes: u32) c_int
{
    var rv = c.LIBSVC_ERROR_SEND_DATA;
    if (svc) |asvc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            asession.logln_devel(log.LogLevel.info, @src(),
                    "total_bytes {} bytes {} flags {}",
                    .{total_bytes, bytes, flags})
                    catch return c.LIBSVC_ERROR_SEND_DATA;
            if (c.rdpc_channel_send_data(asession.rdpc, channel_id,
                    total_bytes, flags, data, bytes) == c.LIBRDPC_ERROR_NONE)
            {
                rv = c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct cliprdr_t* cliprdr, const char* msg);
pub export fn cb_drdynvc_log_msg(drdynvc: ?*c.drdynvc_t,
        msg: ?[*:0]const u8) c_int
{
    var rv = c.LIBDRDYNVC_ERROR_LOG;
    if (msg) |amsg|
    {
        if (drdynvc) |adrdynvc|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(adrdynvc.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBDRDYNVC_ERROR_LOG;
                rv = c.LIBDRDYNVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*send_data)(struct drdynvc_t* drdynvc, uint16_t channel_id,
//                  void* data, uint32_t bytes);
pub export fn cb_drdynvc_svc_send_data(drdynvc: ?*c.drdynvc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBDRDYNVC_ERROR_SEND_DATA;
    if (drdynvc) |adrdynvc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(adrdynvc.user));
        if (session) |asession|
        {
            asession.logln(log.LogLevel.info, @src(), "bytes {}", .{bytes})
                    catch return c.LIBDRDYNVC_ERROR_LOG;
            if (c.svc_send_data(asession.svc, channel_id, data, bytes) ==
                    c.LIBSVC_ERROR_NONE)
            {
                rv = c.LIBDRDYNVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_data)(struct svc_t* svc, uint16_t channel_id,
//                     void* data, uint32_t bytes);
pub export fn cb_svc_drdynvc_process_data(svc: ?*c.svc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBSVC_ERROR_PROCESS_DATA;
    if (svc) |asvc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            if (c.drdynvc_process_data(asession.drdynvc, channel_id,
                    data, bytes) == c.LIBDRDYNVC_ERROR_NONE)
            {
                rv = c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct cliprdr_t* cliprdr, const char* msg);
pub export fn cb_cliprdr_log_msg(cliprdr: ?*c.cliprdr_t,
        msg: ?[*:0]const u8) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_LOG;
    if (msg) |amsg|
    {
        if (cliprdr) |acliprdr|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBCLIPRDR_ERROR_LOG;
                rv = c.LIBCLIPRDR_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*send_data)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                  void* data, uint32_t bytes);
pub export fn cb_cliprdr_svc_send_data(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_SEND_DATA;
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            asession.logln(log.LogLevel.info, @src(), "bytes {}", .{bytes})
                    catch return c.LIBCLIPRDR_ERROR_LOG;
            if (c.svc_send_data(asession.svc, channel_id, data, bytes) ==
                    c.LIBSVC_ERROR_NONE)
            {
                rv = c.LIBCLIPRDR_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*ready)(struct cliprdr_t* cliprdr, uint32_t version,
//              uint32_t general_flags);
pub export fn cb_cliprdr_ready(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        version: u32, general_flags: u32) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_READY;
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            rv = asession.cliprdr_ready(channel_id,
                    version, general_flags) catch c.LIBCLIPRDR_ERROR_READY;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*format_list)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                    uint16_t msg_flags, uint32_t num_formats,
//                    struct cliprdr_format_t* formats);
pub export fn cb_cliprdr_format_list(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        msg_flags: u16, num_formats: u32,
        formats: ?[*]c.cliprdr_format_t) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_FORMAT_LIST;
    if (cliprdr) |acliprdr|
    {
        if (formats) |aformats|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                rv = asession.cliprdr_format_list(channel_id, msg_flags,
                        num_formats, aformats) catch
                        c.LIBCLIPRDR_ERROR_FORMAT_LIST;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*format_list_response)(struct cliprdr_t* cliprdr,
//                             uint16_t channel_id, uint16_t msg_flags);
pub export fn cb_cliprdr_format_list_response(cliprdr: ?*c.cliprdr_t,
        channel_id: u16, msg_flags: u16) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_FORMAT_LIST_RESPONSE;
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            rv = asession.cliprdr_format_list_response(channel_id,
                    msg_flags) catch c.LIBCLIPRDR_ERROR_FORMAT_LIST_RESPONSE;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*data_request)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                     uint32_t requested_format_id);
pub export fn cb_cliprdr_data_request(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        requested_format_id: u32) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_DATA_REQUEST;
    if (cliprdr) |acliprdr|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(acliprdr.user));
        if (session) |asession|
        {
            rv = asession.cliprdr_data_request(channel_id,
                    requested_format_id) catch
                    c.LIBCLIPRDR_ERROR_DATA_REQUEST;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*data_response)(struct cliprdr_t* cliprdr, uint16_t channel_id,
//                      uint16_t msg_flags, void* requested_format_data,
//                      uint32_t requested_format_data_bytes);
pub export fn cb_cliprdr_data_response(cliprdr: ?*c.cliprdr_t, channel_id: u16,
        msg_flags: u16, requested_format_data: ?*anyopaque,
        requested_format_data_bytes: u32) c_int
{
    var rv = c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
    if (cliprdr) |acliprdr|
    {
        if (requested_format_data) |arequested_format_data|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(acliprdr.user));
            if (session) |asession|
            {
                rv = asession.cliprdr_data_response(channel_id, msg_flags,
                        arequested_format_data,
                        requested_format_data_bytes) catch
                        c.LIBCLIPRDR_ERROR_DATA_RESPONSE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_data)(struct svc_t* svc, uint16_t channel_id,
//                     void* data, uint32_t bytes);
pub export fn cb_svc_cliprdr_process_data(svc: ?*c.svc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBSVC_ERROR_PROCESS_DATA;
    if (svc) |asvc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            if (c.cliprdr_process_data(asession.cliprdr, channel_id,
                    data, bytes) == c.LIBCLIPRDR_ERROR_NONE)
            {
                rv = c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*log_msg)(struct rdpsnd_t* rdpsnd, const char* msg);
pub export fn cb_rdpsnd_log_msg(rdpsnd: ?*c.rdpsnd_t,
        msg: ?[*:0]const u8) c_int
{
    var rv = c.LIBRDPSND_ERROR_LOG;
    if (msg) |amsg|
    {
        if (rdpsnd) |ardpsnd|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                asession.log_msg_slice(std.mem.sliceTo(amsg, 0)) catch
                        return c.LIBRDPSND_ERROR_LOG;
                rv = c.LIBRDPSND_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*send_data)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                  void* data, uint32_t bytes);
pub export fn cb_rdpsnd_svc_send_data(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBRDPSND_ERROR_SEND_DATA;
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            asession.logln_devel(log.LogLevel.info, @src(),
                    "bytes {}", .{bytes})
                    catch return c.LIBRDPSND_ERROR_LOG;
            if (c.svc_send_data(asession.svc, channel_id, data, bytes) ==
                    c.LIBSVC_ERROR_NONE)
            {
                rv = c.LIBRDPSND_ERROR_NONE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_close)(struct rdpsnd_t* rdpsnd, uint16_t channel_id);
pub export fn cb_rdpsnd_process_close(rdpsnd: ?*c.rdpsnd_t,
        channel_id: u16) c_int
{
    var rv = c.LIBRDPSND_ERROR_PROCESS_CLOSE;
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            rv = asession.rdpsnd_process_close(channel_id) catch
                    c.LIBRDPSND_ERROR_PROCESS_CLOSE;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_wave)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                     uint16_t time_stamp, uint16_t format_no,
//                     uint8_t block_no, void* data, uint32_t bytes);
pub export fn cb_rdpsnd_process_wave(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        time_stamp: u16, format_no: u16, block_no: u8,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBRDPSND_ERROR_PROCESS_WAVE;
    if (rdpsnd) |ardpsnd|
    {
        if (data) |adata|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                var slice: []u8 = undefined;
                slice.ptr = @ptrCast(adata);
                slice.len = bytes;
                rv = asession.rdpsnd_process_wave_slice(channel_id,
                        time_stamp, format_no, block_no, slice) catch
                        c.LIBRDPSND_ERROR_PROCESS_WAVE;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_training)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                         uint16_t time_stamp, uint16_t pack_size,
//                         void* data, uint32_t bytes);
pub export fn cb_rdpsnd_process_training(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        time_stamp: u16, pack_size: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBRDPSND_ERROR_PROCESS_TRAINING;
    if (rdpsnd) |ardpsnd|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(ardpsnd.user));
        if (session) |asession|
        {
            rv = asession.rdpsnd_process_training(channel_id, time_stamp,
                    pack_size, data, bytes) catch
                    c.LIBRDPSND_ERROR_PROCESS_TRAINING;
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_formats)(struct rdpsnd_t* rdpsnd, uint16_t channel_id,
//                        uint32_t flags, uint32_t volume,
//                        uint32_t pitch, uint16_t dgram_port,
//                        uint16_t version, uint8_t block_no,
//                        uint16_t num_formats, struct format_t* formats);
pub export fn cb_rdpsnd_process_formats(rdpsnd: ?*c.rdpsnd_t, channel_id: u16,
        flags: u32, volume: u32, pitch: u32, dgram_port: u16,
        version: u16, block_no: u8, num_formats: u16,
        formats: ?[*]c.rdpsnd_format_t) c_int
{
    var rv = c.LIBRDPSND_ERROR_PROCESS_FORMATS;
    if (rdpsnd) |ardpsnd|
    {
        if (formats) |aformats|
        {
            const session: ?*rdpc_session.rdp_session_t =
                    @alignCast(@ptrCast(ardpsnd.user));
            if (session) |asession|
            {
                rv = asession.rdpsnd_process_formats(channel_id, flags,
                        volume, pitch, dgram_port, version, block_no,
                        num_formats, aformats) catch
                        c.LIBRDPSND_ERROR_PROCESS_FORMATS;
            }
        }
    }
    return rv;
}

//*****************************************************************************
// callback
// int (*process_data)(struct svc_t* svc, uint16_t channel_id,
//                     void* data, uint32_t bytes);
pub export fn cb_svc_rdpsnd_process_data(svc: ?*c.svc_t, channel_id: u16,
        data: ?*anyopaque, bytes: u32) c_int
{
    var rv = c.LIBSVC_ERROR_PROCESS_DATA;
    if (svc) |asvc|
    {
        const session: ?*rdpc_session.rdp_session_t =
                @alignCast(@ptrCast(asvc.user));
        if (session) |asession|
        {
            if (c.rdpsnd_process_data(asession.rdpsnd, channel_id,
                    data, bytes) == c.LIBRDPSND_ERROR_NONE)
            {
                rv = c.LIBSVC_ERROR_NONE;
            }
        }
    }
    return rv;
}
