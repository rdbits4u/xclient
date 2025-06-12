const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");
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
    @cInclude("pulse/pulseaudio.h");
});

const PulseError = error
{
    PaMainLoop,
    PaContext,
    PaContextConnect,
    PaStart,
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
fn create_pa_context(pa_mainloop: *c.pa_threaded_mainloop) !*c.pa_context
{
    const api = c.pa_threaded_mainloop_get_api(pa_mainloop);
    const pa_context = c.pa_context_new(api, "xclient");
    if (pa_context) |apa_context|
    {
        return apa_context;
    }
    return PulseError.PaContext;
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
fn get_state_not_ready(pa_context: *c.pa_context,
        state: *c.pa_context_state_t) bool
{
    const lstate = c.pa_context_get_state(pa_context);
    state.* = lstate;
    return lstate != c.PA_CONTEXT_READY;
}

//*****************************************************************************
pub fn create(session: *rdpc_session.rdp_session_t,
        allocator: *const std.mem.Allocator) !*rdp_pulse_t
{
    try session.logln(log.LogLevel.info, @src(), "pulse", .{});
    const self = try allocator.create(rdp_pulse_t);
    errdefer allocator.destroy(self);
    const pa_mainloop = try create_pa_mainloop();
    errdefer c.pa_threaded_mainloop_free(pa_mainloop);
    const pa_context = try create_pa_context(pa_mainloop);
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
    while (get_state_not_ready(pa_context, &state))
    {
        try err_if(c.PA_CONTEXT_IS_GOOD(state) == 0, PulseError.PaStart);
        c.pa_threaded_mainloop_wait(pa_mainloop);
    }
    self.* = .{.session = session, .allocator = allocator,
            .pa_mainloop = pa_mainloop, .pa_context = pa_context};

    return self;
}
