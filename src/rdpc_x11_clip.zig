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

const clip_state = enum
{
    idle,
    send_requested_data, // cliprdr_send_data_request called
    send_format_list, // cliprdr_send_format_list called
    incr_notify,
    incr_request,
};

pub const cliprdr_format_t = struct
{
    allocator: *const std.mem.Allocator,
    format_id: u32 = 0,
    format_name: []u8 = &.{},

    //*************************************************************************
    fn create(allocator: *const std.mem.Allocator) !*cliprdr_format_t
    {
        const self = try allocator.create(cliprdr_format_t);
        self.* = .{.allocator = allocator};
        return self;
    }

    //*************************************************************************
    fn create_from_format(allocator: *const std.mem.Allocator,
            format: *c.cliprdr_format_t) !*cliprdr_format_t
    {
        const self = try allocator.create(cliprdr_format_t);
        self.* = .{.allocator = allocator,
                .format_id = format.format_id};
        if (format.format_name_bytes > 0)
        {
            if (format.format_name) |aformat_name|
            {
                var lslice: []u8 = undefined;
                lslice.ptr = @ptrCast(aformat_name);
                lslice.len = format.format_name_bytes;
                self.format_name = try self.allocator.alloc(u8,
                        format.format_name_bytes);
                std.mem.copyForwards(u8, self.format_name, lslice);
            }
        }
        return self;
    }

    //*************************************************************************
    fn delete(self: *cliprdr_format_t) void
    {
        self.allocator.free(self.format_name);
        self.allocator.destroy(self);
    }

};

const cliprdr_formats_t = std.ArrayListUnmanaged(*cliprdr_format_t);

