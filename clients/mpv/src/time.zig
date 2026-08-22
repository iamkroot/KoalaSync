const std = @import("std");

extern fn usleep(usec: c_uint) c_int;

pub fn milliTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(tv.usec, 1000);
}

pub fn sleepMs(ms: u64) void {
    _ = usleep(@intCast(@min(ms * 1000, std.math.maxInt(c_uint))));
}
