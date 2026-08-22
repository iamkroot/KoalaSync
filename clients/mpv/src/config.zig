/// Configuration for the KoalaSync mpv plugin.
///
/// Supports reading from:
///   1. ~/.config/mpv/script-opts/koalasync.conf (and $XDG_CONFIG_HOME / %APPDATA%)
///   2. mpv script-opts properties (e.g. --script-opts=koalasync-room=test)
///
/// Properties passed on the command line override file settings.
const std = @import("std");
const mpv = @import("mpv.zig");
const K = @import("constants.zig");
const time = @import("time.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern fn fclose(stream: *anyopaque) c_int;

pub const Config = struct {
    server: []const u8,
    room: []const u8,
    password: []const u8,
    username: []const u8,
    peer_id: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.server);
        self.allocator.free(self.room);
        self.allocator.free(self.password);
        self.allocator.free(self.username);
        self.allocator.free(self.peer_id);
    }
};

/// Read configuration from script-opts.conf and/or mpv property options.
pub fn load(handle: mpv.Handle, allocator: std.mem.Allocator) !Config {
    var server_val: ?[]const u8 = null;
    var room_val: ?[]const u8 = null;
    var password_val: ?[]const u8 = null;
    var username_val: ?[]const u8 = null;

    // 1. Try reading the config file first
    if (readConfigFile(allocator)) |file_content| {
        defer allocator.free(file_content);
        var it = std.mem.splitScalar(u8, file_content, '\n');
        while (it.next()) |raw_line| {
            const line = trim(raw_line);
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

            const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = trim(line[0..eq_pos]);
            const val = trim(line[eq_pos + 1 ..]);

            if (std.mem.eql(u8, key, "room") or std.mem.eql(u8, key, "koalasync-room") or std.mem.eql(u8, key, "koalasync_room")) {
                if (room_val) |prev| allocator.free(prev);
                room_val = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "server") or std.mem.eql(u8, key, "koalasync-server") or std.mem.eql(u8, key, "koalasync_server")) {
                if (server_val) |prev| allocator.free(prev);
                server_val = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "password") or std.mem.eql(u8, key, "koalasync-password") or std.mem.eql(u8, key, "koalasync_password")) {
                if (password_val) |prev| allocator.free(prev);
                password_val = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "username") or std.mem.eql(u8, key, "koalasync-username") or std.mem.eql(u8, key, "koalasync_username")) {
                if (username_val) |prev| allocator.free(prev);
                username_val = try allocator.dupe(u8, val);
            }
        }
    }

    // 2. Override with mpv runtime script-opts properties (e.g. from CLI --script-opts=koalasync-room=...)
    if (readOpt(handle, allocator, "koalasync-room") catch readOpt(handle, allocator, "koalasync_room") catch readOpt(handle, allocator, "room") catch null) |cli_room| {
        if (room_val) |prev| allocator.free(prev);
        room_val = cli_room;
    }
    if (readOpt(handle, allocator, "koalasync-server") catch readOpt(handle, allocator, "koalasync_server") catch readOpt(handle, allocator, "server") catch null) |cli_server| {
        if (server_val) |prev| allocator.free(prev);
        server_val = cli_server;
    }
    if (readOpt(handle, allocator, "koalasync-password") catch readOpt(handle, allocator, "koalasync_password") catch readOpt(handle, allocator, "password") catch null) |cli_password| {
        if (password_val) |prev| allocator.free(prev);
        password_val = cli_password;
    }
    if (readOpt(handle, allocator, "koalasync-username") catch readOpt(handle, allocator, "koalasync_username") catch readOpt(handle, allocator, "username") catch null) |cli_username| {
        if (username_val) |prev| allocator.free(prev);
        username_val = cli_username;
    }

    // 3. Resolve defaults
    const final_server = server_val orelse try allocator.dupe(u8, K.official_server_url);
    errdefer allocator.free(final_server);

    const final_room = room_val orelse return error.NoRoomConfigured;
    errdefer allocator.free(final_room);

    const final_password = password_val orelse try allocator.dupe(u8, "");
    errdefer allocator.free(final_password);

    const final_username = username_val orelse try allocator.dupe(u8, "mpv-user");
    errdefer allocator.free(final_username);

    // Generate a short random peer ID
    var id_buf: [8]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
    prng.random().bytes(&id_buf);
    const peer_id = try std.fmt.allocPrint(allocator, "mpv-{s}", .{std.fmt.bytesToHex(id_buf, .lower)});

    return .{
        .server = final_server,
        .room = final_room,
        .password = final_password,
        .username = final_username,
        .peer_id = peer_id,
        .allocator = allocator,
    };
}

fn readOpt(handle: mpv.Handle, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const prop_name = try std.fmt.allocPrintSentinel(allocator, "script-opts/{s}", .{name}, 0);
    defer allocator.free(prop_name);
    return mpv.getPropertyString(handle, allocator, prop_name.ptr) catch null;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    var res = s[start..end];
    if (res.len >= 2 and ((res[0] == '"' and res[res.len - 1] == '"') or (res[0] == '\'' and res[res.len - 1] == '\''))) {
        res = res[1 .. res.len - 1];
    }
    return res;
}

fn readConfigFile(allocator: std.mem.Allocator) ?[]const u8 {
    // 1. Try $XDG_CONFIG_HOME/mpv/script-opts/koalasync.conf
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        const path = std.fmt.allocPrintSentinel(allocator, "{s}/mpv/script-opts/koalasync.conf", .{std.mem.sliceTo(xdg, 0)}, 0) catch return null;
        defer allocator.free(path);
        if (readFile(allocator, path)) |content| return content;
    }
    // 2. Try $HOME/.config/mpv/script-opts/koalasync.conf
    if (getenv("HOME")) |home| {
        const path = std.fmt.allocPrintSentinel(allocator, "{s}/.config/mpv/script-opts/koalasync.conf", .{std.mem.sliceTo(home, 0)}, 0) catch return null;
        defer allocator.free(path);
        if (readFile(allocator, path)) |content| return content;

        // 3. Try $HOME/.mpv/script-opts/koalasync.conf
        const path2 = std.fmt.allocPrintSentinel(allocator, "{s}/.mpv/script-opts/koalasync.conf", .{std.mem.sliceTo(home, 0)}, 0) catch return null;
        defer allocator.free(path2);
        if (readFile(allocator, path2)) |content| return content;
    }
    // 4. Try %APPDATA%/mpv/script-opts/koalasync.conf (Windows)
    if (getenv("APPDATA")) |appdata| {
        const path = std.fmt.allocPrintSentinel(allocator, "{s}/mpv/script-opts/koalasync.conf", .{std.mem.sliceTo(appdata, 0)}, 0) catch return null;
        defer allocator.free(path);
        if (readFile(allocator, path)) |content| return content;
    }
    return null;
}

fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ?[]const u8 {
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);

    var buf = allocator.alloc(u8, 64 * 1024) catch return null;
    const n = fread(buf.ptr, 1, buf.len, f);
    if (n == 0) {
        allocator.free(buf);
        return null;
    }
    const result = allocator.realloc(buf, n) catch buf[0..n];
    return result;
}
