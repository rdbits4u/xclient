const std = @import("std");
const strings = @import("strings");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
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
    root_window: c.Window = c.None,
    window: c.Window = c.None,
    pixmap: c.Pixmap = c.None,
    width: c_uint = 0,
    height: c_uint = 0,
    gc: c.GC = undefined,
    net_wm_pid: c.Atom = 0,
    wm_protocols: c.Atom = 0,
    wm_delete_window: c.Atom = 0,

    //*************************************************************************
    pub fn delete(self: *rdp_x11_t) void
    {
        _ = c.XFreeGC(self.display, self.gc);
        _ = c.XFreePixmap(self.display, self.pixmap);
        if (self.window != c.None)
        {
            _ = c.XDestroyWindow(self.display, self.window);
        }
        _ = c.XCloseDisplay(self.display);
        self.allocator.destroy(self);
    }

    //*************************************************************************
    pub fn get_fds(self: *rdp_x11_t, fds: []i32, timeout: *i32) ![]i32
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "fd {}", .{self.fd});
        if (fds.len < 1)
        {
            return error.Unexpected;
        }
        fds[0] = self.fd;
        _ = timeout;
        return fds[0..1];
    }

    //*************************************************************************
    fn handle_key_press(self: *rdp_x11_t, event: *c.XKeyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_key_release(self: *rdp_x11_t, event: *c.XKeyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
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
        if (self.window == event.window)
        {
            const x = event.x;
            const y = event.y;
            const width: c_uint = @bitCast(event.width);
            const height: c_uint = @bitCast(event.height);
            _ = c.XCopyArea(self.display, self.pixmap, self.window, self.gc, x, y, width, height, x, y);
        }
    }

    //*************************************************************************
    fn handle_visibility(self: *rdp_x11_t, event: *c.XVisibilityEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_destroy(self: *rdp_x11_t, event: *c.XDestroyWindowEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        if ((self.window == event.window) and (event.event == event.window))
        {
            self.window = c.None;
            // closing main window, set term
            const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
            _ = try posix.write(rdpc_session.g_term[1], msg[0..4]);
        }
    }

    //*************************************************************************
    fn handle_unmap(self: *rdp_x11_t, event: *c.XUnmapEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_map(self: *rdp_x11_t, event: *c.XMapEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn handle_configure(self: *rdp_x11_t, event: *c.XConfigureEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        const width: c_uint = @bitCast(event.width);
        const height: c_uint = @bitCast(event.height);
        if ((self.window == event.window) and (event.event == event.window))
        {
            try self.check_pixmap(width, height);
        }
    }

    //*************************************************************************
    fn handle_client_message(self: *rdp_x11_t, event: *c.XClientMessageEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        if (self.window == event.window)
        {
            if (event.message_type == self.wm_protocols)
            {
                if (event.data.l[0] == self.wm_delete_window)
                {
                    try self.session.logln(log.LogLevel.debug, @src(), "closing window", .{});
                    _ = c.XDestroyWindow(self.display, self.window);
                }
            }
        }
    }

    //*************************************************************************
    fn handle_other(self: *rdp_x11_t, event: *c.XEvent) !void
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
                c.KeyPress => try self.handle_key_press(&event.xkey),
                c.KeyRelease => try self.handle_key_release(&event.xkey),
                c.ButtonPress => try self.handle_button_press(&event.xbutton),
                c.ButtonRelease => try self.handle_button_release(&event.xbutton),
                c.MotionNotify => try self.handle_motion(&event.xmotion),
                c.Expose => try self.handle_expose(&event.xexpose),
                c.VisibilityNotify => try self.handle_visibility(&event.xvisibility),
                c.DestroyNotify => try self.handle_destroy(&event.xdestroywindow),
                c.UnmapNotify => try self.handle_unmap(&event.xunmap),
                c.MapNotify => try self.handle_map(&event.xmap),
                c.ConfigureNotify => try self.handle_configure(&event.xconfigure),
                c.ClientMessage => try self.handle_client_message(&event.xclient),
                else => try handle_other(self, &event),
            }
        }
    }

    //*************************************************************************
    fn create_window(self: *rdp_x11_t) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        // attribs for create window
        var attribs: c.XSetWindowAttributes = .{};
        attribs.background_pixel = self.black;
        attribs.border_pixel = self.white;
        attribs.backing_store = c.NotUseful;
        attribs.override_redirect = 0;
        attribs.colormap = 0;
        attribs.bit_gravity = c.ForgetGravity;
        attribs.win_gravity = c.StaticGravity;
        // value_mask for create window
        const value_mask: c_ulong = c.CWBackPixel | c.CWBackingStore |
                c.CWOverrideRedirect | c.CWColormap | c.CWBorderPixel |
                c.CWWinGravity | c.CWBitGravity;
        // create window
        self.window = c.XCreateWindow(self.display, self.root_window,
                0, 0, self.width, self.height, 0, @bitCast(self.depth),
                c.InputOutput, self.visual, value_mask, &attribs);
        // setup WM_CLASS for window manager
        var class_hints: c.XClassHint = .{};
        var res_name: [16]u8 = undefined;
        var res_class: [16]u8 = undefined;
        strings.copyZ(&res_name, "xclient");
        strings.copyZ(&res_class, "xclient");
        class_hints.res_name = &res_name;
        class_hints.res_class = &res_class;
        _ = c.XSetClassHint(self.display, self.window, &class_hints);
        // setup _NET_WM_PID for window manager
        self.net_wm_pid = c.XInternAtom(self.display, "_NET_WM_PID", 0);
        const pid: c_long = std.os.linux.getpid();
        _ = c.XChangeProperty(self.display, self.window, self.net_wm_pid,
                c.XA_CARDINAL, 32, c.PropModeReplace,
                std.mem.asBytes(&pid), 1);
        // setup WM_PROTOCOLS for window manager
        self.wm_protocols = c.XInternAtom(self.display, "WM_PROTOCOLS", 0);
        self.wm_delete_window = c.XInternAtom(self.display, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(self.display, self.window, &self.wm_delete_window, 1);
    }

    //*************************************************************************
    // check that pixmap is created and the right size
    fn check_pixmap(self: *rdp_x11_t, width: c_uint, height: c_uint) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        if ((self.pixmap == c.None) or
                (self.width != width) or (self.height != height))
        {
            // create new pixmap
            const new_pix = c.XCreatePixmap(self.display, self.window,
                    width, height, self.depth);
            // clear new pixmap
            _ = c.XFillRectangle(self.display, new_pix, self.gc,
                    0, 0, width, height);
            if (self.pixmap == c.None)
            {
                try self.session.logln(log.LogLevel.debug, @src(),
                        "create pixmap {} {}", .{width, height});
            }
            else
            {
                try self.session.logln(log.LogLevel.debug, @src(),
                        "resize pixmap from {} {} to {} {}",
                        .{self.width, self.height, width, height});
                // copy old to new
                _ = c.XCopyArea(self.display, self.pixmap, new_pix, self.gc,
                        0, 0, width, height, 0, 0);
                // free old
                _ = c.XFreePixmap(self.display, self.pixmap);
            }
            // set new as current
            self.pixmap = new_pix;
            // update width / height
            self.width = width;
            self.height = height;
        }
    }

};

//*****************************************************************************
pub fn create(session: *rdpc_session.rdp_session_t,
        allocator: *const std.mem.Allocator,
        width: u16, height: u16) !*rdp_x11_t
{
    const self = try allocator.create(rdp_x11_t);
    errdefer allocator.destroy(self);
    self.* = .{};
    self.session = session;
    self.allocator = allocator;
    try self.session.logln(log.LogLevel.debug, @src(), "rdp_x11_t", .{});
    self.width = width;
    self.height = height;
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
    // create window
    try self.create_window();
    // window event mask
    const event_mask: c_long = c.StructureNotifyMask |
            c.VisibilityChangeMask | c.ButtonPressMask |
            c.ButtonReleaseMask | c.KeyPressMask | c.ExposureMask |
            c.PointerMotionMask | c.ExposureMask;
    _ = c.XSelectInput(self.display, self.window, event_mask);
    _ = c.XMapWindow(self.display, self.window);
    // create gc
    var gcv: c.XGCValues = .{};
    self.gc = c.XCreateGC(self.display, self.window, c.GCGraphicsExposures, &gcv);
    // pixmap
    try self.check_pixmap(self.width, self.height);
    // flush to send all requests to xserver
    _ = c.XFlush(self.display);
    return self;
}
