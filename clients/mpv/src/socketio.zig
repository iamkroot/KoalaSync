/// Socket.IO Engine.IO v4 protocol codec.
///
/// EIO=4 is a thin text-based protocol layered on top of WebSocket:
///   0{...}    Engine.IO open (server → client, contains sid, ping config)
///   1         Engine.IO close
///   2         Engine.IO ping  (server → client)
///   3         Engine.IO pong  (client → server, response to ping)
///   4...      Engine.IO message — carries Socket.IO packets:
///     40      Socket.IO CONNECT (namespace /)
///     42[...] Socket.IO EVENT  (the application layer)
///
/// This module handles encoding/decoding of these packets and
/// JSON (de)serialization for Socket.IO event payloads.
const std = @import("std");

pub const PacketType = enum {
    eio_open,
    eio_ping,
    eio_pong,
    eio_close,
    sio_connect,
    sio_event,
    sio_error,
    unknown,
};

pub const Packet = struct {
    type: PacketType,
    /// For sio_event: the event name (e.g. "room_data").
    event: ?[]const u8 = null,
    /// For sio_event: the JSON payload object (raw bytes).
    data: ?[]const u8 = null,
    /// For eio_open: the raw JSON body.
    raw: ?[]const u8 = null,
};

pub const PingConfig = struct {
    ping_interval: u64 = 25000,
    ping_timeout: u64 = 20000,
};

// ── Decoding ────────────────────────────────────────────────────

/// Parse a raw WebSocket text message into a Socket.IO / EIO packet.
/// The returned Packet borrows from `raw` — do not free `raw` while
/// the Packet is in use.
pub fn decode(raw: []const u8) Packet {
    if (raw.len == 0) return .{ .type = .unknown };

    return switch (raw[0]) {
        '0' => .{ .type = .eio_open, .raw = if (raw.len > 1) raw[1..] else null },
        '1' => .{ .type = .eio_close },
        '2' => .{ .type = .eio_ping },
        '3' => .{ .type = .eio_pong },
        '4' => decodeSioMessage(raw[1..]),
        else => .{ .type = .unknown },
    };
}

fn decodeSioMessage(data: []const u8) Packet {
    if (data.len == 0) return .{ .type = .unknown };

    return switch (data[0]) {
        // 40{...} or just 40 — namespace connect/ack
        '0' => .{ .type = .sio_connect, .raw = if (data.len > 1) data[1..] else null },
        // 42["event", {...}]
        '2' => decodeSioEvent(if (data.len > 1) data[1..] else null),
        // 44{...} — error
        '4' => .{ .type = .sio_error, .raw = if (data.len > 1) data[1..] else null },
        else => .{ .type = .unknown },
    };
}

fn decodeSioEvent(json_bytes: ?[]const u8) Packet {
    const bytes = json_bytes orelse return .{ .type = .unknown };
    // Expect: ["event_name", {...}]
    // Find the event name between the first pair of quotes
    const first_quote = std.mem.indexOfScalar(u8, bytes, '"') orelse return .{ .type = .unknown };
    const rest = bytes[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return .{ .type = .unknown };
    const event_name = rest[0..second_quote];

    // Find the data object — everything after the comma and before the trailing ]
    const comma_pos = std.mem.indexOfScalarPos(u8, bytes, first_quote + 1 + second_quote + 1, ',') orelse
        return .{ .type = .sio_event, .event = event_name, .data = null };

    var data_start = comma_pos + 1;
    // Skip whitespace
    while (data_start < bytes.len and bytes[data_start] == ' ') data_start += 1;

    // Trim trailing ]
    var data_end = bytes.len;
    while (data_end > data_start and bytes[data_end - 1] == ']') data_end -= 1;
    // Also trim any trailing whitespace
    while (data_end > data_start and bytes[data_end - 1] == ' ') data_end -= 1;

    const data_slice = if (data_end > data_start) bytes[data_start..data_end] else null;

    return .{ .type = .sio_event, .event = event_name, .data = data_slice };
}

/// Parse the EIO open packet body to extract ping interval/timeout.
pub fn parsePingConfig(json_bytes: []const u8, allocator: std.mem.Allocator) PingConfig {
    var config = PingConfig{};
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return config;
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (obj.get("pingInterval")) |v| {
        config.ping_interval = switch (v) {
            .integer => |i| @intCast(@max(0, i)),
            else => config.ping_interval,
        };
    }
    if (obj.get("pingTimeout")) |v| {
        config.ping_timeout = switch (v) {
            .integer => |i| @intCast(@max(0, i)),
            else => config.ping_timeout,
        };
    }
    return config;
}

// ── Encoding ────────────────────────────────────────────────────

/// Encode a Socket.IO event packet: 42["event_name",{...}]
pub fn encodeEvent(allocator: std.mem.Allocator, event: []const u8, json_data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "42[\"{s}\",{s}]", .{ event, json_data });
}

