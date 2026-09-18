/// Configuration for the KoalaSync mpv plugin.
///
/// Supports reading from:
///   1. ~/.config/mpv/script-opts/koalasync.conf (and $XDG_CONFIG_HOME / %APPDATA%)
///   2. ~/.config/mpv/script-opts/koalasync-favorites.conf (auto-saved favorite rooms)
///   3. mpv script-opts properties (e.g. --script-opts=koalasync-room=test)
///
/// Properties passed on the command line override file settings.
const std = @import("std");
const mpv = @import("mpv.zig");
const K = @import("constants.zig");
const time = @import("time.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern fn fclose(stream: *anyopaque) c_int;

pub const FavoriteRoom = struct {
    room: []const u8,
    password: []const u8,
    label: []const u8,

    pub fn clone(self: FavoriteRoom, allocator: std.mem.Allocator) !FavoriteRoom {
        return .{
            .room = try allocator.dupe(u8, self.room),
            .password = try allocator.dupe(u8, self.password),
            .label = try allocator.dupe(u8, self.label),
        };
    }

    pub fn deinit(self: *FavoriteRoom, allocator: std.mem.Allocator) void {
        allocator.free(self.room);
        allocator.free(self.password);
        allocator.free(self.label);
    }
};

pub const Config = struct {
    server: []const u8,
    room: ?[]const u8,
    password: []const u8,
    username: []const u8,
    peer_id: []const u8,
    autojoin: bool,
    favorites: []FavoriteRoom,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.server);
        if (self.room) |r| self.allocator.free(r);
        self.allocator.free(self.password);
        self.allocator.free(self.username);
        self.allocator.free(self.peer_id);
        for (self.favorites) |fav| {
            self.allocator.free(fav.room);
            self.allocator.free(fav.password);
            self.allocator.free(fav.label);
        }
        self.allocator.free(self.favorites);
    }
};

pub const KeyType = enum {
    none,
    server,
    room,
    password,
    username,
    autojoin,
    fav_main,
    fav_password,
    fav_label,
};

pub const ParsedKey = struct {
    kind: KeyType,
    index: usize = 0,
};

pub fn parseKey(raw_key: []const u8) ParsedKey {
    var k = trim(raw_key);
    if (std.mem.startsWith(u8, k, "koalasync-")) {
        k = k[10..];
    } else if (std.mem.startsWith(u8, k, "koalasync_")) {
        k = k[10..];
    }

    if (std.mem.eql(u8, k, "server")) return .{ .kind = .server };
    if (std.mem.eql(u8, k, "room")) return .{ .kind = .room };
    if (std.mem.eql(u8, k, "password")) return .{ .kind = .password };
    if (std.mem.eql(u8, k, "username")) return .{ .kind = .username };
    if (std.mem.eql(u8, k, "autojoin")) return .{ .kind = .autojoin };

    var rest: []const u8 = "";
    if (std.mem.startsWith(u8, k, "room")) {
        rest = k[4..];
    } else if (std.mem.startsWith(u8, k, "favorite")) {
        rest = k[8..];
    } else {
        return .{ .kind = .none };
    }

    var digit_count: usize = 0;
    while (digit_count < rest.len and std.ascii.isDigit(rest[digit_count])) : (digit_count += 1) {}
    if (digit_count == 0) return .{ .kind = .none };

    const idx = std.fmt.parseInt(usize, rest[0..digit_count], 10) catch return .{ .kind = .none };
    if (idx == 0 or idx > 32) return .{ .kind = .none };

    const suffix = rest[digit_count..];
    if (suffix.len == 0) {
        return .{ .kind = .fav_main, .index = idx };
    } else if (std.mem.eql(u8, suffix, "-password") or std.mem.eql(u8, suffix, "_password")) {
        return .{ .kind = .fav_password, .index = idx };
    } else if (std.mem.eql(u8, suffix, "-label") or std.mem.eql(u8, suffix, "_label") or
        std.mem.eql(u8, suffix, "-name") or std.mem.eql(u8, suffix, "_name"))
    {
        return .{ .kind = .fav_label, .index = idx };
    }

    return .{ .kind = .none };
}

