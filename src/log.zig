const std = @import("std");
const stdout = std.io.getStdOut();
const writer = stdout.writer();

pub const LogLevel = enum(u8)
{
    always = 0,
    err,
    warning,
    info,
    debug,
    trace,
    never,
};

const g_log_names = [_][]const u8
{
    "ALLWAYS",
    "ERROR",
    "WARNING",
    "INFO",
    "DEBUG",
    "TRACE",
    "NEVER",
};

// run time log level
var g_lv: LogLevel = LogLevel.debug;
var g_allocator: *const std.mem.Allocator = undefined;
var g_seconds_bias: i32 = 0;

const g_show_devel = false;

//*****************************************************************************
pub fn init(allocator: *const std.mem.Allocator, lv: LogLevel) !void
{
    g_allocator = allocator;
    g_lv = lv;
    const result = init_timezone();
    if (result) |_|
    {
        // ok
    }
    else |err|
    {
        std.debug.print("init_timezone failed err {}\n", .{err});
    }
}

//*****************************************************************************
fn file_exists(file_path: [:0]const u8) bool
{
    var stat_buf: std.c.Stat = undefined;
    const result = std.c.stat(file_path, &stat_buf);
    if (result == 0)
    {
        const mode = stat_buf.mode & std.c.S.IFMT;
        if (std.c.S.IFREG == mode)
        {
            return true;
        }
    }
    return false;
}

//*****************************************************************************
fn init_timezone() !void
{
    const zoneinfo = "/usr/share/zoneinfo/";
    var tz_file_path: ?[]u8 = null;
    const tz_env = std.posix.getenv("TZ");
    if (tz_env) |atz_env|
    {
        if (atz_env[0] == '/')
        {
            tz_file_path = try std.fmt.allocPrint(g_allocator.*, "{s}",
                    .{atz_env});
        }
        else
        {
            tz_file_path = try std.fmt.allocPrint(g_allocator.*, "{s}{s}",
                    .{zoneinfo, atz_env});
        }
    }
    else if (file_exists("/etc/timezone"))
    {
        const file = try std.fs.openFileAbsolute("/etc/timezone",
                .{.mode = .read_only});
        defer file.close();
        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        const buf = try g_allocator.alloc(u8, 1024);
        defer g_allocator.free(buf);
        if (try in_stream.readUntilDelimiterOrEof(buf, '\n')) |line|
        {
            tz_file_path = try std.fmt.allocPrint(g_allocator.*, "{s}{s}",
                    .{zoneinfo, line});
        }
    }
    else if (file_exists("/etc/localtime"))
    {
        tz_file_path = try std.fmt.allocPrint(g_allocator.*,
                "/etc/localtime", .{});

    }
    if (tz_file_path) |atz_file_path|
    {
        defer g_allocator.free(atz_file_path);
        const file = try std.fs.openFileAbsolute(atz_file_path,
                .{.mode = .read_only});
        defer file.close();
        var in_stream = std.io.bufferedReader(file.reader());
        var tz = try std.Tz.parse(g_allocator.*, in_stream.reader());
        defer tz.deinit();
        // time in seconds
        const now = std.time.timestamp();
        var last: ?std.tz.Transition = null;
        for (tz.transitions) |trans|
        {
            if (trans.ts > now)
            {
                break;
            }
            last = trans;
        }
        if (last) |alast|
        {
            g_seconds_bias = alast.timetype.offset;
        }
    }
}

//*****************************************************************************
pub fn deinit() void
{
}

//*****************************************************************************
pub fn logln(lv: LogLevel, src: std.builtin.SourceLocation,
        comptime fmt: []const u8, args: anytype) !void
{
    const format = "[{d:0>4.0}-{d:0>2.0}-{d:0>2.0}T{d:0>2.0}:{d:0>2.0}:{d:0>2.0}.{d:0>3.0}{c}{d:0>4.0}] [{s: <7.0}] {s}: {s}\n";
    const lv_int = @intFromEnum(lv);
    if (lv_int <= @intFromEnum(g_lv))
    {
        const alloc_buf = try std.fmt.allocPrint(g_allocator.*, fmt, args);
        defer g_allocator.free(alloc_buf);
        var dt: DateTime = undefined;
        // time in milliseconds
        const now = std.time.milliTimestamp();
        fromMilliTimestamp(now + g_seconds_bias * 1000, &dt);
        const log_name = g_log_names[lv_int];
        const sign: u8 = if (g_seconds_bias < 0) '-' else '+';
        try writer.print(format,
                .{dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
                dt.millisecond, sign, @abs(@divTrunc(g_seconds_bias, 36)),
                log_name, src.fn_name, alloc_buf});
    }
}

//*****************************************************************************
pub fn logln_devel(lv: LogLevel, src: std.builtin.SourceLocation,
        comptime fmt: []const u8, args: anytype) !void
{
    if (g_show_devel)
    {
        try logln(lv, src, fmt, args);
    }
}

const DateTime = struct
{
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};

//*****************************************************************************
fn fromMilliTimestamp(mst: i64, dt: *DateTime) void
{
    const MILLISECONDS_PER_DAY = 86400 * 1000;
    const DAYS_PER_YEAR = 365;
    const DAYS_IN_4YEARS = 1461;
    const DAYS_IN_100YEARS = 36524;
    const DAYS_IN_400YEARS = 146097;
    const DAYS_BEFORE_EPOCH = 719468;

    const mstu: u64 = @intCast(mst);
    const miliseconds_since_midnight: u64 = @rem(mstu, MILLISECONDS_PER_DAY);
    var day_n: u64 = DAYS_BEFORE_EPOCH + mstu / MILLISECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
    var year: u16 = @intCast(100 * temp);
    day_n -= DAYS_IN_100YEARS * temp + temp / 4;

    temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
    year += @intCast(temp);
    day_n -= DAYS_PER_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * day_n + 2) / 153);
    const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12)
    {
        month -= 12;
        year += 1;
    }

    dt.year = year;
    dt.month = month;
    dt.day = day;
    dt.hour = @intCast((miliseconds_since_midnight / 1000) / 3600);
    dt.minute = @intCast((miliseconds_since_midnight / 1000) % 3600 / 60);
    dt.second = @intCast((miliseconds_since_midnight / 1000) % 60);
    dt.millisecond = @intCast(miliseconds_since_midnight % 1000);
}