/// Encode an event with no data: 42["event_name"]
pub fn encodeEventNoData(allocator: std.mem.Allocator, event: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "42[\"{s}\"]", .{event});
}

/// Encode the namespace connect packet.
pub fn encodeConnect() []const u8 {
    return "40";
}

/// Encode the pong response.
pub fn encodePong() []const u8 {
    return "3";
}

// ── JSON helpers ────────────────────────────────────────────────

/// Encode string as a JSON string literal with outer quotes and proper escaping.
/// Caller must free returned memory with `allocator.free()`.
pub fn encodeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var extra: usize = 2; // For outer quotes
    for (s) |ch| {
        switch (ch) {
            '"', '\\', '\n', '\r', '\t' => extra += 1,
            0...8, 11...12, 14...0x1F => extra += 5,
            else => {},
        }
    }

    var buf = try allocator.alloc(u8, s.len + extra);
    var idx: usize = 0;
    buf[idx] = '"';
    idx += 1;

    for (s) |ch| {
        switch (ch) {
            '"' => {
                buf[idx] = '\\';
                buf[idx + 1] = '"';
                idx += 2;
            },
            '\\' => {
                buf[idx] = '\\';
                buf[idx + 1] = '\\';
                idx += 2;
            },
            '\n' => {
                buf[idx] = '\\';
                buf[idx + 1] = 'n';
                idx += 2;
            },
            '\r' => {
                buf[idx] = '\\';
                buf[idx + 1] = 'r';
                idx += 2;
            },
            '\t' => {
                buf[idx] = '\\';
                buf[idx + 1] = 't';
                idx += 2;
            },
            0...8, 11...12, 14...0x1F => {
                const hex_chars = "0123456789abcdef";
                buf[idx] = '\\';
                buf[idx + 1] = 'u';
                buf[idx + 2] = '0';
                buf[idx + 3] = '0';
                buf[idx + 4] = hex_chars[(ch >> 4) & 0xF];
                buf[idx + 5] = hex_chars[ch & 0xF];
                idx += 6;
            },
            else => {
                buf[idx] = ch;
                idx += 1;
            },
        }
    }

    buf[idx] = '"';
    idx += 1;
    return buf[0..idx];
}

/// Canonical Media State snapshot parsed from room_data.
pub const MediaStateSnapshot = struct {
    current_time: f64,
    playback_state: PlaybackState,

    pub const PlaybackState = enum {
        playing,
        paused,
    };
};