pub fn parseFavValue(allocator: std.mem.Allocator, val: []const u8) !struct { room: []const u8, pass: ?[]const u8, label: ?[]const u8 } {
    var room_part = val;
    var label_part: ?[]const u8 = null;
    var pass_part: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, val, '=')) |eq_idx| {
        room_part = val[0..eq_idx];
        label_part = val[eq_idx + 1 ..];
    }

    if (std.mem.indexOfScalar(u8, room_part, ':')) |colon_idx| {
        pass_part = room_part[colon_idx + 1 ..];
        room_part = room_part[0..colon_idx];
    }

    const trimmed_room = trim(room_part);
    if (trimmed_room.len == 0) return error.EmptyRoom;

    const room = try allocator.dupe(u8, trimmed_room);
    errdefer allocator.free(room);

    const pass = if (pass_part) |p| try allocator.dupe(u8, trim(p)) else null;
    errdefer if (pass) |p| allocator.free(p);

    const label = if (label_part) |l| blk: {
        const trimmed_l = trim(l);
        if (trimmed_l.len > 0) break :blk try allocator.dupe(u8, trimmed_l);
        break :blk null;
    } else null;

    return .{ .room = room, .pass = pass, .label = label };
}

pub fn parseBool(val: []const u8) bool {
    const v = trim(val);
    return std.ascii.eqlIgnoreCase(v, "yes") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "1") or
        std.ascii.eqlIgnoreCase(v, "on");
}

const Slot = struct {
    room: ?[]const u8 = null,
    password: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

fn processConfigContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    server_val: *?[]const u8,
    room_val: *?[]const u8,
    password_val: *?[]const u8,
    username_val: *?[]const u8,
    autojoin_val: *?bool,
    slots: []Slot,
) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq_pos]);
        const val = trim(line[eq_pos + 1 ..]);
        const key_info = parseKey(key);

        switch (key_info.kind) {
            .server => {
                if (server_val.*) |prev| allocator.free(prev);
                server_val.* = try allocator.dupe(u8, val);
            },
            .room => {
                if (room_val.*) |prev| allocator.free(prev);
                room_val.* = try allocator.dupe(u8, val);
            },
            .password => {
                if (password_val.*) |prev| allocator.free(prev);
                password_val.* = try allocator.dupe(u8, val);
            },
            .username => {
                if (username_val.*) |prev| allocator.free(prev);
                username_val.* = try allocator.dupe(u8, val);
            },
            .autojoin => {
                autojoin_val.* = parseBool(val);
            },
            .fav_main => {
                const idx = key_info.index;
                if (idx < slots.len) {
                    if (parseFavValue(allocator, val)) |parsed| {
                        if (slots[idx].room) |prev| allocator.free(prev);
                        slots[idx].room = parsed.room;
                        if (parsed.pass) |p| {
                            if (slots[idx].password) |prev| allocator.free(prev);
                            slots[idx].password = p;
                        }
                        if (parsed.label) |l| {
                            if (slots[idx].label) |prev| allocator.free(prev);
                            slots[idx].label = l;
                        }
                    } else |_| {}
                }
            },
            .fav_password => {
                const idx = key_info.index;
                if (idx < slots.len) {
                    if (slots[idx].password) |prev| allocator.free(prev);
                    slots[idx].password = try allocator.dupe(u8, val);
                }
            },
            .fav_label => {
                const idx = key_info.index;
                if (idx < slots.len) {
                    if (slots[idx].label) |prev| allocator.free(prev);
                    slots[idx].label = try allocator.dupe(u8, val);
                }
            },
            .none => {},
        }
    }
}