pub const rdp_x11_clip_t = struct
{
    allocator: *const std.mem.Allocator,
    session: *rdpc_session.rdp_session_t,
    rdp_x11: *rdpc_x11.rdp_x11_t,
    formats: cliprdr_formats_t,
    server_time: c.Time = 0,
    client_time: i64 = 0,

    state: clip_state = clip_state.idle,
    channel_id: u16 = 0,
    selection_req_event: c.XSelectionRequestEvent = .{},
    requested_format: u16 = 0,
    requested_target: c.Atom = c.None,

    // INCR
    incr_notify_property: c.Atom = c.None,
    incr_notify_target: c.Atom = c.None,
    incr_notify_window: c.Window = c.None,

    incr_request_property: c.Atom = c.None,
    incr_request_target: c.Atom = c.None,
    incr_request_window: c.Window = c.None,

    //*************************************************************************
    pub fn create(allocator: *const std.mem.Allocator,
            session: *rdpc_session.rdp_session_t,
            rdp_x11: *rdpc_x11.rdp_x11_t) !*rdp_x11_clip_t
    {
        const self = try allocator.create(rdp_x11_clip_t);
        const formats: cliprdr_formats_t = .{};
        self.* = .{.allocator = allocator, .session = session,
                .rdp_x11 = rdp_x11, .formats = formats};
        return self;
    }

    //*************************************************************************
    pub fn delete(self: *rdp_x11_clip_t) void
    {
        for (self.formats.items) |acliprdr_format|
        {
            acliprdr_format.delete();
        }
        self.formats.deinit(self.allocator.*);
        self.allocator.destroy(self);
    }

    //*************************************************************************
    pub fn cliprdr_ready(self: *rdp_x11_clip_t, channel_id: u16,
            version: u32, general_flags: u32) !void
    {
        self.channel_id = channel_id;
        _ = version;
        _ = general_flags;
    }

    //*************************************************************************
    pub fn cliprdr_format_list(self: *rdp_x11_clip_t, channel_id: u16,
            msg_flags: u16, num_formats: u32,
            formats: [*]c.cliprdr_format_t) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "channel_id 0x{X} msg_flags {}", .{channel_id, msg_flags});
        _ = c.cliprdr_send_format_list_response(self.session.cliprdr,
                channel_id, c.CB_RESPONSE_OK);
        // clear formats
        for (self.formats.items) |acliprdr_format|
        {
            acliprdr_format.delete();
        }
        self.formats.clearRetainingCapacity();
        // copy, check formats
        var format_ok = false;
        for (0..num_formats) |index|
        {
            const format = &formats[index];
            try self.session.logln(log.LogLevel.debug, @src(),
                    "index {} format_id {} format_name_bytes {}",
                    .{index, format.format_id, format.format_name_bytes});
            const cliprdr_format = try cliprdr_format_t.create_from_format(
                    self.allocator, format);
            errdefer cliprdr_format.delete();
            const aformat = try self.formats.addOne(self.allocator.*);
            aformat.* = cliprdr_format;
            if (format.format_id == c.CF_UNICODETEXT)
            {
                format_ok = true;
            }
        }
        if (format_ok)
        {
            const x11 = self.rdp_x11;
            _ = c.XSetSelectionOwner(x11.display, x11.clipboard_atom,
                    x11.window, c.CurrentTime);
        }
    }

    //*************************************************************************
    pub fn cliprdr_format_list_response(self: *rdp_x11_clip_t, channel_id: u16,
            msg_flags: u16) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "channel_id {} msg_flags {}", .{channel_id, msg_flags});
        if (self.state != clip_state.send_format_list)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "bad state {}, should be send_format_list",
                    .{self.state});
            return;
        }
        self.state = clip_state.idle;
    }

    //*************************************************************************
    pub fn cliprdr_data_request(self: *rdp_x11_clip_t, channel_id: u16,
            requested_format_id: u32) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "channel_id {} requested_format_id {}",
                .{channel_id, requested_format_id});
        const x11 = self.rdp_x11;
        if (requested_format_id == c.CF_UNICODETEXT)
        {
            _ = c.XConvertSelection(x11.display, x11.clipboard_atom,
                    x11.utf8_atom, x11.clip_property_atom, x11.window,
                    c.CurrentTime);
        }
    }

    //*************************************************************************
    pub fn cliprdr_data_response(self: *rdp_x11_clip_t, channel_id: u16,
            msg_flags: u16, requested_format_data: ?*anyopaque,
            requested_format_data_bytes: u32) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "channel_id {} msg_flags {}", .{channel_id, msg_flags});
        if (self.state != clip_state.send_requested_data)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "bad state {}, should be send_requested_data",
                    .{self.state});
            return;
        }
        self.state = clip_state.idle;
        if (msg_flags == c.CB_RESPONSE_OK)
        {
            if ((self.requested_format == c.CF_UNICODETEXT) and
                (self.requested_target == self.rdp_x11.utf8_atom))
            {
                var utf16_as_u8: []u8 = undefined;
                utf16_as_u8.ptr = @ptrCast(requested_format_data);
                utf16_as_u8.len = requested_format_data_bytes;
                var al: std.ArrayListUnmanaged(u32) = .{};
                defer al.deinit(self.allocator.*);
                try strings.utf16_as_u8_to_u32_array(self.allocator,
                        utf16_as_u8, &al);
                var utf8 = try self.allocator.alloc(u8, al.items.len * 4 + 1);
                defer self.allocator.free(utf8);
                var len: usize = 0;
                try strings.u32_array_to_utf8Z(&al, utf8, &len);
                try self.provide_selection(&self.selection_req_event,
                        self.selection_req_event.target, 8,
                        &utf8[0], @truncate(len));
                return;
            }
        }
        try self.refuse_selection(&self.selection_req_event);
    }

    //*************************************************************************
    fn handle_property_notify(self: *rdp_x11_clip_t,
                event: *c.XPropertyEvent) !void
    {
        //const x11 = self.rdp_x11;
        self.server_time = event.time;
        self.client_time = std.time.milliTimestamp();
        if ((self.state == clip_state.incr_notify) and
                (event.window == self.incr_notify_window) and
                (event.atom == self.incr_notify_property) and
                (event.state == c.PropertyNewValue))
        {
        }
        if ((self.state == clip_state.incr_request) and
                (event.window == self.incr_request_window) and
                (event.atom == self.incr_request_property) and
                (event.state == c.PropertyDelete))
        {
        }
    }

    //*************************************************************************
    fn handle_selection_clear(self: *rdp_x11_clip_t,
            event: *c.XSelectionClearEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        _ = event;
    }

    //*************************************************************************
    fn provide_selection(self: *rdp_x11_clip_t,
            event: *c.XSelectionRequestEvent, type1: c.Atom, format: i32,
            data: *u8, count: u32) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "requestor {}",
                .{event.requestor});
        const x11 = self.rdp_x11;
        _ = c.XChangeProperty(x11.display, event.requestor, event.property,
                type1, format, c.PropModeReplace, data, @bitCast(count));
        var xev = std.mem.zeroes(c.XEvent);
        xev.xselection.type = c.SelectionNotify;
        xev.xselection.send_event = c.True;
        xev.xselection.display = event.display;
        xev.xselection.requestor = event.requestor;
        xev.xselection.selection = event.selection;
        xev.xselection.target = event.target;
        xev.xselection.property = event.property;
        xev.xselection.time = event.time;
        _ = c.XSendEvent(x11.display, event.requestor, c.False,
                c.NoEventMask, &xev);
    }

    //*************************************************************************
    fn refuse_selection(self: *rdp_x11_clip_t,
            event: *c.XSelectionRequestEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "requestor {}",
                .{event.requestor});
        const x11 = self.rdp_x11;
        var xev = std.mem.zeroes(c.XEvent);
        xev.xselection.type = c.SelectionNotify;
        xev.xselection.send_event = c.True;
        xev.xselection.display = event.display;
        xev.xselection.requestor = event.requestor;
        xev.xselection.selection = event.selection;
        xev.xselection.target = event.target;
        xev.xselection.property = c.None;
        xev.xselection.time = event.time;
        _ = c.XSendEvent(x11.display, event.requestor, c.False,
                c.NoEventMask, &xev);
    }

    //*************************************************************************
    fn clipboard_find_format_id(self: *rdp_x11_clip_t, format_id: u32) bool
    {
        for (self.formats.items) |aformat|
        {
            if (aformat.format_id == format_id)
            {
                return true;
            }
        }
        return false;
    }

    //*************************************************************************
    fn handle_selection_request(self: *rdp_x11_clip_t,
            event: *c.XSelectionRequestEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        const x11 = self.rdp_x11;
        if (event.property == c.None)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "property is None", .{});
            return;
        }
        if (event.target == x11.targets_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is targets_atom", .{});
            var atom_buf: [16]c.Atom = undefined;
            atom_buf[0] = x11.targets_atom;
            atom_buf[1] = x11.timestamp_atom;
            atom_buf[2] = x11.multiple_atom;
            var atom_count: u32 = 3;
            if (self.clipboard_find_format_id(c.CF_UNICODETEXT))
            {
                atom_buf[atom_count] = x11.utf8_atom;
                atom_count += 1;
            }
            atom_buf[atom_count] = 0;
            const ptr: *u8 = @ptrCast(&atom_buf[0]);
            return self.provide_selection(event, c.XA_ATOM, 32,
                    ptr, atom_count);
        }
        if (event.target == x11.timestamp_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is timestamp_atom", .{});
            return;
        }
        if (event.target == x11.multiple_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is multiple_atom", .{});
            return;
        }
        if (event.target == x11.utf8_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is utf8_atom", .{});
            if (self.state != clip_state.idle)
            {
                try self.session.logln(log.LogLevel.debug, @src(),
                        "bad state {}, should be idle", .{self.state});
                return;
            }
            self.state = clip_state.send_requested_data;
            self.selection_req_event = event.*;
            self.requested_format = c.CF_UNICODETEXT;
            self.requested_target = x11.utf8_atom;
            _ = c.cliprdr_send_data_request(self.session.cliprdr,
                    self.channel_id, c.CF_UNICODETEXT);
            return;
        }
        try self.session.logln(log.LogLevel.debug, @src(),
                "target is other", .{});
    }

    //*************************************************************************
    fn process_target_targets(self: *rdp_x11_clip_t, targets: []c.Atom) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        const x11 = self.rdp_x11;
        var al: std.ArrayListUnmanaged(c.cliprdr_format_t) = .{};
        defer al.deinit(self.allocator.*);
        for (targets) |atom|
        {
            if (atom == x11.utf8_atom)
            {
                var format = try al.addOne(self.allocator.*);
                format.* = .{};
                format.format_id = c.CF_UNICODETEXT;
            }
        }
        if (al.items.len > 0)
        {
            if (self.state != clip_state.idle)
            {
                try self.session.logln(log.LogLevel.debug, @src(),
                        "bad state {}, should be idle", .{self.state});
                return;
            }
            self.state = clip_state.send_format_list;
            const rv = c.cliprdr_send_format_list(self.session.cliprdr,
                self.channel_id, 0, @truncate(al.items.len), &al.items[0]);
            _ = rv;
        }
    }

    //*************************************************************************
    fn process_target_utf8(self: *rdp_x11_clip_t, utf8: []u8) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        var al: std.ArrayListUnmanaged(u32) = .{};
        defer al.deinit(self.allocator.*);
        try strings.utf8_to_u32_array(self.allocator, utf8, &al);
        const utf16_as_u8 = try self.allocator.alloc(u8,
                (al.items.len + 16) * 4);
        defer self.allocator.free(utf16_as_u8);
        var bytes_written_out: usize = 0;
        try strings.u32_array_to_utf16Z_as_u8(&al, utf16_as_u8,
                &bytes_written_out);
        try self.session.logln(log.LogLevel.debug, @src(),
                "utf8 length {} utf16 length {}",
                .{utf8.len, bytes_written_out});
        _ = c.cliprdr_send_data_response(self.session.cliprdr,
                self.channel_id, c.CB_RESPONSE_OK,
                utf16_as_u8.ptr, @truncate(bytes_written_out));
    }
    
    //*************************************************************************
    fn handle_selection_notify(self: *rdp_x11_clip_t,
            event: *c.XSelectionEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(), "", .{});
        const x11 = self.rdp_x11;
        const com = x11.rdp_x11_common;
        if (event.property == c.None)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "property is None", .{});
            return;
        }
        const prop_type = try
                com.get_window_property_type(event.requestor, event.property);
        if (prop_type == x11.incr_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(), "INCR", .{});
            _ = c.XDeleteProperty(x11.display, event.requestor,
                    event.property);
            if (self.state != clip_state.idle)
            {
                try self.session.logln(log.LogLevel.debug, @src(),
                        "bad state {}, should be idle", .{self.state});
                return;
            }
            self.incr_notify_property = event.property;
            self.incr_notify_target = event.target;
            self.incr_notify_window = x11.window;
            self.state = clip_state.incr_notify;
            // nothing more to do here, the data is coming in through
            // PropertyNotify
            return;
        }
        if (event.target == x11.targets_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is targets_atom", .{});
            var atom_list: std.ArrayListUnmanaged(c.Atom) = .{};
            defer atom_list.deinit(self.allocator.*);
            try com.get_window_property(c.Atom, &atom_list,
                    event.requestor, event.property, c.XA_ATOM, 32);
            _ = c.XDeleteProperty(x11.display, event.requestor,
                    event.property);
            return self.process_target_targets(atom_list.items);
        }
        if (event.target == x11.utf8_atom)
        {
            try self.session.logln(log.LogLevel.debug, @src(),
                    "target is utf8_atom", .{});
            var utf8_list: std.ArrayListUnmanaged(u8) = .{};
            defer utf8_list.deinit(self.allocator.*);
            try com.get_window_property(u8, &utf8_list,
                    event.requestor, event.property, x11.utf8_atom, 8);
            _ = c.XDeleteProperty(x11.display, event.requestor,
                    event.property);
            return self.process_target_utf8(utf8_list.items);
        }
        try self.session.logln(log.LogLevel.debug, @src(),
                "unhandled target is {}", .{event.target});
    }

    //*************************************************************************
    // xfixes
    fn handle_selection_set_owner(self: *rdp_x11_clip_t,
            event: *c.XFixesSelectionNotifyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "owner 0x{X} subtype {}", .{event.owner, event.subtype});
        const x11 = self.rdp_x11;
        if (event.owner == x11.window)
        {
            return;
        }
        if (event.owner != c.None)
        {
            _ = c.XConvertSelection(x11.display, x11.clipboard_atom,
                    x11.targets_atom, x11.clip_property_atom,
                    x11.window, event.timestamp);
        }
    }

    //*************************************************************************
    // xfixes
    fn handle_selection_window_destory(self: *rdp_x11_clip_t,
            event: *c.XFixesSelectionNotifyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "owner 0x{X} subtype {}", .{event.owner, event.subtype});
    }

    //*************************************************************************
    // xfixes
    fn handle_selection_client_close(self: *rdp_x11_clip_t,
            event: *c.XFixesSelectionNotifyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "owner 0x{X} subtype {}", .{event.owner, event.subtype});
    }

    //*************************************************************************
    // xfixes
    fn handle_selection_other(self: *rdp_x11_clip_t,
            event: *c.XFixesSelectionNotifyEvent) !void
    {
        try self.session.logln(log.LogLevel.debug, @src(),
                "owner 0x{X} subtype {}", .{event.owner, event.subtype});
    }

    //*************************************************************************
    fn handle_other(self: *rdp_x11_clip_t, event: *c.XEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "rdpc_x11_clip event {}", .{event.type});
        const base = self.rdp_x11.xfixes_event_base;
        if ((base > 0) and (event.type == base + c.XFixesSelectionNotify))
        {
            const levent: *c.XFixesSelectionNotifyEvent = @ptrCast(event);
            try switch (levent.subtype)
            {
                c.XFixesSetSelectionOwnerNotify => self.handle_selection_set_owner(levent),
                c.XFixesSelectionWindowDestroyNotify => self.handle_selection_window_destory(levent),
                c.XFixesSelectionClientCloseNotify => self.handle_selection_client_close(levent),
                else => self.handle_selection_other(levent),
            };
        }
    }

    //*************************************************************************
    pub fn handle_clip_message(self: *rdp_x11_clip_t, event: *c.XEvent) !void
    {
        try self.session.logln_devel(log.LogLevel.debug, @src(),
                "rdpc_x11_clip: event {}", .{event.type});
        try switch (event.type)
        {
            c.PropertyNotify => self.handle_property_notify(&event.xproperty),
            c.SelectionClear => self.handle_selection_clear(&event.xselectionclear),
            c.SelectionRequest => self.handle_selection_request(&event.xselectionrequest),
            c.SelectionNotify => self.handle_selection_notify(&event.xselection),
            else => self.handle_other(event),
        };
    }

};
