const std = @import("std");
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
    @cInclude("librdpc.h");
    @cInclude("pixman.h");
    @cInclude("rfxcodec_decode.h");
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
    got_xshm: bool = false,

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
        try self.session.logln(log.LogLevel.debug, @src(), "keycode {}",
                .{event.keycode});
        var keyboard_flags: u16 = 0;
        var key_code: u16 = 0;
        switch (event.keycode)
        {
            111 =>
            {
                keyboard_flags = 0x8100;
                key_code = 72;
            },
            116 =>
            {
                keyboard_flags = 0x8100;
                key_code = 80;
            },
            else =>
            {
                keyboard_flags = 0;
                key_code = 0;
            }
        }
        if (key_code != 0)
        {
            _ = c.rdpc_send_keyboard_scancode(self.session.rdpc,
                    keyboard_flags, key_code);
        }
    }

    //*************************************************************************
    fn handle_key_release(self: *rdp_x11_t, event: *c.XKeyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "keycode {}",
                .{event.keycode});
        var keyboard_flags: u16 = 0;
        var key_code: u16 = 0;
        switch (event.keycode)
        {
            111 =>
            {
                keyboard_flags = 0x0100;
                key_code = 72;
            },
            116 =>
            {
                keyboard_flags = 0x0100;
                key_code = 80;
            },
            else =>
            {
                keyboard_flags = 0;
                key_code = 0;
            }
        }
        if (key_code != 0)
        {
            _ = c.rdpc_send_keyboard_scancode(self.session.rdpc,
                    keyboard_flags, key_code);
        }
    }

    //*************************************************************************
    fn handle_button_press(self: *rdp_x11_t, event: *c.XButtonEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "x {} y {} button 0x{X}", .{event.x, event.y, event.button});
        var levent: u16 = switch (event.button)
        {
            c.Button1 => c.PTRFLAGS_BUTTON1,
            c.Button2 => c.PTRFLAGS_BUTTON3,
            c.Button3 => c.PTRFLAGS_BUTTON2,
            else => 0,
        };
        const x: u16 = @intCast(event.x);
        const y: u16 = @intCast(event.y);
        if (levent != 0)
        {
            levent |= c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 8) // back
        {
            levent = c.PTRXFLAGS_BUTTON1 | c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event_ex(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 9) // forward
        {
            levent = c.PTRXFLAGS_BUTTON2 | c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event_ex(self.session.rdpc, levent, x, y);
        }
}

    //*************************************************************************
    fn handle_button_release(self: *rdp_x11_t, event: *c.XButtonEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        var levent: u16 = switch (event.button)
        {
            c.Button1 => c.PTRFLAGS_BUTTON1,
            c.Button2 => c.PTRFLAGS_BUTTON3,
            c.Button3 => c.PTRFLAGS_BUTTON2,
            else => 0,
        };
        const x: u16 = @intCast(event.x);
        const y: u16 = @intCast(event.y);
        const delta: i16 = 120;
        if (levent != 0)
        {
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button4) // wheel up
        {
            levent = c.PTRFLAGS_WHEEL | (delta & c.WheelRotationMask);
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button5) // wheel down
        {
            const ldelta: u16 = @bitCast(-delta);
            levent = c.PTRFLAGS_WHEEL | (ldelta & c.WheelRotationMask);
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 6) // hwheel left
        {
            levent = c.PTRFLAGS_HWHEEL | (delta & c.WheelRotationMask);
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 7) // hwheel right
        {
            const ldelta: u16 = @bitCast(-delta);
            levent = c.PTRFLAGS_HWHEEL | (ldelta & c.WheelRotationMask);
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 8) // back
        {
            levent = c.PTRXFLAGS_BUTTON1;
            _ = c.rdpc_send_mouse_event_ex(self.session.rdpc, levent, x, y);
        }
        else if (event.button == 9) // forward
        {
            levent = c.PTRXFLAGS_BUTTON2;
            _ = c.rdpc_send_mouse_event_ex(self.session.rdpc, levent, x, y);
        }
    }

    //*************************************************************************
    fn handle_motion(self: *rdp_x11_t, event: *c.XMotionEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "x {} y {}", .{event.x, event.y});
        _ = c.rdpc_send_mouse_event(self.session.rdpc, c.PTRFLAGS_MOVE,
                @intCast(event.x), @intCast(event.y));
    }

    //*************************************************************************
    fn handle_expose(self: *rdp_x11_t, event: *c.XExposeEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        if (self.window == event.window)
        {
            const x = event.x;
            const y = event.y;
            const width: c_uint = @bitCast(event.width);
            const height: c_uint = @bitCast(event.height);
            try self.session.logln_devel(log.LogLevel.debug, @src(),
                    "x {} y {} width {} height {}", .{x, y, width, height});
            _ = c.XCopyArea(self.display, self.pixmap, self.window, self.gc,
                    x, y, width, height, x, y);
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
        try self.session.logln(log.LogLevel.debug, @src(),
                "width {} height {} depth {} value_mask 0x{X}",
                .{self.width, self.height, self.depth, value_mask});
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

    //*************************************************************************
    fn draw_image_noshm(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_width: c_uint, dst_height: c_uint,
            data: []u8, clips: []c.XRectangle) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "clips.len {}", .{clips.len});
        const stride_bytes: c_int = @bitCast(src_width * 4);
        if (clips.len < 1)
        {
            const image = c.XCreateImage(self.display, self.visual,
                    self.depth, c.ZPixmap, 0, data.ptr,
                    src_width, src_height, 32, stride_bytes);
            if (image) |aimage|
            {
                // draw entire image
                defer _ = c.XFree(aimage);
                _ = c.XPutImage(self.display, self.pixmap, self.gc, aimage,
                        0, 0, 0, 0, dst_width, dst_height);
                _ = c.XCopyArea(self.display, self.pixmap, self.window,
                        self.gc, 0, 0, dst_width, dst_height, 0, 0);
            }
        }
        else
        {
            for (clips) |aclip|
            {
                try self.session.logln_devel(log.LogLevel.debug, @src(),
                        "x {} y {} width {} height {}",
                        .{aclip.x, aclip.y, aclip.width, aclip.height});
                const pixmap_data: []u8 = try self.allocator.alloc(u8,
                        @as(usize, 4) * aclip.width * aclip.height);
                defer self.allocator.free(pixmap_data);
                var index: c_int = 0;
                while (index < aclip.height) : (index += 1)
                {
                    const st = (aclip.y + index) * stride_bytes + aclip.x * 4;
                    const src_start: usize = @intCast(st);
                    const src_end: usize = src_start + aclip.width * 4;
                    const dst_start: usize = @intCast(index * aclip.width * 4);
                    const dst_end: usize = dst_start + aclip.width * 4;
                    std.mem.copyForwards(u8,
                            pixmap_data[dst_start..dst_end],
                            data[src_start..src_end]);
                }
                const image = c.XCreateImage(self.display, self.visual,
                        self.depth, c.ZPixmap, 0, pixmap_data.ptr,
                        aclip.width, aclip.height, 32, aclip.width * 4);
                if (image) |aimage|
                {
                    defer _ = c.XFree(aimage);
                    _ = c.XPutImage(self.display, self.pixmap, self.gc, aimage,
                            0, 0, aclip.x, aclip.y, aclip.width, aclip.height);
                    _ = c.XCopyArea(self.display, self.pixmap, self.window,
                            self.gc, aclip.x, aclip.y,
                            aclip.width, aclip.height, aclip.x, aclip.y);
                }
            }
        }
    }

    //*************************************************************************
    fn draw_image_shm(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_width: c_uint, dst_height: c_uint,
            data: []u8, clips: []c.XRectangle) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "clips.len {}", .{clips.len});
        var shminfo: c.XShmSegmentInfo = .{};
        shminfo.shmid = self.session.shm_info.shmid;
        shminfo.shmaddr = data.ptr;
        const image = c.XShmCreateImage(self.display, self.visual,
                self.depth, c.ZPixmap, data.ptr, &shminfo,
                src_width, src_height);
        _ = c.XShmAttach(self.display, &shminfo);
        if (clips.len > 0)
        {
            _ = c.XSetClipRectangles(self.display, self.gc, 0, 0,
                    clips.ptr, @intCast(clips.len), c.Unsorted);
        }
        _ = c.XShmPutImage(self.display, self.pixmap, self.gc, image,
                0, 0, 0, 0, dst_width, dst_height, 0);
        _ = c.XSync(self.display, 0);
        _ = c.XShmDetach(self.display, &shminfo);
        _ = c.XFree(image);
        // GC still has clip for XCopyArea
        _ = c.XCopyArea(self.display, self.pixmap, self.window, self.gc,
                0, 0, dst_width, dst_height, 0, 0);
        if (clips.len > 0)
        {
            _ = c.XSetClipMask(self.display, self.gc, c.None);
        }
    }

    //*************************************************************************
    pub fn draw_image(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_width: c_uint, dst_height: c_uint,
            data: []u8, clips: []c.XRectangle) !void
    {
        if (self.got_xshm)
        {
            return self.draw_image_shm(src_width, src_height,
                    dst_width, dst_height, data, clips);
        }
        return self.draw_image_noshm(src_width, src_height,
                dst_width, dst_height, data, clips);
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
    try self.session.logln(log.LogLevel.debug, @src(),
            "rdp_x11_t width {} height {}", .{width, height});
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
            c.ButtonReleaseMask | c.KeyPressMask | c.KeyReleaseMask |
            c.ExposureMask | c.PointerMotionMask | c.ExposureMask;
    _ = c.XSelectInput(self.display, self.window, event_mask);
    _ = c.XMapWindow(self.display, self.window);
    // create gc
    var gcv: c.XGCValues = .{};
    self.gc = c.XCreateGC(self.display, self.window,
            c.GCGraphicsExposures, &gcv);
    // pixmap
    try self.check_pixmap(self.width, self.height);
    // check for Xshm
    self.got_xshm = c.XShmQueryExtension(self.display) != 0;
    try self.session.logln(log.LogLevel.debug, @src(),
            "got_xshm {}", .{self.got_xshm});
    // flush to send all requests to xserver
    _ = c.XFlush(self.display);
    return self;
}