/// Read configuration from script-opts.conf, koalasync-favorites.conf, and runtime script-opts properties.
pub fn load(handle: mpv.Handle, allocator: std.mem.Allocator) !Config {
    var server_val: ?[]const u8 = null;
    var room_val: ?[]const u8 = null;
    var password_val: ?[]const u8 = null;
    var username_val: ?[]const u8 = null;
    var autojoin_val: ?bool = null;

    var slots = [_]Slot{.{}} ** 33;
    defer {
        for (&slots) |*slot| {
            if (slot.room) |r| allocator.free(r);
            if (slot.password) |p| allocator.free(p);
            if (slot.label) |l| allocator.free(l);
        }
    }

    // 1. Try reading the main config file
    if (readConfigFile(allocator)) |file_content| {
        defer allocator.free(file_content);
        try processConfigContent(allocator, file_content, &server_val, &room_val, &password_val, &username_val, &autojoin_val, &slots);
    }

    // 2. Try reading the auto-saved favorites companion file
    if (readFavoritesConfigFile(allocator)) |fav_content| {
        defer allocator.free(fav_content);
        try processConfigContent(allocator, fav_content, &server_val, &room_val, &password_val, &username_val, &autojoin_val, &slots);
    }

    // 3. Override with mpv runtime script-opts properties (e.g. CLI --script-opts=koalasync-room=...)
    var cli_room_specified = false;
    if (readOpt(handle, allocator, "koalasync-room") catch readOpt(handle, allocator, "koalasync_room") catch readOpt(handle, allocator, "room") catch null) |cli_room| {
        if (room_val) |prev| allocator.free(prev);
        room_val = cli_room;
        cli_room_specified = true;
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

    var cli_autojoin_specified: ?bool = null;
    if (readOpt(handle, allocator, "koalasync-autojoin") catch readOpt(handle, allocator, "koalasync_autojoin") catch readOpt(handle, allocator, "autojoin") catch null) |cli_aj| {
        defer allocator.free(cli_aj);
        cli_autojoin_specified = parseBool(cli_aj);
    }

    // Read numbered slots from CLI script-opts (1..32)
    var slot_idx: usize = 1;
    while (slot_idx <= 32) : (slot_idx += 1) {
        var key_buf: [32]u8 = undefined;

        // roomN
        const r_name = std.fmt.bufPrint(&key_buf, "koalasync-room{d}", .{slot_idx}) catch continue;
        if (readOpt(handle, allocator, r_name) catch null) |cli_val| {
            defer allocator.free(cli_val);
            if (parseFavValue(allocator, cli_val)) |parsed| {
                if (slots[slot_idx].room) |prev| allocator.free(prev);
                slots[slot_idx].room = parsed.room;
                if (parsed.pass) |p| {
                    if (slots[slot_idx].password) |prev| allocator.free(prev);
                    slots[slot_idx].password = p;
                }
                if (parsed.label) |l| {
                    if (slots[slot_idx].label) |prev| allocator.free(prev);
                    slots[slot_idx].label = l;
                }
            } else |_| {}
        }

        // roomN-password
        const rp_name = std.fmt.bufPrint(&key_buf, "koalasync-room{d}-password", .{slot_idx}) catch continue;
        if (readOpt(handle, allocator, rp_name) catch null) |cli_pass| {
            if (slots[slot_idx].password) |prev| allocator.free(prev);
            slots[slot_idx].password = cli_pass;
        }

        // roomN-label
        const rl_name = std.fmt.bufPrint(&key_buf, "koalasync-room{d}-label", .{slot_idx}) catch continue;
        if (readOpt(handle, allocator, rl_name) catch null) |cli_lbl| {
            if (slots[slot_idx].label) |prev| allocator.free(prev);
            slots[slot_idx].label = cli_lbl;
        }
    }

    // 4. Resolve defaults
    const final_server = server_val orelse try allocator.dupe(u8, K.official_server_url);
    errdefer allocator.free(final_server);

    const final_password = password_val orelse try allocator.dupe(u8, "");
    errdefer allocator.free(final_password);

    const final_username = username_val orelse try allocator.dupe(u8, "mpv-user");
    errdefer allocator.free(final_username);

    // Autojoin resolution:
    // - Explicit CLI autojoin takes highest priority
    // - If room was explicitly passed via CLI (--script-opts=koalasync-room=...), assume user intent to join
    // - Otherwise default to config file autojoin or false (Standby by default)
    const final_autojoin = if (cli_autojoin_specified) |aj|
        aj
    else if (cli_room_specified)
        true
    else
        autojoin_val orelse false;

    // Collect populated favorite rooms
    var fav_list: std.ArrayList(FavoriteRoom) = .empty;
    errdefer {
        for (fav_list.items) |fav| {
            allocator.free(fav.room);
            allocator.free(fav.password);
            allocator.free(fav.label);
        }
        fav_list.deinit(allocator);
    }

    for (slots[1..]) |*slot| {
        if (slot.room) |r| {
            const pass = if (slot.password) |p| try allocator.dupe(u8, p) else try allocator.dupe(u8, "");
            errdefer allocator.free(pass);
            const lbl = if (slot.label) |l| try allocator.dupe(u8, l) else try allocator.dupe(u8, r);
            errdefer allocator.free(lbl);
            const duped_room = try allocator.dupe(u8, r);
            errdefer allocator.free(duped_room);

            try fav_list.append(allocator, .{
                .room = duped_room,
                .password = pass,
                .label = lbl,
            });
        }
    }

    // If a primary room was set, make sure it is in favorites
    if (room_val) |r| {
        var already_in_favs = false;
        for (fav_list.items) |f| {
            if (std.mem.eql(u8, f.room, r)) {
                already_in_favs = true;
                break;
            }
        }
        if (!already_in_favs) {
            const duped_room = try allocator.dupe(u8, r);
            errdefer allocator.free(duped_room);
            const duped_pass = try allocator.dupe(u8, final_password);
            errdefer allocator.free(duped_pass);
            const duped_lbl = try allocator.dupe(u8, r);
            errdefer allocator.free(duped_lbl);

            try fav_list.insert(allocator, 0, .{
                .room = duped_room,
                .password = duped_pass,
                .label = duped_lbl,
            });
        }
    }

    // If final_room is not set but favorites exist, use first favorite as room template
    const final_room = if (room_val) |r|
        r
    else if (fav_list.items.len > 0)
        try allocator.dupe(u8, fav_list.items[0].room)
    else
        null;

    // Generate a short random peer ID (<= 16 chars for relay compatibility)
    var id_buf: [6]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
    prng.random().bytes(&id_buf);
    const peer_id = try std.fmt.allocPrint(allocator, "mpv-{s}", .{std.fmt.bytesToHex(id_buf, .lower)});

    return .{
        .server = final_server,
        .room = final_room,
        .password = final_password,
        .username = final_username,
        .peer_id = peer_id,
        .autojoin = final_autojoin,
        .favorites = try fav_list.toOwnedSlice(allocator),
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

fn getFavoritesFilePath(allocator: std.mem.Allocator) ?[:0]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/mpv/script-opts/koalasync-favorites.conf", .{std.mem.sliceTo(xdg, 0)}, 0) catch null;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/.config/mpv/script-opts/koalasync-favorites.conf", .{std.mem.sliceTo(home, 0)}, 0) catch null;
    }
    if (getenv("APPDATA")) |appdata| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/mpv/script-opts/koalasync-favorites.conf", .{std.mem.sliceTo(appdata, 0)}, 0) catch null;
    }
    return null;
}

