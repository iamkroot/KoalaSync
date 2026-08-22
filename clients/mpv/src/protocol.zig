/// KoalaSync protocol session.
///
/// Manages the relay connection lifecycle: connect, join room,
/// heartbeat, and bidirectional event translation between mpv
/// property changes and KoalaSync wire events.
const std = @import("std");
const websocket = @import("websocket.zig");
const sio = @import("socketio.zig");
const K = @import("constants.zig");
const time_mod = @import("time.zig");

pub const State = enum {
    disconnected,
    connecting,
    connected, // WebSocket open, EIO handshake done
    joined, // In a room
};

/// An action that the mpv thread should apply.
pub const MpvCommand = struct {
    action: Action,
    time: f64 = 0,
    sender_id: ?[]const u8 = null,

    pub const Action = enum {
        play,
        pause,
        seek,
        noop,
        force_sync_prepare,
        force_sync_execute,
    };
};

/// An event from mpv to send to the relay.
pub const OutgoingEvent = struct {
    kind: Kind,
    time: f64 = 0,
    paused: bool = false,

    pub const Kind = enum { play, pause, seek, heartbeat };
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    ws: ?websocket.Client = null,
    state: State = .disconnected,

    // Config
    server_host: []const u8,
    server_port: u16,
    server_path: []const u8,
    use_tls: bool,
    room_id: []const u8,
    password: []const u8,
    peer_id: []const u8,
    username: []const u8,

    // Protocol state
    seq: u32 = 0,
    ping_config: sio.PingConfig = .{},

    // Thread communication
    incoming: IncomingQueue = .{},
    outgoing: OutgoingQueue = .{},
    should_quit: bool = false,
    mutex: Mutex = .{},

    // Reconnection
    reconnect_attempts: u32 = 0,
    max_reconnect_attempts: u32 = 20,

    const Mutex = struct {
        inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
        pub fn lock(self: *Mutex) void {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
        pub fn unlock(self: *Mutex) void {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    };

    /// Thread-safe queue for commands heading to mpv.
    const IncomingQueue = struct {
        items: [64]MpvCommand = undefined,
        head: usize = 0,
        tail: usize = 0,

        fn push(self: *IncomingQueue, cmd: MpvCommand) void {
            const next = (self.tail + 1) % 64;
            if (next == self.head) return; // full, drop
            self.items[self.tail] = cmd;
            self.tail = next;
        }

        fn pop(self: *IncomingQueue) ?MpvCommand {
            if (self.head == self.tail) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % 64;
            return item;
        }
    };

    /// Thread-safe queue for events heading to the relay.
    const OutgoingQueue = struct {
        items: [64]OutgoingEvent = undefined,
        head: usize = 0,
        tail: usize = 0,

        fn push(self: *OutgoingQueue, evt: OutgoingEvent) void {
            const next = (self.tail + 1) % 64;
            if (next == self.head) return; // full, drop
            self.items[self.tail] = evt;
            self.tail = next;
        }

        fn pop(self: *OutgoingQueue) ?OutgoingEvent {
            if (self.head == self.tail) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % 64;
            return item;
        }
    };

    // ── Initialization ──────────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        server_url: []const u8,
        room_id: []const u8,
        password: []const u8,
        peer_id: []const u8,
        username: []const u8,
    ) !Session {
        // Parse URL: wss://host:port or ws://host:port
        var use_tls = true;
        var url_rest: []const u8 = server_url;

        if (std.mem.startsWith(u8, url_rest, "wss://")) {
            url_rest = url_rest[6..];
        } else if (std.mem.startsWith(u8, url_rest, "ws://")) {
            url_rest = url_rest[5..];
            use_tls = false;
        }

        // Split host:port
        var host: []const u8 = url_rest;
        var port: u16 = if (use_tls) 443 else 80;

        if (std.mem.indexOfScalar(u8, url_rest, ':')) |colon| {
            host = url_rest[0..colon];
            port = std.fmt.parseInt(u16, url_rest[colon + 1 ..], 10) catch port;
        } else if (std.mem.indexOfScalar(u8, url_rest, '/')) |slash| {
            host = url_rest[0..slash];
        }

        // Build upgrade path
        const path = try std.fmt.allocPrint(allocator,
            "/socket.io/?EIO=4&transport=websocket&token={s}&version={s}",
            .{ K.official_server_token, K.app_version },
        );

        return .{
            .allocator = allocator,
            .server_host = try allocator.dupe(u8, host),
            .server_port = port,
            .server_path = path,
            .use_tls = use_tls,
            .room_id = try allocator.dupe(u8, room_id),
            .password = try allocator.dupe(u8, password),
            .peer_id = try allocator.dupe(u8, peer_id),
            .username = try allocator.dupe(u8, username),
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.ws) |*ws| ws.deinit();
        self.allocator.free(self.server_host);
        self.allocator.free(self.server_path);
        self.allocator.free(self.room_id);
        self.allocator.free(self.password);
        self.allocator.free(self.peer_id);
        self.allocator.free(self.username);
    }

    // ── Thread-safe interface for the mpv thread ────────────────

    /// Pop the next incoming command for mpv.  Thread-safe.
    pub fn popCommand(self: *Session) ?MpvCommand {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.incoming.pop();
    }

    /// Push an outgoing event from mpv.  Thread-safe.
    pub fn pushEvent(self: *Session, evt: OutgoingEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.outgoing.push(evt);
    }

    /// Signal the network thread to shut down.  Thread-safe.
    pub fn requestQuit(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_quit = true;
    }

    fn isQuitRequested(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_quit;
    }

    // ── Network thread entry point ──────────────────────────────

    /// Main loop for the network thread.
    pub fn networkLoop(self: *Session) void {
        while (!self.isQuitRequested()) {
            self.connectAndRun() catch {};

            if (self.isQuitRequested()) break;

            // Reconnection backoff
            self.reconnect_attempts += 1;
            if (self.reconnect_attempts > self.max_reconnect_attempts) {
                break;
            }
            const delay_ms: u64 = @min(
                500 * std.math.pow(u64, 2, @min(self.reconnect_attempts, 10)),
                5000,
            );
            time_mod.sleepMs(delay_ms);
        }
    }

    fn connectAndRun(self: *Session) !void {
        self.state = .connecting;

        self.ws = websocket.Client.connect(
            self.allocator,
            self.server_host,
            self.server_port,
            self.server_path,
            self.use_tls,
        ) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };

        self.state = .connected;
        self.reconnect_attempts = 0;

        defer {
            if (self.ws) |*ws| {
                ws.deinit();
                self.ws = null;
            }
            self.state = .disconnected;
        }

        // Main read loop
        while (!self.isQuitRequested()) {
            // Send any queued outgoing events first
            self.drainOutgoing() catch break;

            // Read next message (short timeout ensures outgoing events like pause/play are drained promptly)
            var maybe_msg = (self.ws orelse break).readMessage(20) catch break;
            if (maybe_msg) |*msg| {
                defer msg.deinit(self.allocator);
                self.handleRawMessage(msg.data) catch continue;
            }
        }

        // Send leave_room before disconnecting
        self.sendLeaveRoom() catch {};
    }

    fn handleRawMessage(self: *Session, data: []const u8) !void {
        const packet = sio.decode(data);

        switch (packet.type) {
            .eio_open => {
                // Parse ping config
                if (packet.raw) |raw| {
                    self.ping_config = sio.parsePingConfig(raw, self.allocator);
                }
                // Send namespace connect
                var ws = &(self.ws orelse return error.ConnectionFailed);
                try ws.sendText(sio.encodeConnect());
            },
            .eio_ping => {
                // Respond with pong
                var ws = &(self.ws orelse return error.ConnectionFailed);
                try ws.sendText(sio.encodePong());
            },
            .sio_connect => {
                // Namespace joined — now join the room
                self.state = .connected;
                try self.sendJoinRoom();
            },
            .sio_event => {
                try self.handleEvent(packet.event orelse return, packet.data);
            },
            else => {},
        }
    }

    fn handleEvent(self: *Session, event: []const u8, data: ?[]const u8) !void {
        if (std.mem.eql(u8, event, K.events.room_data)) {
            self.state = .joined;
            // Queue a noop to signal the mpv thread we're connected
            self.mutex.lock();
            defer self.mutex.unlock();
            self.incoming.push(.{ .action = .noop });
            return;
        }

        if (std.mem.eql(u8, event, K.events.play)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.incoming.push(.{ .action = .play, .time = time });
            return;
        }

        if (std.mem.eql(u8, event, K.events.pause)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.incoming.push(.{ .action = .pause, .time = time });
            return;
        }

        if (std.mem.eql(u8, event, K.events.seek)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.incoming.push(.{ .action = .seek, .time = time });
            return;
        }

        if (std.mem.eql(u8, event, K.events.force_sync_prepare)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse (sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0) else 0;
            self.mutex.lock();
            self.incoming.push(.{ .action = .force_sync_prepare, .time = time });
            self.mutex.unlock();

            // Acknowledge prepare immediately so initiator can fire execute
            self.sendForceSyncAck() catch {};
            return;
        }

        if (std.mem.eql(u8, event, K.events.force_sync_execute)) {
            self.mutex.lock();
            self.incoming.push(.{ .action = .force_sync_execute });
            self.mutex.unlock();
            return;
        }

        if (std.mem.eql(u8, event, K.events.@"error")) {
            // Server error — will disconnect
            return;
        }
    }

    // ── Outgoing messages ───────────────────────────────────────

    fn sendJoinRoom(self: *Session) !void {
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"roomId\":\"{s}\",\"peerId\":\"{s}\",\"username\":\"{s}\"" ++
                ",\"password\":\"{s}\",\"protocolVersion\":\"{s}\"}}",
            .{ self.room_id, self.peer_id, self.username, self.password, K.protocol_version },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.join_room, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendLeaveRoom(self: *Session) !void {
        const pkt = try sio.encodeEventNoData(self.allocator, K.events.leave_room);
        defer self.allocator.free(pkt);

        if (self.ws) |*ws| ws.sendText(pkt) catch {};
    }

    fn sendForceSyncAck(self: *Session) !void {
        self.seq += 1;
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"peerId\":\"{s}\",\"seq\":{d}}}",
            .{ self.peer_id, self.seq },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.force_sync_ack, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn drainOutgoing(self: *Session) !void {
        while (true) {
            self.mutex.lock();
            const maybe_evt = self.outgoing.pop();
            self.mutex.unlock();

            const evt = maybe_evt orelse break;

            switch (evt.kind) {
                .play => try self.sendPlayPause(K.events.play, evt.time),
                .pause => try self.sendPlayPause(K.events.pause, evt.time),
                .seek => try self.sendSeek(evt.time),
                .heartbeat => try self.sendHeartbeat(evt.time, evt.paused),
            }
        }
    }

    fn sendPlayPause(self: *Session, event: []const u8, time: f64) !void {
        self.seq += 1;
        const playback_state = if (std.mem.eql(u8, event, K.events.pause)) "paused" else "playing";
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"currentTime\":{d:.3},\"playbackState\":\"{s}\",\"seq\":{d},\"actionTimestamp\":{d}}}",
            .{ time, playback_state, self.seq, time_mod.milliTimestamp() },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, event, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendSeek(self: *Session, time: f64) !void {
        self.seq += 1;
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"targetTime\":{d:.3},\"seq\":{d},\"actionTimestamp\":{d}}}",
            .{ time, self.seq, time_mod.milliTimestamp() },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.seek, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendHeartbeat(self: *Session, time: f64, paused: bool) !void {
        const playback_state = if (paused) "paused" else "playing";
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"peerId\":\"{s}\",\"username\":\"{s}\",\"currentTime\":{d:.3}" ++
                ",\"playbackState\":\"{s}\",\"status\":\"heartbeat\"}}",
            .{ self.peer_id, self.username, time, playback_state },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.peer_status, json);
        defer self.allocator.free(pkt);

        if (self.ws) |*ws| ws.sendText(pkt) catch {};
    }
};
