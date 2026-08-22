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

/// Extract a string field from a JSON object blob.
/// Returns a slice into `json_bytes` — does not allocate.
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
