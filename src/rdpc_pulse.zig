const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");
const net = std.net;
const posix = std.posix;

const c = rdpc_session.c;

const PulseError = error
{
    PaMainLoop,
    PaContext,
    PaContextConnect,
    PaStart,
    PaValid,
    PaStream,
};

//*****************************************************************************
inline fn err_if(b: bool, err: PulseError) !void
{
    if (b) return err else return;
}

pub const rdp_pulse_t = struct
{
    session: *rdpc_session.rdp_session_t,
    allocator: *const std.mem.Allocator,
    pa_mainloop: *c.pa_threaded_mainloop,
    pa_context: *c.pa_context,
    pa_stream: ?*c.pa_stream = null,
    channels: i32 = 0,
    pad: i32 = 0,

    //*************************************************************************
    pub fn delete(self: *rdp_pulse_t) void
    {
        c.pa_threaded_mainloop_stop(self.pa_mainloop);
        c.pa_context_disconnect(self.pa_context);
        c.pa_context_unref(self.pa_context);
        c.pa_threaded_mainloop_free(self.pa_mainloop);
        self.allocator.destroy(self);
    }

    //*************************************************************************
    pub fn start(self: *rdp_pulse_t, name: [:0]const u8, ms_latency: u32,
            format: u32) !void
    {
        try self.session.logln(log.LogLevel.info, @src(),
                "name {s} ms_latency {} format {}",
                .{name, ms_latency, format});

        const sample_spec: c.pa_sample_spec = .{};
        const channel_map_p: ?*c.pa_channel_map = null;

        try err_if(c.pa_sample_spec_valid(&sample_spec) == 0, PulseError.PaValid);
        c.pa_threaded_mainloop_lock(self.pa_mainloop);
        defer c.pa_threaded_mainloop_unlock(self.pa_mainloop);

        self.pa_stream = c.pa_stream_new(self.pa_context, name, &sample_spec, channel_map_p);
        try err_if (self.pa_stream == null, PulseError.PaStream);

        // install essential callbacks
        c.pa_stream_set_state_callback(self.pa_stream, cb_pa_stream_state, self.pa_mainloop);
        c.pa_stream_set_write_callback(self.pa_stream, cb_pa_stream_request, self.pa_mainloop);

        var flags: c_uint = c.PA_STREAM_INTERPOLATE_TIMING | c.PA_STREAM_AUTO_TIMING_UPDATE;
        var buffer_attr: c.pa_buffer_attr = .{};
        var pbuffer_attr: ?*c.pa_buffer_attr = null;
        if (ms_latency > 0)
        {
            pbuffer_attr = &buffer_attr;
            buffer_attr.maxlength = @truncate(c.pa_usec_to_bytes(ms_latency * sample_spec.channels * 1000, &sample_spec));
            buffer_attr.tlength = @truncate(c.pa_usec_to_bytes(ms_latency * 1000, &sample_spec));
            buffer_attr.prebuf = 0xFFFFFFFF;
            buffer_attr.minreq = 0xFFFFFFFF;
            buffer_attr.fragsize = 0xFFFFFFFF;
            flags |= c.PA_STREAM_ADJUST_LATENCY;
        }
        const rv = c.pa_stream_connect_playback(self.pa_stream, 0, pbuffer_attr, flags, 0, null);
        try err_if(rv < 0, PulseError.PaStream);
        while (true)
        {
            const state = c.pa_stream_get_state(self.pa_stream);
            if (state == c.PA_STREAM_READY)
            {
                break;
            }
            try err_if(c.PA_STREAM_IS_GOOD(state) == 0, PulseError.PaStream);
            c.pa_threaded_mainloop_wait(self.pa_mainloop);
        }
    }

    //*************************************************************************
    pub fn stop(self: *rdp_pulse_t) !void
    {
        try self.session.logln(log.LogLevel.info, @src(), "", .{});
        if (self.pa_stream == null)
        {
            return;
        }
        c.pa_threaded_mainloop_lock(self.pa_mainloop);
        defer c.pa_threaded_mainloop_unlock(self.pa_mainloop);
        const operation = c.pa_stream_drain(self.pa_stream,
                cb_pa_pulse_stream_success, self.pa_mainloop);
        while (c.pa_operation_get_state(operation) == c.PA_OPERATION_RUNNING)
        {
            c.pa_threaded_mainloop_wait(self.pa_mainloop);
        }
    }
};

