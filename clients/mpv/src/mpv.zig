/// Zig-friendly wrappers around the mpv C client API.
///
/// Provides safe access to mpv_wait_event, property observation,
/// property get/set, OSD messages, and logging.  All C strings
/// returned by mpv are either consumed immediately or copied into
/// the caller-supplied allocator.
const std = @import("std");
const c = @cImport(@cInclude("mpv/client.h"));

pub const Handle = *c.mpv_handle;
pub const Event = c.mpv_event;
pub const EventId = c.mpv_event_id;
pub const Format = c.mpv_format;
pub const EventProperty = c.mpv_event_property;

// ── Event loop ──────────────────────────────────────────────────

/// Block until the next mpv event or `timeout` seconds elapse.
pub fn waitEvent(handle: Handle, timeout: f64) *Event {
    return c.mpv_wait_event(handle, timeout);
}

// ── Property observation ────────────────────────────────────────

/// Start observing a property.  When it changes, mpv_wait_event
/// will deliver MPV_EVENT_PROPERTY_CHANGE with `reply_userdata`.
pub fn observeProperty(handle: Handle, userdata: u64, name: [*:0]const u8, fmt: Format) !void {
    const rc = c.mpv_observe_property(handle, userdata, name, fmt);
    if (rc < 0) return error.MpvError;
}

// ── Property getters ────────────────────────────────────

/// Get a property as a heap-allocated string.  Caller must free
/// the returned slice with `allocator.free()`.
pub fn getPropertyString(handle: Handle, allocator: std.mem.Allocator, name: [*:0]const u8) ![]const u8 {
    const raw: ?[*:0]const u8 = c.mpv_get_property_string(handle, name);
    if (raw) |ptr| {
        defer c.mpv_free(@constCast(@ptrCast(ptr)));
        return allocator.dupe(u8, std.mem.sliceTo(ptr, 0));
    }
    return error.PropertyUnavailable;
}

/// Get a property as f64 (e.g. time-pos).
pub fn getPropertyDouble(handle: Handle, name: [*:0]const u8) !f64 {
    var value: f64 = 0;
    const rc = c.mpv_get_property(handle, name, c.MPV_FORMAT_DOUBLE, @ptrCast(&value));
    if (rc < 0) return error.PropertyUnavailable;
    return value;
}

/// Get a property as bool (MPV_FORMAT_FLAG).
pub fn getPropertyFlag(handle: Handle, name: [*:0]const u8) !bool {
    var value: c_int = 0;
    const rc = c.mpv_get_property(handle, name, c.MPV_FORMAT_FLAG, @ptrCast(&value));
    if (rc < 0) return error.PropertyUnavailable;
    return value != 0;
}

// ── Property setters ────────────────────────────────────

pub fn setPropertyString(handle: Handle, name: [*:0]const u8, value: [*:0]const u8) !void {
    const rc = c.mpv_set_property_string(handle, name, value);
    if (rc < 0) return error.MpvError;
}

pub fn setPropertyDouble(handle: Handle, name: [*:0]const u8, value: f64) !void {
    var v = value;
    const rc = c.mpv_set_property(handle, name, c.MPV_FORMAT_DOUBLE, @ptrCast(&v));
    if (rc < 0) return error.MpvError;
}

pub fn setPropertyFlag(handle: Handle, name: [*:0]const u8, value: bool) !void {
    var v: c_int = if (value) 1 else 0;
    const rc = c.mpv_set_property(handle, name, c.MPV_FORMAT_FLAG, @ptrCast(&v));
    if (rc < 0) return error.MpvError;
}

// ── Commands ────────────────────────────────────────────

pub fn commandString(handle: Handle, cmd: [*:0]const u8) !void {
    const rc = c.mpv_command_string(handle, cmd);
    if (rc < 0) return error.MpvError;
}

// ── OSD ─────────────────────────────────────────────────

/// Show a transient OSD message for `duration` seconds.
pub fn osdMessage(handle: Handle, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype, duration: f64) void {
    const text = std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch return;
    defer allocator.free(text);
    const dur_str = std.fmt.allocPrintSentinel(allocator, "{d:.0}", .{duration * 1000}, 0) catch return;
    defer allocator.free(dur_str);
    var cmd = [_:null]?[*:0]const u8{ "show-text", text.ptr, dur_str.ptr, null };
    _ = c.mpv_command(handle, @ptrCast(@constCast(&cmd)));
}

// ── Logging ─────────────────────────────────────────────

/// Log an info-level message prefixed with [koalasync].
pub fn log(handle: Handle, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrintSentinel(allocator, fmt, args, 0) catch return;
    defer allocator.free(text);
    var cmd = [_:null]?[*:0]const u8{ "script-message-to", "koalasync", "log", text.ptr, null };
    _ = c.mpv_command(handle, @ptrCast(@constCast(&cmd)));
}

// ── Helpers ─────────────────────────────────────────────

pub fn clientName(handle: Handle) [*:0]const u8 {
    return c.mpv_client_name(handle);
}

pub fn errorString(err: c_int) [*:0]const u8 {
    return c.mpv_error_string(err);
}