fn readFavoritesConfigFile(allocator: std.mem.Allocator) ?[]const u8 {
    if (getFavoritesFilePath(allocator)) |path| {
        defer allocator.free(path);
        if (readFile(allocator, path)) |content| return content;
    }
    if (getenv("HOME")) |home| {
        const path2 = std.fmt.allocPrintSentinel(allocator, "{s}/.mpv/script-opts/koalasync-favorites.conf", .{std.mem.sliceTo(home, 0)}, 0) catch return null;
        defer allocator.free(path2);
        if (readFile(allocator, path2)) |content| return content;
    }
    return null;
}

/// Save favorites list to companion koalasync-favorites.conf in numbered format.
pub fn saveFavorites(allocator: std.mem.Allocator, favorites: []const FavoriteRoom) void {
    const path = getFavoritesFilePath(allocator) orelse return;
    defer allocator.free(path);
    const f = fopen(path, "wb") orelse return;
    defer _ = fclose(f);

    const header = "# KoalaSync saved favorites (auto-managed)\n";
    _ = fwrite(header.ptr, 1, header.len, f);

    for (favorites, 1..) |fav, idx| {
        var line_buf: [512]u8 = undefined;
        const line = if (fav.password.len > 0 and fav.label.len > 0 and !std.mem.eql(u8, fav.label, fav.room))
            std.fmt.bufPrint(&line_buf, "room{d}={s}:{s}={s}\n", .{ idx, fav.room, fav.password, fav.label }) catch continue
        else if (fav.password.len > 0)
            std.fmt.bufPrint(&line_buf, "room{d}={s}:{s}\n", .{ idx, fav.room, fav.password }) catch continue
        else if (fav.label.len > 0 and !std.mem.eql(u8, fav.label, fav.room))
            std.fmt.bufPrint(&line_buf, "room{d}={s}={s}\n", .{ idx, fav.room, fav.label }) catch continue
        else
            std.fmt.bufPrint(&line_buf, "room{d}={s}\n", .{ idx, fav.room }) catch continue;
        _ = fwrite(line.ptr, 1, line.len, f);
    }
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

test "parseKey identifies simple and numbered keys" {
    try std.testing.expectEqual(KeyType.server, parseKey("server").kind);
    try std.testing.expectEqual(KeyType.room, parseKey("room").kind);
    try std.testing.expectEqual(KeyType.password, parseKey("password").kind);
    try std.testing.expectEqual(KeyType.username, parseKey("username").kind);
    try std.testing.expectEqual(KeyType.autojoin, parseKey("autojoin").kind);
    try std.testing.expectEqual(KeyType.autojoin, parseKey("koalasync-autojoin").kind);
    try std.testing.expectEqual(KeyType.autojoin, parseKey("koalasync_autojoin").kind);

    const k1 = parseKey("room1");
    try std.testing.expectEqual(KeyType.fav_main, k1.kind);
    try std.testing.expectEqual(@as(usize, 1), k1.index);

    const k2 = parseKey("koalasync-room2");
    try std.testing.expectEqual(KeyType.fav_main, k2.kind);
    try std.testing.expectEqual(@as(usize, 2), k2.index);

    const k3 = parseKey("favorite3");
    try std.testing.expectEqual(KeyType.fav_main, k3.kind);
    try std.testing.expectEqual(@as(usize, 3), k3.index);

    const kp = parseKey("room1-password");
    try std.testing.expectEqual(KeyType.fav_password, kp.kind);
    try std.testing.expectEqual(@as(usize, 1), kp.index);

    const kl = parseKey("room1-label");
    try std.testing.expectEqual(KeyType.fav_label, kl.kind);
    try std.testing.expectEqual(@as(usize, 1), kl.index);

    const kn = parseKey("favorite2_name");
    try std.testing.expectEqual(KeyType.fav_label, kn.kind);
    try std.testing.expectEqual(@as(usize, 2), kn.index);
}

test "parseFavValue parses room, password, and label" {
    const allocator = std.testing.allocator;

    const res1 = try parseFavValue(allocator, "movie-night:secret=Movie Night");
    defer allocator.free(res1.room);
    defer if (res1.pass) |p| allocator.free(p);
    defer if (res1.label) |l| allocator.free(l);
    try std.testing.expectEqualStrings("movie-night", res1.room);
    try std.testing.expectEqualStrings("secret", res1.pass.?);
    try std.testing.expectEqualStrings("Movie Night", res1.label.?);

    const res2 = try parseFavValue(allocator, "anime-club=Anime Club");
    defer allocator.free(res2.room);
    defer if (res2.pass) |p| allocator.free(p);
    defer if (res2.label) |l| allocator.free(l);
    try std.testing.expectEqualStrings("anime-club", res2.room);
    try std.testing.expect(res2.pass == null);
    try std.testing.expectEqualStrings("Anime Club", res2.label.?);

    const res3 = try parseFavValue(allocator, "simple-room");
    defer allocator.free(res3.room);
    defer if (res3.pass) |p| allocator.free(p);
    defer if (res3.label) |l| allocator.free(l);
    try std.testing.expectEqualStrings("simple-room", res3.room);
    try std.testing.expect(res3.pass == null);
    try std.testing.expect(res3.label == null);
}

test "parseBool handles common boolean representations" {
    try std.testing.expect(parseBool("yes"));
    try std.testing.expect(parseBool("true"));
    try std.testing.expect(parseBool("1"));
    try std.testing.expect(parseBool("ON"));
    try std.testing.expect(!parseBool("no"));
    try std.testing.expect(!parseBool("false"));
    try std.testing.expect(!parseBool("0"));
    try std.testing.expect(!parseBool("off"));
}
