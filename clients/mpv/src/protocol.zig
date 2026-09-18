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
    playback_state: ?PlaybackState = null,
    text_buf: [128]u8 = [_]u8{0} ** 128,
    text_len: u8 = 0,

    pub const Action = enum {
        play,
        pause,
        seek,
        noop,
        force_sync_prepare,
        force_sync_execute,
        initial_sync,
        control_mode_changed,
        error_msg,
    };

    pub const PlaybackState = enum {
        playing,
        paused,
    };

    pub fn text(self: *const MpvCommand) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn setText(self: *MpvCommand, str: []const u8) void {
        const len = @min(str.len, self.text_buf.len);
        @memcpy(self.text_buf[0..len], str[0..len]);
        self.text_len = @intCast(len);
    }
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
    media_title: ?[]u8 = null,

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
        if (self.media_title) |mt| self.allocator.free(mt);
    }

    /// Update the current media title. Thread-safe.
    pub fn setMediaTitle(self: *Session, title: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.media_title) |old| self.allocator.free(old);
        if (title.len == 0) {
            self.media_title = null;
        } else {
            self.media_title = self.allocator.dupe(u8, title) catch null;
        }
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

            var maybe_ms: ?sio.MediaStateSnapshot = null;
            if (data) |d| {
                maybe_ms = sio.parseMediaState(d, self.allocator);
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            if (maybe_ms) |ms| {
                self.incoming.push(.{
                    .action = .initial_sync,
                    .time = ms.current_time,
                    .playback_state = switch (ms.playback_state) {
                        .playing => .playing,
                        .paused => .paused,
                    },
                });
            } else {
                self.incoming.push(.{ .action = .noop });
            }
            return;
        }

        if (std.mem.eql(u8, event, K.events.play)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            self.incoming.push(.{ .action = .play, .time = time });
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.pause)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            self.incoming.push(.{ .action = .pause, .time = time });
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.seek)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse 0 else 0;
            self.mutex.lock();
            self.incoming.push(.{ .action = .seek, .time = time });
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.force_sync_prepare)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse (sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0) else 0;
            self.mutex.lock();
            self.incoming.push(.{ .action = .force_sync_prepare, .time = time });
            self.mutex.unlock();

            // Acknowledge prepare immediately so initiator can fire execute
            self.sendForceSyncAck() catch {};
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.force_sync_execute)) {
            self.mutex.lock();
            self.incoming.push(.{ .action = .force_sync_execute });
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.ping)) {
            if (data) |d| {
                const t = sio.jsonGetNumber(d, "t", self.allocator);
                const sender = sio.jsonGetString(d, "sender", self.allocator);
                defer if (sender) |s| self.allocator.free(s);
                if (t) |timestamp| {
                    self.sendPong(timestamp, sender) catch {};
                }
            }
            return;
        }

        if (std.mem.eql(u8, event, K.events.control_mode)) {
            if (data) |d| {
                if (sio.jsonGetString(d, "controlMode", self.allocator)) |mode| {
                    defer self.allocator.free(mode);
                    self.mutex.lock();
                    var cmd = MpvCommand{ .action = .control_mode_changed };
                    cmd.setText(mode);
                    self.incoming.push(cmd);
                    self.mutex.unlock();
                }
            }
            return;
        }

        if (std.mem.eql(u8, event, K.events.@"error")) {
            if (data) |d| {
                if (sio.jsonGetString(d, "message", self.allocator)) |msg| {
                    defer self.allocator.free(msg);
                    self.mutex.lock();
                    var cmd = MpvCommand{ .action = .error_msg };
                    cmd.setText(msg);
                    self.incoming.push(cmd);
                    self.mutex.unlock();
                }
            }
            return;
        }
    }

    fn maybeAck(self: *Session, data: ?[]const u8) void {
        const d = data orelse return;
        const sender_id = sio.jsonGetString(d, "senderId", self.allocator) orelse return;
        defer self.allocator.free(sender_id);
        const action_ts = sio.jsonGetNumber(d, "actionTimestamp", self.allocator) orelse return;
        self.sendEventAck(sender_id, @intFromFloat(action_ts)) catch {};
    }

    // ── Outgoing messages ───────────────────────────────────────

    fn sendJoinRoom(self: *Session) !void {
        self.mutex.lock();
        const current_title = if (self.media_title) |mt| self.allocator.dupe(u8, mt) catch null else null;
        self.mutex.unlock();
        defer if (current_title) |mt| self.allocator.free(mt);

        const enc_room = try sio.encodeJsonString(self.allocator, self.room_id);
        defer self.allocator.free(enc_room);
        const enc_peer = try sio.encodeJsonString(self.allocator, self.peer_id);
        defer self.allocator.free(enc_peer);
        const enc_user = try sio.encodeJsonString(self.allocator, self.username);
        defer self.allocator.free(enc_user);
        const enc_pass = try sio.encodeJsonString(self.allocator, self.password);
        defer self.allocator.free(enc_pass);
        const enc_proto = try sio.encodeJsonString(self.allocator, K.protocol_version);
        defer self.allocator.free(enc_proto);

        const enc_media_title = if (current_title) |ct| try sio.encodeJsonString(self.allocator, ct) else null;
        defer if (enc_media_title) |emt| self.allocator.free(emt);

        const json = if (enc_media_title) |emt|
            try std.fmt.allocPrint(self.allocator,
                "{{\"roomId\":{s},\"peerId\":{s},\"username\":{s},\"password\":{s},\"protocolVersion\":{s},\"mediaTitle\":{s},\"clientCapabilities\":[\"{s}\"]}}",
                .{ enc_room, enc_peer, enc_user, enc_pass, enc_proto, emt, K.capabilities.media_state_v1 },
            )
        else
            try std.fmt.allocPrint(self.allocator,
                "{{\"roomId\":{s},\"peerId\":{s},\"username\":{s},\"password\":{s},\"protocolVersion\":{s},\"clientCapabilities\":[\"{s}\"]}}",
                .{ enc_room, enc_peer, enc_user, enc_pass, enc_proto, K.capabilities.media_state_v1 },
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
        const enc_peer = try sio.encodeJsonString(self.allocator, self.peer_id);
        defer self.allocator.free(enc_peer);

        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"peerId\":{s},\"seq\":{d}}}",
            .{ enc_peer, self.seq },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.force_sync_ack, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendEventAck(self: *Session, target_id: []const u8, action_timestamp: i64) !void {
        const enc_target = try sio.encodeJsonString(self.allocator, target_id);
        defer self.allocator.free(enc_target);

        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"targetId\":{s},\"actionTimestamp\":{d}}}",
            .{ enc_target, action_timestamp },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.event_ack, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendPong(self: *Session, t: f64, target: ?[]const u8) !void {
        const enc_target = if (target) |tgt| try sio.encodeJsonString(self.allocator, tgt) else null;
        defer if (enc_target) |et| self.allocator.free(et);

        const json = if (enc_target) |et|
            try std.fmt.allocPrint(self.allocator, "{{\"t\":{d:.0},\"target\":{s}}}", .{ t, et })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"t\":{d:.0}}}", .{ t });
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.pong, json);
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

        self.mutex.lock();
        const current_title = if (self.media_title) |mt| self.allocator.dupe(u8, mt) catch null else null;
        self.mutex.unlock();
        defer if (current_title) |mt| self.allocator.free(mt);

        const enc_media_title = if (current_title) |ct| try sio.encodeJsonString(self.allocator, ct) else null;
        defer if (enc_media_title) |emt| self.allocator.free(emt);

        const json = if (enc_media_title) |emt|
            try std.fmt.allocPrint(self.allocator,
                "{{\"currentTime\":{d:.3},\"playbackState\":\"{s}\",\"seq\":{d},\"actionTimestamp\":{d},\"mediaTitle\":{s}}}",
                .{ time, playback_state, self.seq, time_mod.milliTimestamp(), emt },
            )
        else
            try std.fmt.allocPrint(self.allocator,
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

        self.mutex.lock();
        const current_title = if (self.media_title) |mt| self.allocator.dupe(u8, mt) catch null else null;
        self.mutex.unlock();
        defer if (current_title) |mt| self.allocator.free(mt);

        const enc_media_title = if (current_title) |ct| try sio.encodeJsonString(self.allocator, ct) else null;
        defer if (enc_media_title) |emt| self.allocator.free(emt);

        const json = if (enc_media_title) |emt|
            try std.fmt.allocPrint(self.allocator,
                "{{\"targetTime\":{d:.3},\"seq\":{d},\"actionTimestamp\":{d},\"mediaTitle\":{s}}}",
                .{ time, self.seq, time_mod.milliTimestamp(), emt },
            )
        else
            try std.fmt.allocPrint(self.allocator,
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

        self.mutex.lock();
        const current_title = if (self.media_title) |mt| self.allocator.dupe(u8, mt) catch null else null;
        self.mutex.unlock();
        defer if (current_title) |mt| self.allocator.free(mt);

        const enc_peer = try sio.encodeJsonString(self.allocator, self.peer_id);
        defer self.allocator.free(enc_peer);
        const enc_user = try sio.encodeJsonString(self.allocator, self.username);
        defer self.allocator.free(enc_user);

        const enc_media_title = if (current_title) |ct| try sio.encodeJsonString(self.allocator, ct) else null;
        defer if (enc_media_title) |emt| self.allocator.free(emt);

        const json = if (enc_media_title) |emt|
            try std.fmt.allocPrint(self.allocator,
                "{{\"peerId\":{s},\"username\":{s},\"currentTime\":{d:.3},\"playbackState\":\"{s}\",\"mediaTitle\":{s},\"status\":\"heartbeat\"}}",
                .{ enc_peer, enc_user, time, playback_state, emt },
            )
        else
            try std.fmt.allocPrint(self.allocator,
                "{{\"peerId\":{s},\"username\":{s},\"currentTime\":{d:.3},\"playbackState\":\"{s}\",\"status\":\"heartbeat\"}}",
                .{ enc_peer, enc_user, time, playback_state },
            );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.peer_status, json);
        defer self.allocator.free(pkt);

        if (self.ws) |*ws| ws.sendText(pkt) catch {};
    }
};