/// Parse canonical mediaState object from room_data JSON payload.
/// Returns null if mediaState is null, missing, or malformed.
pub fn parseMediaState(json_bytes: []const u8, allocator: std.mem.Allocator) ?MediaStateSnapshot {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const ms_val = root.get("mediaState") orelse return null;
    const ms_obj = switch (ms_val) {
        .object => |o| o,
        else => return null,
    };

    const time_val = ms_obj.get("currentTime") orelse return null;
    const current_time: f64 = switch (time_val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };

    const state_val = ms_obj.get("playbackState") orelse return null;
    const state_str = switch (state_val) {
        .string => |s| s,
        else => return null,
    };

    const state: MediaStateSnapshot.PlaybackState = if (std.mem.eql(u8, state_str, "playing"))
        .playing
    else if (std.mem.eql(u8, state_str, "paused"))
        .paused
    else
        return null;

    return .{
        .current_time = current_time,
        .playback_state = state,
    };
}

/// Extract a string field from a JSON object blob.
/// Caller must free returned memory with `allocator.free()`.
pub fn jsonGetString(json_bytes: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

/// Extract a number field from a JSON object blob.
pub fn jsonGetNumber(json_bytes: []const u8, key: []const u8, allocator: std.mem.Allocator) ?f64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

// ── Unit tests ──────────────────────────────────────────────────

test "decode EIO packets" {
    const p_open = decode("0{\"sid\":\"abc\",\"pingInterval\":25000,\"pingTimeout\":20000}");
    try std.testing.expectEqual(PacketType.eio_open, p_open.type);

    const p_ping = decode("2");
    try std.testing.expectEqual(PacketType.eio_ping, p_ping.type);

    const p_pong = decode("3");
    try std.testing.expectEqual(PacketType.eio_pong, p_pong.type);

    const p_connect = decode("40");
    try std.testing.expectEqual(PacketType.sio_connect, p_connect.type);

    const p_event = decode("42[\"play\",{\"currentTime\":42.5,\"seq\":1}]");
    try std.testing.expectEqual(PacketType.sio_event, p_event.type);
    try std.testing.expectEqualStrings("play", p_event.event.?);
    try std.testing.expectEqualStrings("{\"currentTime\":42.5,\"seq\":1}", p_event.data.?);
}

test "encode Socket.IO events" {
    const allocator = std.testing.allocator;
    const enc = try encodeEvent(allocator, "seek", "{\"targetTime\":123.45}");
    defer allocator.free(enc);
    try std.testing.expectEqualStrings("42[\"seek\",{\"targetTime\":123.45}]", enc);
}

test "encodeJsonString escapes properly" {
    const allocator = std.testing.allocator;

    const s1 = try encodeJsonString(allocator, "simple");
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("\"simple\"", s1);

    const s2 = try encodeJsonString(allocator, "quote \" and \\ and newline \n");
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("\"quote \\\" and \\\\ and newline \\n\"", s2);
}

test "parseMediaState from room_data" {
    const allocator = std.testing.allocator;

    const playing_json = "{\"roomId\":\"test\",\"mediaState\":{\"revision\":1,\"playbackState\":\"playing\",\"currentTime\":42.5}}";
    const playing_ms = parseMediaState(playing_json, allocator);
    try std.testing.expect(playing_ms != null);
    try std.testing.expectEqual(42.5, playing_ms.?.current_time);
    try std.testing.expectEqual(MediaStateSnapshot.PlaybackState.playing, playing_ms.?.playback_state);

    const paused_json = "{\"roomId\":\"test\",\"mediaState\":{\"revision\":2,\"playbackState\":\"paused\",\"currentTime\":100}}";
    const paused_ms = parseMediaState(paused_json, allocator);
    try std.testing.expect(paused_ms != null);
    try std.testing.expectEqual(100.0, paused_ms.?.current_time);
    try std.testing.expectEqual(MediaStateSnapshot.PlaybackState.paused, paused_ms.?.playback_state);

    const null_json = "{\"roomId\":\"test\",\"mediaState\":null}";
    try std.testing.expect(parseMediaState(null_json, allocator) == null);

    const missing_json = "{\"roomId\":\"test\"}";
    try std.testing.expect(parseMediaState(missing_json, allocator) == null);
}
