const std = @import("std");
const builtin = @import("builtin");
const strings = @import("strings");
const log = @import("log");
const hexdump = @import("hexdump");
const rdpc_session = @import("rdpc_session.zig");
const rdpc_x11 = @import("rdpc_x11.zig");
const net = std.net;
const posix = std.posix;

const c = rdpc_session.c;

const X11Error = rdpc_x11.X11Error;

const err_if = rdpc_x11.err_if;

pub const rdp_x11_common_t = struct
{
    allocator: *const std.mem.Allocator,
    session: *rdpc_session.rdp_session_t,
    rdp_x11: *rdpc_x11.rdp_x11_t,

    //*************************************************************************
    pub fn create(allocator: *const std.mem.Allocator,
            session: *rdpc_session.rdp_session_t,
            rdp_x11: *rdpc_x11.rdp_x11_t) !*rdp_x11_common_t
    {
        const self = try allocator.create(rdp_x11_common_t);
        self.* = .{.allocator = allocator, .session = session,
                .rdp_x11 = rdp_x11};
        return self;
    }

    //*************************************************************************
    pub fn delete(self: *rdp_x11_common_t) void
    {
        self.allocator.destroy(self);
    }

    //*************************************************************************
    // read a window property into a list
    pub fn get_window_property(self: *rdp_x11_common_t, comptime T: type,
            al: *std.ArrayList(T), window: c.Window, property: c.Atom,
            want_type: c.Atom, want_format: c_int) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(), "", .{});
        const x11 = self.rdp_x11;
        var long_offset: c_long = 0;
        const long_length: c_long = x11.max_request_size - 8;
        while (true)
        {
            var ltype: c.Atom = c.None;
            var lformat: c_int = 0;
            var lnitems: c_ulong = 0;
            var lbytes_after: c_ulong = 0;
            var lprop: ?*u8 = null;
            const rv = c.XGetWindowProperty(x11.display,
                    window, property, long_offset, long_length, c.False,
                    c.AnyPropertyType, &ltype, &lformat, &lnitems,
                    &lbytes_after, &lprop);
            try self.session.logln_devel(log.LogLevel.debug, @src(),
                    "ltype {} lformat {} nitems {} bytes_after {} prop {*}",
                    .{ltype, lformat, lnitems, lbytes_after, lprop});
            try err_if(rv != c.Success, X11Error.GetWindowProperty);
            try err_if(ltype == c.None, X11Error.GetWindowProperty);
            try err_if(lformat == 0, X11Error.GetWindowProperty);
            if (lprop) |aprop|
            {
                defer _ = c.XFree(aprop);
                if ((ltype == want_type) and (lformat == want_format))
                {
                    var slice: []T = undefined;
                    slice.ptr = @alignCast(@ptrCast(aprop));
                    slice.len = lnitems;
                    try al.appendSlice(slice);
                }
            }
            if (lbytes_after < 1)
            {
                break;
            }
            const num: c_ulong = 32;
            const dem: c_ulong = @intCast(lformat);
            const dem1 = num / dem;
            long_offset += @bitCast(lnitems / dem1);
        }
    }

    //*************************************************************************
    pub fn get_window_property_type(self: *rdp_x11_common_t,
            window: c.Window, property: c.Atom) !c.Atom
    {
        const x11 = self.rdp_x11;
        var ltype: c.Atom = c.None;
        var lformat: c_int = 0;
        var lnitems: c_ulong = 0;
        var lbytes_after: c_ulong = 0;
        var lprop: ?*u8 = null;
        const rv = c.XGetWindowProperty(x11.display,
                window, property, 0, 0, c.False,
                c.AnyPropertyType, &ltype, &lformat, &lnitems,
                &lbytes_after, &lprop);
        try err_if(rv != c.Success, X11Error.GetWindowProperty);
        try err_if(ltype == c.None, X11Error.GetWindowProperty);
        try err_if(lformat == 0, X11Error.GetWindowProperty);
        if (lprop) |aprop|
        {
            _ = c.XFree(aprop);
        }
        return ltype;
    }

};