//*****************************************************************************
fn create_pa_mainloop() !*c.pa_threaded_mainloop
{
    const pa_mainloop = c.pa_threaded_mainloop_new();
    if (pa_mainloop) |apa_mainloop|
    {
        return apa_mainloop;
    }
    return PulseError.PaMainLoop;
}

//*****************************************************************************
fn create_pa_context(pa_mainloop: *c.pa_threaded_mainloop,
        name: [:0]const u8) !*c.pa_context
{
    const api = c.pa_threaded_mainloop_get_api(pa_mainloop);
    const pa_context = c.pa_context_new(api, name);
    if (pa_context) |apa_context|
    {
        return apa_context;
    }
    return PulseError.PaContext;
}

//*****************************************************************************
fn get_state_is_ready(pa_context: *c.pa_context,
        state: *c.pa_context_state_t) bool
{
    const lstate = c.pa_context_get_state(pa_context);
    state.* = lstate;
    return lstate == c.PA_CONTEXT_READY;
}

//*****************************************************************************
pub fn create(session: *rdpc_session.rdp_session_t,
        allocator: *const std.mem.Allocator, name: [:0]const u8) !*rdp_pulse_t
{
    try session.logln(log.LogLevel.info, @src(), "pulse", .{});
    const self = try allocator.create(rdp_pulse_t);
    errdefer allocator.destroy(self);
    const pa_mainloop = try create_pa_mainloop();
    errdefer c.pa_threaded_mainloop_free(pa_mainloop);
    const pa_context = try create_pa_context(pa_mainloop, name);
    errdefer c.pa_context_unref(pa_context);
    c.pa_context_set_state_callback(pa_context, cb_pa_context_state,
            pa_mainloop);
    var rv = c.pa_context_connect(pa_context, null,
            c.PA_CONTEXT_NOFLAGS, null);
    try err_if(rv != 0, PulseError.PaContextConnect);
    c.pa_threaded_mainloop_lock(pa_mainloop);
    defer c.pa_threaded_mainloop_unlock(pa_mainloop);
    rv = c.pa_threaded_mainloop_start(pa_mainloop);
    try err_if(rv < 0, PulseError.PaStart);
    var state: c.pa_context_state_t = c.PA_CONTEXT_UNCONNECTED;
    while (!get_state_is_ready(pa_context, &state))
    {
        try err_if(c.PA_CONTEXT_IS_GOOD(state) == 0, PulseError.PaStart);
        c.pa_threaded_mainloop_wait(pa_mainloop);
    }
    self.* = .{.session = session, .allocator = allocator,
            .pa_mainloop = pa_mainloop, .pa_context = pa_context};

    return self;
}

//*****************************************************************************
fn cb_pa_context_state(context: ?*c.pa_context,
        userdata: ?*anyopaque) callconv(.C) void
{
    const pa_mainloop: ?*c.pa_threaded_mainloop = @ptrCast(userdata);
    const state = c.pa_context_get_state(context);
    if ((state == c.PA_CONTEXT_READY) or
            (state == c.PA_CONTEXT_FAILED) or
            (state == c.PA_CONTEXT_TERMINATED))
    {
        c.pa_threaded_mainloop_signal(pa_mainloop, 0);
    }
}

//*****************************************************************************
fn cb_pa_pulse_stream_success(stream: ?*c.pa_stream, success: c_int,
        userdata: ?*anyopaque) callconv(.C) void
{
    _ = stream;
    _ = success;
    const pa_mainloop: ?*c.pa_threaded_mainloop = @ptrCast(userdata);
    c.pa_threaded_mainloop_signal(pa_mainloop, 0);
}

//*****************************************************************************
fn cb_pa_stream_state(stream: ?*c.pa_stream,
        userdata: ?*anyopaque) callconv(.C) void
{
    const pa_mainloop: ?*c.pa_threaded_mainloop = @ptrCast(userdata);
    const state = c.pa_stream_get_state(stream);
    if ((state == c.PA_STREAM_READY) or
            (state == c.PA_STREAM_FAILED) or
            (state == c.PA_STREAM_TERMINATED))
    {
        c.pa_threaded_mainloop_signal(pa_mainloop, 0);
    }
}

//*****************************************************************************
fn cb_pa_stream_request(stream: ?*c.pa_stream, length: usize,
        userdata: ?*anyopaque) callconv(.C) void
{
    _ = stream;
    _ = length;
    const pa_mainloop: ?*c.pa_threaded_mainloop = @ptrCast(userdata);
    c.pa_threaded_mainloop_signal(pa_mainloop, 0);
}