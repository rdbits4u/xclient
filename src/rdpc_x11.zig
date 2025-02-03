const std = @import("std");
const rdpc_session = @import("rdpc_session.zig");
const log = @import("log.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("X11/Xlib.h");
    @cInclude("librdpc.h");
});

pub const rdp_x11_t = struct
{
    session: *rdpc_session.rdp_session_t = undefined,
    allocator: *const std.mem.Allocator = undefined,
    display: *c.Display = undefined,
    fd: c_int = 0,
    screen_number: c_int = 0,
    white: c_ulong = 0,
    black: c_ulong = 0,
    screen: c_int = 0,
    depth: c_uint = 0,
    visual: *c.Visual = undefined,
    root_window: c.Window = 0,
    window: c.Window = 0,
    pixmap: c.Pixmap = 0,
    width: c_uint = 0,
    height: c_uint = 0,
    gc: c.GC = undefined,
    wm_protocols: c.Atom = 0,
    wm_delete_window: c.Atom = 0,

    //*************************************************************************
    pub fn delete(self: *rdp_x11_t) void
    {
        _ = c.XFreeGC(self.display, self.gc);
        _ = c.XFreePixmap(self.display, self.pixmap);
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }

    //*************************************************************************
    pub fn get_fds(self: *rdp_x11_t, fds: []i32, timeout: *i32) ![]i32
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "fd {}", .{self.fd});
        fds[0] = self.fd;
        _ = timeout;
        return fds[0..1];
    }

    //*************************************************************************
    fn handle_button_press(self: *rdp_x11_t, event: *c.XButtonEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_button_release(self: *rdp_x11_t, event: *c.XButtonEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_motion(self: *rdp_x11_t, event: *c.XMotionEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "x {} y {}", .{event.x, event.y});
    }

    //*************************************************************************
    fn handle_expose(self: *rdp_x11_t, event: *c.XExposeEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        const x = event.x;
        const y = event.y;
        const width: c_uint = @bitCast(event.width);
        const height: c_uint = @bitCast(event.height);
        _ = c.XCopyArea(self.display, self.pixmap, self.window, self.gc, x, y, width, height, x, y);
    }

    //*************************************************************************
    fn handle_visibility(self: *rdp_x11_t, event: *c.XVisibilityEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_configure(self: *rdp_x11_t, event: *c.XConfigureEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_client_message(self: *rdp_x11_t, event: *c.XClientMessageEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        if (event.window == self.window)
        {
            if (event.message_type == self.wm_protocols)
            {
                if (event.data.l[0] == self.wm_delete_window)
                {
                    try self.session.logln(log.LogLevel.debug, @src(), "closing window", .{});
                    const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
                    _ = try posix.write(rdpc_session.g_term[1], msg[0..4]);
                }
            }
        }
    }

    //*************************************************************************
    fn handle_event(self: *rdp_x11_t, event: *c.XEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "event {}", .{event.type});
    }

    //*************************************************************************
    pub fn check_fds(self: *rdp_x11_t) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        var event: c.XEvent = undefined;
        while (c.XPending(self.display) > 0)
        {
            try self.session.logln_devel(log.LogLevel.debug, @src(), "loop", .{});
            _ = c.XNextEvent(self.display, &event);
            switch (event.type)
            {
                c.ButtonPress => try self.handle_button_press(&event.xbutton),
                c.ButtonRelease => try self.handle_button_release(&event.xbutton),
                c.MotionNotify => try self.handle_motion(&event.xmotion),
                c.Expose => try self.handle_expose(&event.xexpose),
                c.VisibilityNotify => try self.handle_visibility(&event.xvisibility),
                c.ConfigureNotify => try self.handle_configure(&event.xconfigure),
                c.ClientMessage => try self.handle_client_message(&event.xclient),
                else => try handle_event(self, &event),
            }
        }
    }

};

//*****************************************************************************
pub fn create(session: *rdpc_session.rdp_session_t,
        allocator: *const std.mem.Allocator,
        settings: *c.rdpc_settings_t) !*rdp_x11_t
{
    const self = try allocator.create(rdp_x11_t);
    errdefer allocator.destroy(self);
    self.* = std.mem.zeroInit(rdp_x11_t, .{});
    self.session = session;
    self.allocator = allocator;
    try self.session.logln(log.LogLevel.debug, @src(), "rdp_x11_t", .{});
    self.width = @bitCast(settings.width);
    self.height = @bitCast(settings.height);
    const dis = c.XOpenDisplay(null);
    self.display = if (dis) |adis| adis else return error.Unexpected;
    self.fd = c.XConnectionNumber(self.display);
    self.screen_number = c.DefaultScreen(self.display);
    self.white = c.WhitePixel(self.display, self.screen_number);
    self.black = c.BlackPixel(self.display, self.screen_number);
    self.screen = c.DefaultScreen(self.display);
    self.depth = @bitCast(c.DefaultDepth(self.display, self.screen));
    self.visual = c.DefaultVisual(self.display, self.screen);
    self.root_window = c.DefaultRootWindow(self.display);
    self.window = c.XCreateSimpleWindow(self.display, self.root_window,
            50, 50, self.width, self.height, 0, self.black, self.white);
    _ = c.XMapWindow(self.display, self.window);
    const event_mask = c.StructureNotifyMask | c.VisibilityChangeMask |
            c.ButtonPressMask | c.ButtonReleaseMask | c.KeyPressMask |
            c.ExposureMask | c.PointerMotionMask | c.ExposureMask;
    _ = c.XSelectInput(self.display, self.window, event_mask);
    self.pixmap = c.XCreatePixmap(self.display, self.window,
            self.width, self.height, self.depth);
    var gcv: c.XGCValues = std.mem.zeroes(c.XGCValues);
    self.gc = c.XCreateGC(self.display, self.window, c.GCGraphicsExposures, &gcv);
    _ = c.XFillRectangle(self.display, self.pixmap, self.gc, 0, 0,
            self.width, self.height);
    self.wm_protocols = c.XInternAtom(self.display, "WM_PROTOCOLS", 0);
    self.wm_delete_window = c.XInternAtom(self.display, "WM_DELETE_WINDOW", 0);
    _ = c.XSetWMProtocols(self.display, self.window, &self.wm_delete_window, 1);
    _ = c.XFlush(self.display);
    return self;
}
