const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings");
const log = @import("log");
const rdpc_session = @import("rdpc_session.zig");
const rdpc_x11_clip = @import("rdpc_x11_clip.zig");
const rdpc_x11_common = @import("rdpc_x11_common.zig");
const net = std.net;
const posix = std.posix;

const c = rdpc_session.c;

pub const X11Error = error
{
    GetFds,
    BadPointerCacheIndex,
    BadOpenDisplay,
    BadClipRdr,
    GetWindowProperty,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: X11Error) !void
{
    if (b) return err else return;
}

const rdp_key_code_t = struct
{
    code: u16,
    flags: [2]u16, // down, up flags
    is_down: bool = false,
};

pub const rdp_x11_t = struct
{
    session: *rdpc_session.rdp_session_t,
    allocator: *const std.mem.Allocator,
    display: *c.Display,
    rdp_x11_common: *rdpc_x11_common.rdp_x11_common_t,
    rdp_x11_clip: *rdpc_x11_clip.rdp_x11_clip_t,
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
    net_wm_pid_atom: c.Atom = c.None,
    wm_protocols_atom: c.Atom = c.None,
    wm_delete_window_atom: c.Atom = c.None,
    clipboard_atom: c.Atom = c.None,
    timestamp_atom: c.Atom = c.None,
    targets_atom: c.Atom = c.None,
    multiple_atom: c.Atom = c.None,
    primary_atom: c.Atom = c.None,
    secondary_atom: c.Atom = c.None,
    utf8_atom: c.Atom = c.None,
    incr_atom: c.Atom = c.None,
    net_workarea: c.Atom = c.None,
    clip_property_atom: c.Atom = c.None,
    get_time_atom: c.Atom = c.None,
    got_xshm: bool = false,
    got_xfixes: bool = false,
    pointer_cache: []c_ulong = &.{},
    keymap: [256]rdp_key_code_t = undefined,
    need_keyboard_sync: bool = false,
    xfixes_event_base: i32 = 0,
    xfixes_error_base: i32 = 0,
    max_request_size: c_long = 0,
    ex_max_request_size: c_long = 0,
    resize_timer: ?*anyopaque = null,

    //*************************************************************************
    pub fn create(session: *rdpc_session.rdp_session_t,
            allocator: *const std.mem.Allocator,
            width: u16, height: u16, workarea: bool) !*rdp_x11_t
    {
        const self = try allocator.create(rdp_x11_t);
        errdefer allocator.destroy(self);
        const dis = c.XOpenDisplay(null);
        const display = if (dis) |adis| adis else return X11Error.BadOpenDisplay;
        errdefer _ = c.XCloseDisplay(display);
        const rdp_x11_common = try rdpc_x11_common.rdp_x11_common_t.create(allocator,
                session, self);
        const rdp_x11_clip = try rdpc_x11_clip.rdp_x11_clip_t.create(allocator,
                session, self);
        self.* = .{.session = session, .allocator = allocator,
                .display = display, .rdp_x11_clip = rdp_x11_clip,
                .rdp_x11_common = rdp_x11_common};
        try self.session.logln(log.LogLevel.debug, @src(),
                "rdp_x11_t width {} height {}", .{width, height});
        self.width = width;
        self.height = height;
        self.fd = c.XConnectionNumber(self.display);
        self.screen_number = c.DefaultScreen(self.display);
        self.white = c.WhitePixel(self.display, self.screen_number);
        self.black = c.BlackPixel(self.display, self.screen_number);
        self.screen = c.DefaultScreen(self.display);
        self.depth = @bitCast(c.DefaultDepth(self.display, self.screen));
        self.visual = c.DefaultVisual(self.display, self.screen);
        self.root_window = c.DefaultRootWindow(self.display);
        self.net_wm_pid_atom = c.XInternAtom(self.display, "_NET_WM_PID", c.False);
        self.wm_protocols_atom = c.XInternAtom(self.display, "WM_PROTOCOLS", c.False);
        self.wm_delete_window_atom = c.XInternAtom(self.display, "WM_DELETE_WINDOW", c.False);
        self.clipboard_atom = c.XInternAtom(self.display, "CLIPBOARD", c.False);
        self.timestamp_atom = c.XInternAtom(self.display, "TIMESTAMP", c.False);
        self.targets_atom = c.XInternAtom(self.display, "TARGETS", c.False);
        self.multiple_atom = c.XInternAtom(self.display, "MULTIPLE", c.False);
        self.primary_atom = c.XInternAtom(self.display, "PRIMARY", c.False);
        self.secondary_atom = c.XInternAtom(self.display, "SECONDARY", c.False);
        self.utf8_atom = c.XInternAtom(self.display, "UTF8_STRING", c.False);
        self.incr_atom = c.XInternAtom(self.display, "INCR", c.False);
        self.net_workarea = c.XInternAtom(self.display, "_NET_WORKAREA", c.False);

        self.clip_property_atom = c.XInternAtom(self.display, "RDPC_CLIP_PROPERTY_ATOM", c.False);
        self.get_time_atom = c.XInternAtom(self.display, "RDPC_GET_TIME_ATOM", c.False);

        if (workarea)
        {
            var long_list = try std.ArrayListUnmanaged(c_long).initCapacity(
                    self.allocator.*, 32);
            defer long_list.deinit(self.allocator.*);
            try rdp_x11_common.get_window_property(c_long, &long_list,
                    self.root_window, self.net_workarea, c.XA_CARDINAL, 32);
            if (long_list.items.len > 3)
            {
                const lx = long_list.items[0];
                const ly = long_list.items[1];
                const lwidth = long_list.items[2];
                const lheight = long_list.items[3];
                try self.session.logln(log.LogLevel.debug, @src(),
                        "workarea x {} y {} width {} height {}",
                        .{lx, ly, lwidth, lheight});
                self.width = @intCast(lwidth);
                self.height = @intCast(lheight);
            }
        }

        // create window
        try self.create_window();
        // window event mask
        const event_mask: c_long = c.StructureNotifyMask |
                c.VisibilityChangeMask | c.ButtonPressMask |
                c.ButtonReleaseMask | c.KeyPressMask | c.KeyReleaseMask |
                c.ExposureMask | c.PointerMotionMask | c.ExposureMask |
                c.FocusChangeMask | c.PropertyChangeMask;
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
        self.got_xfixes = c.XFixesQueryExtension(self.display,
                &self.xfixes_event_base, &self.xfixes_error_base) != 0;
        try self.session.logln(log.LogLevel.debug, @src(),
                "got_xfixes {}", .{self.got_xfixes});
        c.XFixesSelectSelectionInput(self.display, self.window,
                self.clipboard_atom, c.XFixesSetSelectionOwnerNotifyMask |
                c.XFixesSelectionWindowDestroyNotifyMask |
                c.XFixesSelectionClientCloseNotifyMask);
        // used to get server time
        const no_text: [4]u8 = .{0, 0, 0, 0};
        _ = c.XChangeProperty(self.display, self.window, self.get_time_atom,
                    c.XA_STRING, 8, c.PropModeAppend, &no_text, 0);

        self.max_request_size = c.XMaxRequestSize(self.display);
        try self.session.logln(log.LogLevel.debug, @src(),
                "XMaxRequestSize {}", .{self.max_request_size});
        self.ex_max_request_size = c.XExtendedMaxRequestSize(self.display);
        try self.session.logln(log.LogLevel.debug, @src(),
                "XExtendedMaxRequestSize {}", .{self.ex_max_request_size});

        // flush to send all requests to xserver
        _ = c.XFlush(self.display);

        for (0..256) |index|
        {
            self.keymap[index] = .{.code = 0, .flags = .{0, 0}};
        }
        // evdev map
        self.keymap[9] =   .{.code = 1,  .flags = .{0x0000, 0x8000}}; // Esc
        self.keymap[10] =  .{.code = 2,  .flags = .{0x0000, 0x8000}}; // 1
        self.keymap[11] =  .{.code = 3,  .flags = .{0x0000, 0x8000}}; // 2
        self.keymap[12] =  .{.code = 4,  .flags = .{0x0000, 0x8000}}; // 3
        self.keymap[13] =  .{.code = 5,  .flags = .{0x0000, 0x8000}}; // 4
        self.keymap[14] =  .{.code = 6,  .flags = .{0x0000, 0x8000}}; // 5
        self.keymap[15] =  .{.code = 7,  .flags = .{0x0000, 0x8000}}; // 6
        self.keymap[16] =  .{.code = 8,  .flags = .{0x0000, 0x8000}}; // 7
        self.keymap[17] =  .{.code = 9,  .flags = .{0x0000, 0x8000}}; // 8
        self.keymap[18] =  .{.code = 10, .flags = .{0x0000, 0x8000}}; // 9
        self.keymap[19] =  .{.code = 11, .flags = .{0x0000, 0x8000}}; // 0
        self.keymap[20] =  .{.code = 12, .flags = .{0x0000, 0x8000}}; // -
        self.keymap[21] =  .{.code = 13, .flags = .{0x0000, 0x8000}}; // =
        self.keymap[22] =  .{.code = 14, .flags = .{0x0000, 0x8000}}; // backspace
        self.keymap[23] =  .{.code = 15, .flags = .{0x0000, 0x8000}}; // Tab
        self.keymap[24] =  .{.code = 16, .flags = .{0x0000, 0x8000}}; // Q
        self.keymap[25] =  .{.code = 17, .flags = .{0x0000, 0x8000}}; // W
        self.keymap[26] =  .{.code = 18, .flags = .{0x0000, 0x8000}}; // E
        self.keymap[27] =  .{.code = 19, .flags = .{0x0000, 0x8000}}; // R
        self.keymap[28] =  .{.code = 20, .flags = .{0x0000, 0x8000}}; // T
        self.keymap[29] =  .{.code = 21, .flags = .{0x0000, 0x8000}}; // Y
        self.keymap[30] =  .{.code = 22, .flags = .{0x0000, 0x8000}}; // U
        self.keymap[31] =  .{.code = 23, .flags = .{0x0000, 0x8000}}; // I
        self.keymap[32] =  .{.code = 24, .flags = .{0x0000, 0x8000}}; // O
        self.keymap[33] =  .{.code = 25, .flags = .{0x0000, 0x8000}}; // P
        self.keymap[34] =  .{.code = 26, .flags = .{0x0000, 0x8000}}; // [
        self.keymap[35] =  .{.code = 27, .flags = .{0x0000, 0x8000}}; // ]
        self.keymap[36] =  .{.code = 28, .flags = .{0x0000, 0x8000}}; // Enter
        self.keymap[37] =  .{.code = 29, .flags = .{0x0000, 0xC000}}; // left Ctrl
        self.keymap[38] =  .{.code = 30, .flags = .{0x0000, 0x8000}}; // A
        self.keymap[39] =  .{.code = 31, .flags = .{0x0000, 0x8000}}; // S
        self.keymap[40] =  .{.code = 32, .flags = .{0x0000, 0x8000}}; // D
        self.keymap[41] =  .{.code = 33, .flags = .{0x0000, 0x8000}}; // F
        self.keymap[42] =  .{.code = 34, .flags = .{0x0000, 0x8000}}; // G
        self.keymap[43] =  .{.code = 35, .flags = .{0x0000, 0x8000}}; // H
        self.keymap[44] =  .{.code = 36, .flags = .{0x0000, 0x8000}}; // J
        self.keymap[45] =  .{.code = 37, .flags = .{0x0000, 0x8000}}; // K
        self.keymap[46] =  .{.code = 38, .flags = .{0x0000, 0x8000}}; // L
        self.keymap[47] =  .{.code = 39, .flags = .{0x0000, 0x8000}}; // ;
        self.keymap[48] =  .{.code = 40, .flags = .{0x0000, 0x8000}}; // '
        self.keymap[49] =  .{.code = 41, .flags = .{0x0000, 0x8000}}; // `
        self.keymap[50] =  .{.code = 42, .flags = .{0x0000, 0xC000}}; // left Shift
        self.keymap[51] =  .{.code = 43, .flags = .{0x0000, 0x8000}}; // \
        self.keymap[52] =  .{.code = 44, .flags = .{0x0000, 0x8000}}; // Z
        self.keymap[53] =  .{.code = 45, .flags = .{0x0000, 0x8000}}; // X
        self.keymap[54] =  .{.code = 46, .flags = .{0x0000, 0x8000}}; // C
        self.keymap[55] =  .{.code = 47, .flags = .{0x0000, 0x8000}}; // V
        self.keymap[56] =  .{.code = 48, .flags = .{0x0000, 0x8000}}; // B
        self.keymap[57] =  .{.code = 49, .flags = .{0x0000, 0x8000}}; // N
        self.keymap[58] =  .{.code = 50, .flags = .{0x0000, 0x8000}}; // M
        self.keymap[59] =  .{.code = 51, .flags = .{0x0000, 0x8000}}; // ,
        self.keymap[60] =  .{.code = 52, .flags = .{0x0000, 0x8000}}; // .
        self.keymap[61] =  .{.code = 53, .flags = .{0x0000, 0x8000}}; // /
        self.keymap[62] =  .{.code = 54, .flags = .{0x0000, 0xC000}}; // right Shift
        self.keymap[63] =  .{.code = 55, .flags = .{0x0000, 0x8000}}; // NP *
        self.keymap[64] =  .{.code = 56, .flags = .{0x0000, 0xC000}}; // left Alt
        self.keymap[65] =  .{.code = 57, .flags = .{0x0000, 0x8000}}; // Space
        self.keymap[66] =  .{.code = 58, .flags = .{0x0000, 0xC000}}; // Caps Lock
        self.keymap[67] =  .{.code = 59, .flags = .{0x0000, 0x8000}}; // F1
        self.keymap[68] =  .{.code = 60, .flags = .{0x0000, 0x8000}}; // F2
        self.keymap[69] =  .{.code = 61, .flags = .{0x0000, 0x8000}}; // F3
        self.keymap[70] =  .{.code = 62, .flags = .{0x0000, 0x8000}}; // F4
        self.keymap[71] =  .{.code = 63, .flags = .{0x0000, 0x8000}}; // F5
        self.keymap[72] =  .{.code = 64, .flags = .{0x0000, 0x8000}}; // F6
        self.keymap[73] =  .{.code = 65, .flags = .{0x0000, 0x8000}}; // F7
        self.keymap[74] =  .{.code = 66, .flags = .{0x0000, 0x8000}}; // F8
        self.keymap[75] =  .{.code = 67, .flags = .{0x0000, 0x8000}}; // F9
        self.keymap[76] =  .{.code = 68, .flags = .{0x0000, 0x8000}}; // F10
        self.keymap[77] =  .{.code = 69, .flags = .{0x0000, 0xC000}}; // Num Lock
        self.keymap[78] =  .{.code = 70, .flags = .{0x0000, 0xC000}}; // Scroll Lock
        self.keymap[79] =  .{.code = 71, .flags = .{0x0000, 0x8000}}; // NP 7
        self.keymap[80] =  .{.code = 72, .flags = .{0x0000, 0x8000}}; // NP 8
        self.keymap[81] =  .{.code = 73, .flags = .{0x0000, 0x8000}}; // NP 9
        self.keymap[82] =  .{.code = 74, .flags = .{0x0000, 0x8000}}; // NP -
        self.keymap[83] =  .{.code = 75, .flags = .{0x0000, 0x8000}}; // NP 4
        self.keymap[84] =  .{.code = 76, .flags = .{0x0000, 0x8000}}; // NP 5
        self.keymap[85] =  .{.code = 77, .flags = .{0x0000, 0x8000}}; // NP 6
        self.keymap[86] =  .{.code = 78, .flags = .{0x0000, 0x8000}}; // NP +
        self.keymap[87] =  .{.code = 79, .flags = .{0x0000, 0x8000}}; // NP 1
        self.keymap[88] =  .{.code = 80, .flags = .{0x0000, 0x8000}}; // NP 2
        self.keymap[89] =  .{.code = 81, .flags = .{0x0000, 0x8000}}; // NP 3
        self.keymap[90] =  .{.code = 82, .flags = .{0x0000, 0x8000}}; // NP 0
        self.keymap[91] =  .{.code = 83, .flags = .{0x0000, 0x8000}}; // NP .

        self.keymap[95] =  .{.code = 87, .flags = .{0x0000, 0x8000}}; // F11
        self.keymap[96] =  .{.code = 88, .flags = .{0x0000, 0x8000}}; // F12

        self.keymap[104] = .{.code = 28, .flags = .{0x0100, 0xC100}}; // KP Enter
        self.keymap[105] = .{.code = 29, .flags = .{0x0100, 0xC100}}; // right Ctrl
        self.keymap[106] = .{.code = 53, .flags = .{0x0100, 0x8100}}; // NP /

        self.keymap[108] = .{.code = 56, .flags = .{0x0100, 0xC100}}; // right Alt

        self.keymap[110] = .{.code = 71, .flags = .{0x0100, 0x8100}}; // Home
        self.keymap[111] = .{.code = 72, .flags = .{0x0100, 0x8100}}; // up arrow
        self.keymap[112] = .{.code = 73, .flags = .{0x0100, 0x8100}}; // Page Up
        self.keymap[113] = .{.code = 75, .flags = .{0x0100, 0x8100}}; // left arrow
        self.keymap[114] = .{.code = 77, .flags = .{0x0100, 0x8100}}; // right arrow
        self.keymap[115] = .{.code = 79, .flags = .{0x0100, 0x8100}}; // End
        self.keymap[116] = .{.code = 80, .flags = .{0x0100, 0x8100}}; // down arrow
        self.keymap[117] = .{.code = 81, .flags = .{0x0100, 0x8100}}; // Page Down
        self.keymap[118] = .{.code = 82, .flags = .{0x0100, 0x8100}}; // Insert
        self.keymap[119] = .{.code = 83, .flags = .{0x0100, 0x8100}}; // Delete

        self.keymap[127] = .{.code = 29, .flags = .{0x0200, 0x8200}}; // Pause

        self.keymap[134] = .{.code = 92, .flags = .{0x0100, 0x8100}}; // right Win
        self.keymap[135] = .{.code = 93, .flags = .{0x0100, 0x8100}}; // menu

        return self;
    }

    //*************************************************************************
    pub fn delete(self: *rdp_x11_t) void
    {
        self.session.timer_free(self.resize_timer);
        self.rdp_x11_clip.delete();
        for (self.pointer_cache) |cur|
        {
            if (cur != c.None)
            {
                _ = c.XFreeCursor(self.display, cur);
            }
        }
        self.allocator.free(self.pointer_cache);
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
        try err_if(fds.len < 1, X11Error.GetFds);
        fds[0] = self.fd;
        _ = timeout;
        return fds[0..1];
    }

    //*************************************************************************
    fn handle_key_press(self: *rdp_x11_t, event: *c.XKeyEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "keycode {}", .{event.keycode});
        if (self.need_keyboard_sync)
        {
            try self.send_keyboard_sync(event.state);
        }
        const keycode = event.keycode & 0xFF;
        const keyboard_flags = self.keymap[keycode].flags[0];
        const key_code = self.keymap[keycode].code;
        if (key_code != 0)
        {
            const rv = c.rdpc_send_keyboard_scancode(self.session.rdpc,
                    keyboard_flags, key_code);
            if (rv == c.LIBRDPC_ERROR_NONE)
            {
                self.keymap[keycode].is_down = true;
            }
        }
    }

    //*************************************************************************
    fn handle_key_release(self: *rdp_x11_t, event: *c.XKeyEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "keycode {}", .{event.keycode});
        const keycode = event.keycode & 0xFF;
        const keyboard_flags = self.keymap[keycode].flags[1];
        const key_code = self.keymap[keycode].code;
        if (key_code != 0)
        {
            const rv = c.rdpc_send_keyboard_scancode(self.session.rdpc,
                    keyboard_flags, key_code);
            if (rv == c.LIBRDPC_ERROR_NONE)
            {
                self.keymap[keycode].is_down = false;
            }
        }
    }

    //*************************************************************************
    fn handle_button_press(self: *rdp_x11_t, event: *c.XButtonEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "x {} y {} button 0x{X}", .{event.x, event.y, event.button});
        var levent: u16 = undefined;
        const x = u16_from_c_int(event.x);
        const y = u16_from_c_int(event.y);
        if (event.button == c.Button1)
        {
            levent = c.PTRFLAGS_BUTTON1 | c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button2)
        {
            levent = c.PTRFLAGS_BUTTON3 | c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button3)
        {
            levent = c.PTRFLAGS_BUTTON2 | c.PTRFLAGS_DOWN;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        // 4, 5, 6, and 7 are wheels handled by handle_button_release
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
        var levent: u16 = undefined;
        const x = u16_from_c_int(event.x);
        const y = u16_from_c_int(event.y);
        const delta: i16 = 60;
        if (event.button == c.Button1)
        {
            levent = c.PTRFLAGS_BUTTON1;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button2)
        {
            levent = c.PTRFLAGS_BUTTON3;
            _ = c.rdpc_send_mouse_event(self.session.rdpc, levent, x, y);
        }
        else if (event.button == c.Button3)
        {
            levent = c.PTRFLAGS_BUTTON2;
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
        const x = u16_from_c_int(event.x);
        const y = u16_from_c_int(event.y);
        _ = c.rdpc_send_mouse_event(self.session.rdpc, c.PTRFLAGS_MOVE, x, y);
    }

    //*************************************************************************
    fn handle_focus_in(self: *rdp_x11_t, event: *c.XFocusChangeEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "", .{});
        _ = event;
        // look for any down keys
        for (&self.keymap) |*akeymap|
        {
            if (akeymap.is_down)
            {
                const keyboard_flags = akeymap.flags[1];
                const key_code = akeymap.code;
                if (key_code != 0)
                {
                    const rv = c.rdpc_send_keyboard_scancode(self.session.rdpc,
                            keyboard_flags, key_code);
                    if (rv == c.LIBRDPC_ERROR_NONE)
                    {
                        akeymap.is_down = false;
                    }
                }
            }
        }
        // need to sync on next key down
        self.need_keyboard_sync = true;
    }

    //*************************************************************************
    fn handle_focus_out(self: *rdp_x11_t, event: *c.XFocusChangeEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "", .{});
        _ = event;
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
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
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
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        const width: c_uint = @bitCast(event.width);
        const height: c_uint = @bitCast(event.height);
        if ((self.window == event.window) and (event.event == event.window))
        {
            try self.check_pixmap(width, height);
            self.resize_timer = try self.session.timer_set(
                    self.resize_timer, 1000, resize_timer_fn, self);

        }
    }

    //*************************************************************************
    fn handle_client_message(self: *rdp_x11_t, event: *c.XClientMessageEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        if (self.window == event.window)
        {
            if (event.message_type == self.wm_protocols_atom)
            {
                if (event.data.l[0] == self.wm_delete_window_atom)
                {
                    try self.session.logln(log.LogLevel.debug, @src(),
                            "closing window", .{});
                    _ = c.XDestroyWindow(self.display, self.window);
                }
            }
        }
    }

    //*************************************************************************
    fn handle_other(self: *rdp_x11_t, event: *c.XEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "rdpc_x11 event {}", .{event.type});
    }

    //*************************************************************************
    pub fn check_fds(self: *rdp_x11_t) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        while (c.XPending(self.display) > 0)
        {
            try self.session.logln_devel(log.LogLevel.debug, @src(), "loop", .{});
            var event = std.mem.zeroes(c.XEvent);
            _ = c.XNextEvent(self.display, &event);
            switch (event.type)
            {
                c.KeyPress => try self.handle_key_press(&event.xkey),
                c.KeyRelease => try self.handle_key_release(&event.xkey),
                c.ButtonPress => try self.handle_button_press(&event.xbutton),
                c.ButtonRelease => try self.handle_button_release(&event.xbutton),
                c.MotionNotify => try self.handle_motion(&event.xmotion),
                c.FocusIn => try self.handle_focus_in(&event.xfocus),
                c.FocusOut => try self.handle_focus_out(&event.xfocus),
                c.Expose => try self.handle_expose(&event.xexpose),
                c.VisibilityNotify => try self.handle_visibility(&event.xvisibility),
                c.DestroyNotify => try self.handle_destroy(&event.xdestroywindow),
                c.UnmapNotify => try self.handle_unmap(&event.xunmap),
                c.MapNotify => try self.handle_map(&event.xmap),
                c.ConfigureNotify => try self.handle_configure(&event.xconfigure),
                c.ClientMessage => try self.handle_client_message(&event.xclient),
                else => try self.handle_other(&event),
            }
            try self.rdp_x11_clip.handle_clip_message(&event);
        }
    }

    //*************************************************************************
    fn send_keyboard_sync(self: *rdp_x11_t, state: c_uint) !void
    {
        var toggle_flags: u32 = 0;
        if ((state & c.LockMask) != 0)
        {
            toggle_flags |= c.TS_SYNC_CAPS_LOCK;
        }
        if ((state & c.Mod2Mask) != 0)
        {
            toggle_flags |= c.TS_SYNC_NUM_LOCK;
        }
        const rv = c.rdpc_send_keyboard_sync(self.session.rdpc, toggle_flags);
        self.need_keyboard_sync = rv != c.LIBRDPC_ERROR_NONE;
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
        const pid: c_long = std.os.linux.getpid();
        _ = c.XChangeProperty(self.display, self.window, self.net_wm_pid_atom,
                c.XA_CARDINAL, 32, c.PropModeReplace,
                std.mem.asBytes(&pid), 1);
        // setup WM_PROTOCOLS for window manager
        _ = c.XSetWMProtocols(self.display, self.window, &self.wm_delete_window_atom, 1);
    }

    //*************************************************************************
    // check that pixmap is created and the right size
    fn check_pixmap(self: *rdp_x11_t, width: c_uint, height: c_uint) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
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
    fn init_box(box: *c.XSegment, x: isize, y: isize,
            width: isize, height: isize) void
    {
        box.x1 = @intCast(x);
        box.y1 = @intCast(y);
        box.x2 = @intCast(x + @as(isize, @intCast(width)));
        box.y2 = @intCast(y + @as(isize, @intCast(height)));
    }

    //*************************************************************************
    // draw without shm, try to draw with minimum XPutImage pixels
    // interect each clip with dst and draw the non nil rects
    fn draw_image_by_clip(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_left: c_int, dst_top: c_int,
            dst_width: c_uint, dst_height: c_uint,
            data: []u8, clips: [*]c.rfx_rect, num_clips: u32,
            stride_bytes: c_int) !void
    {
        var dest_rect: c.XSegment = undefined;
        init_box(&dest_rect, dst_left, dst_top,
                @min(src_width, dst_width),
                @min(src_height, dst_height));
        var jndex: u32 = 0;
        while (jndex < num_clips) : (jndex += 1)
        {
            const clip = clips[jndex];
            try self.session.logln_devel(log.LogLevel.debug, @src(),
                    "x {} y {} width {} height {}",
                    .{clip.x, clip.y, clip.cx, clip.cy});
            var clip_rect: c.XSegment = undefined;
            init_box(&clip_rect, clip.x, clip.y, clip.cx, clip.cy);
            var draw_rect: c.XSegment = undefined;
            // intersect dest_rect and clip_rect
            draw_rect.x1 = @max(dest_rect.x1, clip_rect.x1);
            draw_rect.y1 = @max(dest_rect.y1, clip_rect.y1);
            draw_rect.x2 = @min(dest_rect.x2, clip_rect.x2);
            draw_rect.y2 = @min(dest_rect.y2, clip_rect.y2);
            if ((draw_rect.x2 > draw_rect.x1) and
                    (draw_rect.y2 > draw_rect.y1))
            {
                const draw_width: u16 = @intCast(draw_rect.x2 - draw_rect.x1);
                const draw_height: u16 = @intCast(draw_rect.y2 - draw_rect.y1);
                const pd_alloc_size: usize = @as(usize, 4) *
                        @as(usize, draw_width) * @as(usize, draw_height);
                try self.session.logln_devel(log.LogLevel.debug, @src(),
                        "draw_width {} draw_height {} pd_alloc_size {}",
                        .{draw_width, draw_height, pd_alloc_size});
                const pixmap_data: []u8 = try self.allocator.alloc(u8,
                        pd_alloc_size);
                defer self.allocator.free(pixmap_data);
                var index: c_int = 0;
                while (index < draw_height) : (index += 1)
                {
                    const lleft: i32 = draw_rect.x1 - dst_left;
                    const ltop: i32 = draw_rect.y1 - dst_top;
                    const st = (ltop + index) * stride_bytes + lleft * 4;
                    const src_start: usize = @intCast(st);
                    const src_end: usize = src_start + draw_width * 4;
                    const dst_start: usize = @intCast(index * draw_width * 4);
                    const dst_end: usize = dst_start + draw_width * 4;
                    try self.session.logln_devel(log.LogLevel.debug, @src(),
                            "dst_start {} dst_end {} src_start {} src_end {}",
                            .{dst_start, dst_end, src_start, src_end});
                    std.mem.copyForwards(u8,
                            pixmap_data[dst_start..dst_end],
                            data[src_start..src_end]);
                }
                const image = c.XCreateImage(self.display, self.visual,
                        self.depth, c.ZPixmap, 0, pixmap_data.ptr,
                        draw_width, draw_height, 32, draw_width * 4);
                if (image) |aimage|
                {
                    defer _ = c.XFree(aimage);
                    _ = c.XPutImage(self.display, self.pixmap, self.gc, aimage,
                            0, 0, draw_rect.x1, draw_rect.y1,
                            draw_width, draw_height);
                    _ = c.XCopyArea(self.display, self.pixmap, self.window,
                            self.gc, draw_rect.x1, draw_rect.y1,
                            draw_width, draw_height,
                            draw_rect.x1, draw_rect.y1);
                }
            }
        }
    }

    //*************************************************************************
    pub fn draw_image(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_left: c_int, dst_top: c_int,
            dst_width: c_uint, dst_height: c_uint,
            data: ?[*]u8, clips: ?[*]c.rfx_rect, num_clips: i32) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "num_clips {}", .{num_clips});
        const stride_bytes: c_int = @bitCast(src_width * 4);
        if (num_clips < 1)
        {
            const image = c.XCreateImage(self.display, self.visual,
                    self.depth, c.ZPixmap, 0, data,
                    src_width, src_height, 32, stride_bytes);
            if (image) |aimage|
            {
                // draw entire image
                defer _ = c.XFree(aimage);
                _ = c.XPutImage(self.display, self.pixmap, self.gc, aimage,
                        0, 0, dst_left, dst_top, dst_width, dst_height);
                _ = c.XCopyArea(self.display, self.pixmap, self.window,
                        self.gc, dst_left, dst_top, dst_width, dst_height,
                        dst_left, dst_top);
            }
        }
        else
        {
            if (clips) |aclips|
            {
                if (data) |adata|
                {
                    var ldata: []u8 = undefined;
                    ldata.ptr = adata;
                    ldata.len = @as(u32, @intCast(stride_bytes)) * src_height;
                    try self.draw_image_by_clip(src_width, src_height,
                            dst_left, dst_top, dst_width, dst_height,
                            ldata, aclips, @bitCast(num_clips), stride_bytes);
                }
            }
        }
    }

    //*************************************************************************
    pub fn draw_image_shm(self: *rdp_x11_t,
            src_width: c_uint, src_height: c_uint,
            dst_left: c_int, dst_top: c_int,
            dst_width: c_uint, dst_height: c_uint,
            shmid: c_int, shmaddr: ?[*]u8,
            clips: ?[*]c.rfx_rect, num_clips: i32) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "num_clips {}", .{num_clips});
        var shminfo: c.XShmSegmentInfo = .{};
        shminfo.shmid = shmid;
        shminfo.shmaddr = shmaddr;
        const image = c.XShmCreateImage(self.display, self.visual,
                self.depth, c.ZPixmap, shmaddr, &shminfo,
                src_width, src_height);
        _ = c.XShmAttach(self.display, &shminfo);
        if (num_clips > 0)
        {
            if (clips) |aclips|
            {
                // copy aclips to lclips
                const clips_t = std.ArrayListUnmanaged(c.XRectangle);
                var lclips = try clips_t.initCapacity(self.allocator.*, 32);
                defer lclips.deinit(self.allocator.*);
                var index: usize = 0;
                while (index < num_clips) : (index += 1)
                {
                    var clip: c.XRectangle = .{};
                    clip.x = @intCast(aclips[index].x);
                    clip.y = @intCast(aclips[index].y);
                    clip.width = @intCast(aclips[index].cx);
                    clip.height = @intCast(aclips[index].cy);
                    try lclips.append(self.allocator.*, clip);
                }
                _ = c.XSetClipRectangles(self.display, self.gc, 0, 0,
                        lclips.items.ptr, num_clips, c.Unsorted);
            }
        }
        _ = c.XShmPutImage(self.display, self.pixmap, self.gc, image,
                0, 0, dst_left, dst_top, dst_width, dst_height, 0);
        _ = c.XSync(self.display, 0);
        _ = c.XShmDetach(self.display, &shminfo);
        _ = c.XFree(image);
        // GC still has clip for XCopyArea
        _ = c.XCopyArea(self.display, self.pixmap, self.window, self.gc,
                dst_left, dst_top, dst_width, dst_height, dst_left, dst_top);
        if (num_clips > 0)
        {
            _ = c.XSetClipMask(self.display, self.gc, c.None);
        }
    }

    //*************************************************************************
    fn get_pointer_pixel(self: *rdp_x11_t, data: []const u8, bpp: u16,
            width: u32, height: u32, x: usize, y: usize) !c_uint
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "bpp {} width {} height {} x {} y {}",
                .{bpp, width, height, x, y});
        if (bpp == 32)
        {
            const offset = y * width * 4 + x * 4;
            var pixel: u32 = data[offset + 3];
            pixel = (pixel << 8) | data[offset + 2];
            pixel = (pixel << 8) | data[offset + 1];
            pixel = (pixel << 8) | data[offset];
            return pixel;
        }
        else if (bpp == 24)
        {
            const offset = y * width * 3 + x * 3;
            var pixel: u32 = data[offset];
            pixel = (pixel << 8) | data[offset + 1];
            pixel = (pixel << 8) | data[offset + 2];
            return pixel | 0xFF000000;
        }
        else if (bpp == 16)
        {
            const offset = y * width * 2 + x * 2;
            var pixel: u32 = data[offset + 1];
            pixel = (pixel << 8) | data[offset];
            var r = (pixel & 0xF800) >> 11;
            var g = (pixel & 0x07E0) >> 5;
            var b = pixel * 0x001F;
            r = (r << 3) | (r >> 2);
            g = (g << 2) | (g >> 4);
            b = (b << 3) | (b >> 2);
            return (r << 16) | (g << 8) | b | 0xFF000000;
        }
        else if (bpp == 15)
        {
            const offset = y * width * 2 + x * 2;
            var pixel: u32 = data[offset + 1];
            pixel = (pixel << 8) | data[offset];
            var r = (pixel & 0x7C00) >> 10;
            var g = (pixel & 0x3E0) >> 5;
            var b = pixel * 0x001F;
            r = (r << 3) | (r >> 2);
            g = (g << 3) | (g >> 2);
            b = (b << 3) | (b >> 2);
            return (r << 16) | (g << 8) | b | 0xFF000000;
        }
        else if (bpp == 1)
        {
            const lwidth = (width + 7) / 8;
            const start = (y * lwidth) + x / 8;
            var shift = x % 8;
            var pixel: u32 = data[start];
            var mask: u32 = 0x80;
            while (shift > 0) : (shift -= 1) mask >>= 1;
            pixel = if ((pixel & mask) != 0) 0xFFFFFFFF else 0xFF000000;
            return pixel;
        }
        return 0;
    }

    //*************************************************************************
    pub fn pointer_update(self: *rdp_x11_t, pointer: *c.pointer_t) !void
    {
        // _ = self;
        // _ = pointer;
        try self.session.logln_devel(log.LogLevel.debug, @src(), "xor_bpp {}",
                .{pointer.xor_bpp});
        if (self.pointer_cache.len < 1)
        {
            const cpointer = &self.session.rdpc.ccaps.pointer;
            const pointer_cache_size = @max(cpointer.colorPointerCacheSize,
                    cpointer.pointerCacheSize);
            if (pointer_cache_size > 0)
            {
                self.pointer_cache = try self.allocator.alloc(c_ulong,
                        pointer_cache_size);
                @memset(self.pointer_cache, c.None);
            }
            try self.session.logln_devel(log.LogLevel.debug, @src(),
                    "pointer_cache_size {}", .{pointer_cache_size});
        }
        var ci: c.XcursorImage = .{};
        ci.version = c.XCURSOR_IMAGE_VERSION;
        ci.size = @sizeOf(c.XcursorImage);
        ci.width = pointer.width;
        ci.height = pointer.height;
        ci.xhot = pointer.hotx;
        ci.yhot = pointer.hoty;
        const pixels = try self.allocator.alloc(c_uint, ci.width * ci.height);
        defer self.allocator.free(pixels);
        ci.pixels = pixels.ptr;
        if (pointer.xor_mask_data) |axor_data|
        {
            var xor_data: []const u8 = undefined;
            xor_data.ptr = @ptrCast(axor_data);
            xor_data.len = pointer.length_xor_mask;
            if (pointer.and_mask_data) |aand_data|
            {
                const bpp = if (pointer.xor_bpp == 0) 24 else pointer.xor_bpp;
                const w = pointer.width;
                const h = pointer.height;
                var and_data: []const u8 = undefined;
                and_data.ptr = @ptrCast(aand_data);
                and_data.len = pointer.length_and_mask;
                for (0..h) |y|
                {
                    const yup = (h - 1) - y;
                    for (0..w) |x|
                    {
                        const apixel = try self.get_pointer_pixel(
                                and_data, 1, w, h, x, yup);
                        var xpixel = try self.get_pointer_pixel(
                                xor_data, bpp, w, h, x, yup);
                        try self.session.logln_devel(log.LogLevel.debug,
                                @src(), "apixel 0x{X} xpixel 0x{X}",
                                .{apixel, xpixel});
                        if ((apixel & 0xFFFFFF) != 0)
                        {
                            if ((xpixel & 0xFFFFFF) == 0xFFFFFF)
                            {
                                // use pattern (not solid black) for xor area
                                xpixel = if ((x & 1) == (y & 1)) 0xFFFFFFFF
                                        else 0xFF000000;
                            }
                            else if (xpixel == 0xFF000000)
                            {
                                xpixel = 0;
                            }
                        }
                        pixels[w * y + x] = xpixel;
                    }
                }
            }
        }
        const cur = c.XcursorImageLoadCursor(self.display, &ci);
        _ = c.XDefineCursor(self.display, self.window, cur);
        try err_if(pointer.cache_index >= self.pointer_cache.len,
                X11Error.BadPointerCacheIndex);
        self.pointer_cache[pointer.cache_index] = cur;
    }

    //*************************************************************************
    pub fn pointer_cached(self: *rdp_x11_t, cache_index: u16) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "cache_index {}", .{cache_index});
        try err_if(cache_index >= self.pointer_cache.len,
                X11Error.BadPointerCacheIndex);
        _ = c.XDefineCursor(self.display, self.window,
                self.pointer_cache[cache_index]);
    }

};

//*****************************************************************************
fn u16_from_c_int(in: c_int) u16
{
    const max = std.math.maxInt(u16);
    const val = if (in < 0) 0 else if (in > max) max else in;
    return @intCast(val);
}

//*****************************************************************************
fn resize_timer_fn(user: ?*anyopaque) !void
{
    const self: *rdp_x11_t = @alignCast(@ptrCast(user));
    try self.session.logln(log.LogLevel.debug, @src(), "width {} height {}",
            .{self.width, self.height});
    //const width = self.width ;
    //const height = self.height;
    //try self.session.resize_desktop(width, height);
}