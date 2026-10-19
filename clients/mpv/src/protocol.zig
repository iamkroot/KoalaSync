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
const invite = @import("invite.zig");

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
    text2_buf: [128]u8 = [_]u8{0} ** 128,
    text2_len: u8 = 0,

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
        peer_joined,
        peer_left,
        left_room,
        force_sync_done,
    };

    pub const PlaybackState = enum {
        playing,
        paused,
    };

    pub fn text(self: *const MpvCommand) []const u8 {
        if (self.text_len == 0) return "";
        return self.text_buf[0..self.text_len];
    }

    pub fn setText(self: *MpvCommand, str: []const u8) void {
        const len = @min(str.len, self.text_buf.len);
        @memcpy(self.text_buf[0..len], str[0..len]);
        self.text_len = @intCast(len);
    }

    pub fn text2(self: *const MpvCommand) []const u8 {
        if (self.text2_len == 0) return "";
        return self.text2_buf[0..self.text2_len];
    }

    pub fn setText2(self: *MpvCommand, str: []const u8) void {
        const len = @min(str.len, self.text2_buf.len);
        @memcpy(self.text2_buf[0..len], str[0..len]);
        self.text2_len = @intCast(len);
    }
};

/// An event from mpv to send to the relay.
pub const OutgoingEvent = struct {
    kind: Kind,
    time: f64 = 0,
    paused: bool = false,
    text_buf: [128]u8 = [_]u8{0} ** 128,
    text_len: u8 = 0,
    text2_buf: [128]u8 = [_]u8{0} ** 128,
    text2_len: u8 = 0,
    text3_buf: [128]u8 = [_]u8{0} ** 128,
    text3_len: u8 = 0,
    text4_buf: [64]u8 = [_]u8{0} ** 64,
    text4_len: u8 = 0,

    pub const Kind = enum {
        play,
        pause,
        seek,
        heartbeat,
        join_room,
        leave_room,
        force_sync_prepare,
        force_sync_execute,
    };

    pub fn text(self: *const OutgoingEvent) []const u8 {
        if (self.text_len == 0) return "";
        return self.text_buf[0..self.text_len];
    }

    pub fn setText(self: *OutgoingEvent, str: []const u8) void {
        const len = @min(str.len, self.text_buf.len);
        @memcpy(self.text_buf[0..len], str[0..len]);
        self.text_len = @intCast(len);
    }

    pub fn text2(self: *const OutgoingEvent) []const u8 {
        if (self.text2_len == 0) return "";
        return self.text2_buf[0..self.text2_len];
    }

    pub fn setText2(self: *OutgoingEvent, str: []const u8) void {
        const len = @min(str.len, self.text2_buf.len);
        @memcpy(self.text2_buf[0..len], str[0..len]);
        self.text2_len = @intCast(len);
    }

    pub fn text3(self: *const OutgoingEvent) []const u8 {
        if (self.text3_len == 0) return "";
        return self.text3_buf[0..self.text3_len];
    }

    pub fn setText3(self: *OutgoingEvent, str: []const u8) void {
        const len = @min(str.len, self.text3_buf.len);
        @memcpy(self.text3_buf[0..len], str[0..len]);
        self.text3_len = @intCast(len);
    }

    pub fn text4(self: *const OutgoingEvent) []const u8 {
        if (self.text4_len == 0) return "";
        return self.text4_buf[0..self.text4_len];
    }

    pub fn setText4(self: *OutgoingEvent, str: []const u8) void {
        const len = @min(str.len, self.text4_buf.len);
        @memcpy(self.text4_buf[0..len], str[0..len]);
        self.text4_len = @intCast(len);
    }
};

/// Information about a connected peer in the current room.
pub const PeerInfo = struct {
    id_buf: [48]u8 = [_]u8{0} ** 48,
    id_len: u8 = 0,
    username_buf: [48]u8 = [_]u8{0} ** 48,
    username_len: u8 = 0,
    time_pos: f64 = 0,
    last_update_ms: i64 = 0,
    is_paused: bool = false,
    ping_ms: u32 = 0,
    is_host: bool = false,
    active: bool = false,

    pub fn currentPos(self: *const PeerInfo, now_ms: i64) f64 {
        if (self.is_paused or self.last_update_ms == 0) {
            return self.time_pos;
        }
        const delta_ms = now_ms - self.last_update_ms;
        if (delta_ms <= 0) return self.time_pos;
        const delta_sec = @min(@as(f64, @floatFromInt(delta_ms)) / 1000.0, 10.0);
        return self.time_pos + delta_sec;
    }

    pub fn id(self: *const PeerInfo) []const u8 {
        if (self.id_len == 0) return "";
        return self.id_buf[0..self.id_len];
    }

    pub fn setId(self: *PeerInfo, s: []const u8) void {
        const len = @min(s.len, self.id_buf.len);
        @memcpy(self.id_buf[0..len], s[0..len]);
        self.id_len = @intCast(len);
    }

    pub fn username(self: *const PeerInfo) []const u8 {
        if (self.username_len == 0) return "";
        return self.username_buf[0..self.username_len];
    }

    pub fn setUsername(self: *PeerInfo, s: []const u8) void {
        const len = @min(s.len, self.username_buf.len);
        @memcpy(self.username_buf[0..len], s[0..len]);
        self.username_len = @intCast(len);
    }
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
    room_id: ?[]u8 = null,
    password: []u8,
    chat_key: []u8,
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

    // User controls state
    sync_muted: bool = false,
    peers: [32]PeerInfo = [_]PeerInfo{.{}} ** 32,
    server_ping_ms: u32 = 0,
    local_time: f64 = 0,
    local_paused: bool = true,
    last_room_time: f64 = 0,
    last_room_playback_state: MpvCommand.PlaybackState = .paused,
    force_sync_active: bool = false,
    force_sync_execute_at: i64 = 0,

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

    pub fn parseServerUrl(server_url: []const u8) struct { host: []const u8, port: u16, use_tls: bool } {
        var use_tls = true;
        var url_rest: []const u8 = server_url;

        if (std.mem.startsWith(u8, url_rest, "wss://")) {
            url_rest = url_rest[6..];
        } else if (std.mem.startsWith(u8, url_rest, "ws://")) {
            url_rest = url_rest[5..];
            use_tls = false;
        }

        var host: []const u8 = url_rest;
        var port: u16 = if (use_tls) 443 else 80;

        if (std.mem.indexOfScalar(u8, url_rest, ':')) |colon| {
            host = url_rest[0..colon];
            const port_str = url_rest[colon + 1 ..];
            const port_end = std.mem.indexOfScalar(u8, port_str, '/') orelse port_str.len;
            port = std.fmt.parseInt(u16, port_str[0..port_end], 10) catch port;
        } else if (std.mem.indexOfScalar(u8, url_rest, '/')) |slash| {
            host = url_rest[0..slash];
        }

        return .{ .host = host, .port = port, .use_tls = use_tls };
    }

    pub fn updateServer(self: *Session, server_url: []const u8) !bool {
        if (server_url.len == 0) return false;
        const parsed = parseServerUrl(server_url);
        if (std.mem.eql(u8, self.server_host, parsed.host) and
            self.server_port == parsed.port and
            self.use_tls == parsed.use_tls)
        {
            return false;
        }
        self.allocator.free(self.server_host);
        self.server_host = try self.allocator.dupe(u8, parsed.host);
        self.server_port = parsed.port;
        self.use_tls = parsed.use_tls;
        return true;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        server_url: []const u8,
        room_id: ?[]const u8,
        password: []const u8,
        peer_id: []const u8,
        username: []const u8,
    ) !Session {
        const parsed = parseServerUrl(server_url);

        // Build upgrade path
        const path = try std.fmt.allocPrint(allocator,
            "/socket.io/?EIO=4&transport=websocket&token={s}&version={s}",
            .{ K.official_server_token, K.app_version },
        );

        const duped_room = if (room_id) |r| (if (r.len > 0) try allocator.dupe(u8, r) else null) else null;
        const safe_peer_id = if (peer_id.len > 16) peer_id[0..16] else peer_id;

        var chat_key_init: []u8 = undefined;
        if (duped_room != null) {
            var k_buf: [22]u8 = undefined;
            invite.generateChatKey(&k_buf);
            chat_key_init = try allocator.dupe(u8, &k_buf);
        } else {
            chat_key_init = try allocator.dupe(u8, "");
        }

        return .{
            .allocator = allocator,
            .server_host = try allocator.dupe(u8, parsed.host),
            .server_port = parsed.port,
            .server_path = path,
            .use_tls = parsed.use_tls,
            .room_id = duped_room,
            .password = try allocator.dupe(u8, password),
            .chat_key = chat_key_init,
            .peer_id = try allocator.dupe(u8, safe_peer_id),
            .username = try allocator.dupe(u8, username),
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.ws) |*ws| ws.deinit();
        self.allocator.free(self.server_host);
        self.allocator.free(self.server_path);
        if (self.room_id) |r| self.allocator.free(r);
        self.allocator.free(self.password);
        self.allocator.free(self.chat_key);
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

    // ── Thread-safe user controls interface ────────────────────

    pub fn requestJoin(
        self: *Session,
        room: []const u8,
        password: ?[]const u8,
        server_url: ?[]const u8,
        chat_key: ?[]const u8,
    ) void {
        var evt = OutgoingEvent{ .kind = .join_room };
        evt.setText(room);
        if (password) |pass| {
            evt.setText2(pass);
        }
        if (server_url) |srv| {
            evt.setText3(srv);
        }
        if (chat_key) |ck| {
            evt.setText4(ck);
        }
        self.mutex.lock();
        self.outgoing.push(evt);
        self.mutex.unlock();
    }

    pub fn requestLeave(self: *Session) void {
        self.mutex.lock();
        self.outgoing.push(.{ .kind = .leave_room });
        self.mutex.unlock();
    }

    pub fn requestForceSync(self: *Session, time: f64) void {
        self.mutex.lock();
        self.outgoing.push(.{ .kind = .force_sync_prepare, .time = time });
        self.mutex.unlock();
    }

    pub fn toggleSyncMute(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sync_muted = !self.sync_muted;
        return self.sync_muted;
    }

    pub fn isSyncMuted(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sync_muted;
    }

    pub fn getLastRoomTime(self: *Session) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_room_time;
    }

    pub fn getRoomName(self: *Session, buf: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.room_id) |r| {
            if (r.len == 0) return null;
            const len = @min(r.len, buf.len);
            @memcpy(buf[0..len], r[0..len]);
            return buf[0..len];
        }
        return null;
    }

    pub fn getRoomInviteLink(self: *Session, allocator: std.mem.Allocator, base_url: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const room = self.room_id orelse return null;
        if (room.len == 0) return null;

        var custom_server: ?[]const u8 = null;
        var srv_buf: [128]u8 = undefined;
        const is_official = std.mem.eql(u8, self.server_host, "syncserver.koalastuff.net") and
            (if (self.use_tls) self.server_port == 443 else self.server_port == 80);

        if (!is_official) {
            const scheme: []const u8 = if (self.use_tls) "wss://" else "ws://";
            const default_port: u16 = if (self.use_tls) 443 else 80;
            if (self.server_port == default_port) {
                custom_server = std.fmt.bufPrint(&srv_buf, "{s}{s}", .{ scheme, self.server_host }) catch null;
            } else {
                custom_server = std.fmt.bufPrint(&srv_buf, "{s}{s}:{d}", .{ scheme, self.server_host, self.server_port }) catch null;
            }
        }

        return invite.buildInviteLink(allocator, base_url, room, self.password, self.chat_key, custom_server) catch null;
    }

    pub fn updateLocalState(self: *Session, time: f64, paused: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.local_time = time;
        self.local_paused = paused;
    }

    pub fn getRosterSnapshot(self: *Session, out: []PeerInfo) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;

        // If in a joined room, entry #0 is the local player
        if (self.state == .joined and out.len > 0) {
            var local = &out[0];
            local.active = true;
            local.setId(self.peer_id);
            var u_buf: [48]u8 = undefined;
            const u_str = std.fmt.bufPrint(&u_buf, "{s} (You)", .{self.username}) catch self.username;
            local.setUsername(u_str);
            local.time_pos = self.local_time;
            local.last_update_ms = time_mod.milliTimestamp();
            local.is_paused = self.local_paused;
            local.ping_ms = self.server_ping_ms;
            local.is_host = false;
            count = 1;
        }

        const now = time_mod.milliTimestamp();
        for (&self.peers) |*p| {
            if (p.active and count < out.len) {
                out[count] = p.*;
                out[count].time_pos = p.currentPos(now);
                count += 1;
            }
        }
        return count;
    }

    pub fn getServerPing(self: *Session) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.server_ping_ms;
    }

    // ── Thread-safe interface for the mpv thread ────────────────

    /// Pop the next incoming command for mpv. Thread-safe.
    pub fn popCommand(self: *Session) ?MpvCommand {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.incoming.pop();
    }

    /// Push an outgoing event from mpv. Thread-safe.
    pub fn pushEvent(self: *Session, evt: OutgoingEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If sync is muted, suppress play, pause, and seek events from mpv
        if (self.sync_muted) {
            switch (evt.kind) {
                .play, .pause, .seek => return,
                else => {},
            }
        }

        self.outgoing.push(evt);
    }

    /// Signal the network thread to shut down. Thread-safe.
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

    fn hasRoom(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.room_id) |r| r.len > 0 else false;
    }

    // ── Peer Roster Helpers (Mutex must be held by caller) ──────

    fn updateOrAddPeer(self: *Session, peer_id: []const u8, user: ?[]const u8, time_pos: ?f64, paused: ?bool) void {
        if (peer_id.len == 0 or std.mem.eql(u8, peer_id, self.peer_id)) return;

        const now = time_mod.milliTimestamp();
        for (&self.peers) |*p| {
            if (p.active and std.mem.eql(u8, p.id(), peer_id)) {
                if (user) |u| p.setUsername(u);
                if (time_pos) |t| {
                    p.time_pos = t;
                    p.last_update_ms = now;
                }
                if (paused) |is_p| p.is_paused = is_p;
                return;
            }
        }
        for (&self.peers) |*p| {
            if (!p.active) {
                p.active = true;
                p.setId(peer_id);
                if (user) |u| p.setUsername(u) else p.setUsername(peer_id);
                if (time_pos) |t| {
                    p.time_pos = t;
                    p.last_update_ms = now;
                } else {
                    p.time_pos = 0;
                    p.last_update_ms = 0;
                }
                if (paused) |is_p| p.is_paused = is_p;
                p.ping_ms = self.server_ping_ms;
                return;
            }
        }
    }

    fn removePeer(self: *Session, peer_id: []const u8) void {
        for (&self.peers) |*p| {
            if (p.active and std.mem.eql(u8, p.id(), peer_id)) {
                p.active = false;
                p.id_len = 0;
                p.username_len = 0;
                return;
            }
        }
    }

    fn clearPeers(self: *Session) void {
        for (&self.peers) |*p| {
            p.active = false;
            p.id_len = 0;
            p.username_len = 0;
        }
    }

    // ── Network thread entry point ──────────────────────────────

    /// Main loop for the network thread.
    pub fn networkLoop(self: *Session) void {
        while (!self.isQuitRequested()) {
            if (!self.hasRoom()) {
                self.drainControlEvents();
                time_mod.sleepMs(50);
                continue;
            }

            self.connectAndRun() catch {};

            if (self.isQuitRequested()) break;

            if (!self.hasRoom()) {
                continue;
            }

            // Reconnection backoff
            self.reconnect_attempts += 1;
            if (self.reconnect_attempts > self.max_reconnect_attempts) {
                self.mutex.lock();
                if (self.room_id) |r| {
                    self.allocator.free(r);
                    self.room_id = null;
                }
                self.state = .disconnected;
                self.mutex.unlock();
                continue;
            }
            const delay_ms: u64 = @min(
                500 * std.math.pow(u64, 2, @min(self.reconnect_attempts, 10)),
                5000,
            );

            var slept: u64 = 0;
            while (slept < delay_ms and !self.isQuitRequested() and self.hasRoom()) : (slept += 50) {
                self.drainControlEvents();
                time_mod.sleepMs(50);
            }
        }
    }

    fn drainControlEvents(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        while (count < 16) : (count += 1) {
            const maybe_evt = self.outgoing.pop();
            const evt = maybe_evt orelse break;

            switch (evt.kind) {
                .join_room => {
                    if (self.room_id) |old| self.allocator.free(old);
                    self.room_id = self.allocator.dupe(u8, evt.text()) catch null;
                    if (evt.text2_len > 0) {
                        self.allocator.free(self.password);
                        self.password = self.allocator.dupe(u8, evt.text2()) catch self.password;
                    }
                    if (evt.text3_len > 0) {
                        _ = self.updateServer(evt.text3()) catch {};
                    }
                    if (evt.text4_len > 0) {
                        self.allocator.free(self.chat_key);
                        self.chat_key = self.allocator.dupe(u8, evt.text4()) catch self.chat_key;
                    } else {
                        var k_buf: [22]u8 = undefined;
                        invite.generateChatKey(&k_buf);
                        self.allocator.free(self.chat_key);
                        self.chat_key = self.allocator.dupe(u8, &k_buf) catch self.chat_key;
                    }
                    self.reconnect_attempts = 0;
                },
                .leave_room => {
                    if (self.room_id) |old| {
                        self.allocator.free(old);
                        self.room_id = null;
                    }
                    self.allocator.free(self.chat_key);
                    self.chat_key = self.allocator.dupe(u8, "") catch self.chat_key;
                    self.state = .disconnected;
                    self.clearPeers();
                    self.incoming.push(.{ .action = .left_room });
                },
                else => {},
            }
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
        while (!self.isQuitRequested() and self.hasRoom()) {
            // Check force sync deadline
            self.checkForceSyncDeadline();

            // Send any queued outgoing events first
            self.drainOutgoing() catch break;

            // Read next message (short timeout ensures outgoing events like pause/play are drained promptly)
            var maybe_msg = (self.ws orelse break).readMessage(20) catch break;
            if (maybe_msg) |*msg| {
                defer msg.deinit(self.allocator);
                self.handleRawMessage(msg.data) catch continue;
            }
        }

        // Send leave_room before disconnecting if in joined state
        if (self.state == .joined) {
            self.sendLeaveRoom() catch {};
        }
    }

    fn checkForceSyncDeadline(self: *Session) void {
        self.mutex.lock();
        const active = self.force_sync_active;
        const deadline = self.force_sync_execute_at;
        self.mutex.unlock();

        if (active and time_mod.milliTimestamp() >= deadline) {
            self.sendForceSyncExecute() catch {};
            self.mutex.lock();
            self.force_sync_active = false;
            self.incoming.push(.{ .action = .force_sync_done });
            self.mutex.unlock();
        }
    }

    fn handleRawMessage(self: *Session, data: []const u8) !void {
        const packet = sio.decode(data);

        switch (packet.type) {
            .eio_open => {
                if (packet.raw) |raw| {
                    self.ping_config = sio.parsePingConfig(raw, self.allocator);
                }
                var ws = &(self.ws orelse return error.ConnectionFailed);
                try ws.sendText(sio.encodeConnect());
            },
            .eio_ping => {
                var ws = &(self.ws orelse return error.ConnectionFailed);
                try ws.sendText(sio.encodePong());
            },
            .sio_connect => {
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

            self.clearPeers();

            if (data) |d| {
                if (std.json.parseFromSlice(std.json.Value, self.allocator, d, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        const obj = parsed.value.object;
                        if (obj.get("peers")) |peers_val| {
                            if (peers_val == .array) {
                                for (peers_val.array.items) |item| {
                                    if (item == .object) {
                                        const peer_obj = item.object;
                                        const pid = if (peer_obj.get("peerId")) |v| (if (v == .string) v.string else null) else null;
                                        const uname = if (peer_obj.get("username")) |v| (if (v == .string) v.string else null) else null;
                                        if (pid) |p| {
                                            self.updateOrAddPeer(p, uname, null, null);
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else |_| {}
            }

            if (maybe_ms) |ms| {
                self.last_room_time = ms.current_time;
                self.last_room_playback_state = switch (ms.playback_state) {
                    .playing => .playing,
                    .paused => .paused,
                };
                self.incoming.push(.{
                    .action = .initial_sync,
                    .time = ms.current_time,
                    .playback_state = self.last_room_playback_state,
                });
            } else {
                self.incoming.push(.{ .action = .noop });
            }
            return;
        }

        if (std.mem.eql(u8, event, K.events.play)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            const sender = if (data) |d| (sio.jsonGetString(d, "senderId", self.allocator) orelse sio.jsonGetString(d, "peerId", self.allocator)) else null;
            defer if (sender) |s| self.allocator.free(s);
            self.mutex.lock();
            self.last_room_time = time;
            self.last_room_playback_state = .playing;
            if (sender) |s| self.updateOrAddPeer(s, null, time, false);
            const muted = self.sync_muted;
            if (!muted) {
                self.incoming.push(.{ .action = .play, .time = time });
            }
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.pause)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0 else 0;
            const sender = if (data) |d| (sio.jsonGetString(d, "senderId", self.allocator) orelse sio.jsonGetString(d, "peerId", self.allocator)) else null;
            defer if (sender) |s| self.allocator.free(s);
            self.mutex.lock();
            self.last_room_time = time;
            self.last_room_playback_state = .paused;
            if (sender) |s| self.updateOrAddPeer(s, null, time, true);
            const muted = self.sync_muted;
            if (!muted) {
                self.incoming.push(.{ .action = .pause, .time = time });
            }
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.seek)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse 0 else 0;
            const sender = if (data) |d| (sio.jsonGetString(d, "senderId", self.allocator) orelse sio.jsonGetString(d, "peerId", self.allocator)) else null;
            defer if (sender) |s| self.allocator.free(s);
            self.mutex.lock();
            self.last_room_time = time;
            if (sender) |s| self.updateOrAddPeer(s, null, time, null);
            const muted = self.sync_muted;
            if (!muted) {
                self.incoming.push(.{ .action = .seek, .time = time });
            }
            self.mutex.unlock();
            self.maybeAck(data);
            return;
        }

        if (std.mem.eql(u8, event, K.events.peer_status)) {
            if (data) |d| {
                const pid = sio.jsonGetString(d, "peerId", self.allocator);
                defer if (pid) |p| self.allocator.free(p);
                const uname = sio.jsonGetString(d, "username", self.allocator);
                defer if (uname) |u| self.allocator.free(u);
                const status = sio.jsonGetString(d, "status", self.allocator);
                defer if (status) |s| self.allocator.free(s);
                const time = sio.jsonGetNumber(d, "currentTime", self.allocator);
                const state_str = sio.jsonGetString(d, "playbackState", self.allocator);
                defer if (state_str) |s| self.allocator.free(s);
                const is_paused: ?bool = if (state_str) |s| std.mem.eql(u8, s, "paused") else null;

                if (pid) |p| {
                    self.mutex.lock();
                    if (status) |s| {
                        if (std.mem.eql(u8, s, "left")) {
                            self.removePeer(p);
                            var cmd = MpvCommand{ .action = .peer_left };
                            cmd.setText(if (uname) |u| u else p);
                            self.incoming.push(cmd);
                        } else if (std.mem.eql(u8, s, "joined")) {
                            self.updateOrAddPeer(p, uname, time, is_paused);
                            var cmd = MpvCommand{ .action = .peer_joined };
                            cmd.setText(if (uname) |u| u else p);
                            self.incoming.push(cmd);
                        } else {
                            self.updateOrAddPeer(p, uname, time, is_paused);
                        }
                    } else {
                        self.updateOrAddPeer(p, uname, time, is_paused);
                    }
                    self.mutex.unlock();
                }
            }
            return;
        }

        if (std.mem.eql(u8, event, K.events.force_sync_prepare)) {
            const time = if (data) |d| sio.jsonGetNumber(d, "targetTime", self.allocator) orelse (sio.jsonGetNumber(d, "currentTime", self.allocator) orelse 0) else 0;
            self.mutex.lock();
            self.last_room_time = time;
            self.incoming.push(.{ .action = .force_sync_prepare, .time = time });
            self.mutex.unlock();

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

        if (std.mem.eql(u8, event, K.events.pong)) {
            if (data) |d| {
                if (sio.jsonGetNumber(d, "t", self.allocator)) |t| {
                    const now = time_mod.milliTimestamp();
                    const rtt = now - @as(i64, @intFromFloat(t));
                    if (rtt >= 0 and rtt < 10000) {
                        self.mutex.lock();
                        self.server_ping_ms = @intCast(rtt);
                        for (&self.peers) |*p| {
                            if (p.active) p.ping_ms = self.server_ping_ms;
                        }
                        self.mutex.unlock();
                    }
                }
            }
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
        const current_room = if (self.room_id) |r| (if (r.len > 0) self.allocator.dupe(u8, r) catch null else null) else null;
        const current_title = if (self.media_title) |mt| self.allocator.dupe(u8, mt) catch null else null;
        const pass = self.allocator.dupe(u8, self.password) catch null;
        self.mutex.unlock();

        defer if (current_title) |mt| self.allocator.free(mt);
        defer if (pass) |p| self.allocator.free(p);

        const room = current_room orelse return;
        defer self.allocator.free(room);

        const enc_room = try sio.encodeJsonString(self.allocator, room);
        defer self.allocator.free(enc_room);
        const enc_peer = try sio.encodeJsonString(self.allocator, self.peer_id);
        defer self.allocator.free(enc_peer);
        const enc_user = try sio.encodeJsonString(self.allocator, self.username);
        defer self.allocator.free(enc_user);
        const enc_pass = try sio.encodeJsonString(self.allocator, pass orelse "");
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

    fn sendForceSyncPrepare(self: *Session, time: f64) !void {
        self.seq += 1;
        const enc_media_title = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.media_title) |mt| {
                break :blk try sio.encodeJsonString(self.allocator, mt);
            }
            break :blk null;
        };
        defer if (enc_media_title) |emt| self.allocator.free(emt);

        const json = if (enc_media_title) |emt|
            try std.fmt.allocPrint(self.allocator,
                "{{\"targetTime\":{d:.3},\"currentTime\":{d:.3},\"seq\":{d},\"actionTimestamp\":{d},\"mediaTitle\":{s}}}",
                .{ time, time, self.seq, time_mod.milliTimestamp(), emt },
            )
        else
            try std.fmt.allocPrint(self.allocator,
                "{{\"targetTime\":{d:.3},\"currentTime\":{d:.3},\"seq\":{d},\"actionTimestamp\":{d}}}",
                .{ time, time, self.seq, time_mod.milliTimestamp() },
            );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.force_sync_prepare, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
    }

    fn sendForceSyncExecute(self: *Session) !void {
        self.seq += 1;
        const json = try std.fmt.allocPrint(self.allocator,
            "{{\"seq\":{d},\"actionTimestamp\":{d}}}",
            .{ self.seq, time_mod.milliTimestamp() },
        );
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.force_sync_execute, json);
        defer self.allocator.free(pkt);

        var ws = &(self.ws orelse return error.ConnectionFailed);
        try ws.sendText(pkt);
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

    fn sendPing(self: *Session) !void {
        const json = try std.fmt.allocPrint(self.allocator, "{{\"t\":{d}}}", .{time_mod.milliTimestamp()});
        defer self.allocator.free(json);

        const pkt = try sio.encodeEvent(self.allocator, K.events.ping, json);
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
                .join_room => {
                    self.mutex.lock();
                    if (self.room_id) |old| self.allocator.free(old);
                    self.room_id = self.allocator.dupe(u8, evt.text()) catch null;
                    if (evt.text2_len > 0) {
                        self.allocator.free(self.password);
                        self.password = self.allocator.dupe(u8, evt.text2()) catch self.password;
                    }
                    var server_changed = false;
                    if (evt.text3_len > 0) {
                        server_changed = self.updateServer(evt.text3()) catch false;
                    }
                    if (evt.text4_len > 0) {
                        self.allocator.free(self.chat_key);
                        self.chat_key = self.allocator.dupe(u8, evt.text4()) catch self.chat_key;
                    } else {
                        var k_buf: [22]u8 = undefined;
                        invite.generateChatKey(&k_buf);
                        self.allocator.free(self.chat_key);
                        self.chat_key = self.allocator.dupe(u8, &k_buf) catch self.chat_key;
                    }
                    self.mutex.unlock();
                    if (server_changed) {
                        if (self.ws) |*ws| ws.deinit();
                        self.ws = null;
                        return;
                    }
                    try self.sendJoinRoom();
                },
                .leave_room => {
                    try self.sendLeaveRoom();
                    self.mutex.lock();
                    if (self.room_id) |old| {
                        self.allocator.free(old);
                        self.room_id = null;
                    }
                    self.allocator.free(self.chat_key);
                    self.chat_key = self.allocator.dupe(u8, "") catch self.chat_key;
                    self.state = .disconnected;
                    self.clearPeers();
                    self.incoming.push(.{ .action = .left_room });
                    self.mutex.unlock();
                    return;
                },
                .force_sync_prepare => {
                    try self.sendForceSyncPrepare(evt.time);
                    self.mutex.lock();
                    self.force_sync_active = true;
                    self.force_sync_execute_at = time_mod.milliTimestamp() + 750;
                    self.mutex.unlock();
                },
                .force_sync_execute => {
                    try self.sendForceSyncExecute();
                    self.mutex.lock();
                    self.force_sync_active = false;
                    self.mutex.unlock();
                },
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

        if (self.ws) |*ws| {
            ws.sendText(pkt) catch {};
            self.sendPing() catch {};
        }
    }
};

test "PeerInfo.currentPos advances only while playing" {
    var peer = PeerInfo{};
    peer.time_pos = 100.0;
    peer.last_update_ms = 1000;
    peer.is_paused = false;

    // Advance by 3 seconds
    const pos = peer.currentPos(4000);
    try std.testing.expectApproxEqAbs(@as(f64, 103.0), pos, 0.001);

    // When paused, stays fixed
    peer.is_paused = true;
    const paused_pos = peer.currentPos(5000);
    try std.testing.expectEqual(@as(f64, 100.0), paused_pos);
}

test "Session peer_id is clamped to at most 16 chars" {
    const allocator = std.testing.allocator;
    var s = try Session.init(
        allocator,
        "wss://localhost:443",
        "room1",
        "pass",
        "mpv-0123456789abcdef", // 20 chars
        "alice",
    );
    defer s.deinit();

    try std.testing.expect(s.peer_id.len <= 16);
    try std.testing.expectEqualStrings("mpv-0123456789ab", s.peer_id);
}

test "Session getRosterSnapshot includes local player when joined" {
    const allocator = std.testing.allocator;
    var s = try Session.init(
        allocator,
        "wss://localhost:443",
        "testroom",
        "",
        "mpv-test1234",
        "kroot",
    );
    defer s.deinit();

    var out: [4]PeerInfo = undefined;

    // Disconnected: 0 peers
    try std.testing.expectEqual(@as(usize, 0), s.getRosterSnapshot(&out));

    // Joined: local player is entry 0
    s.state = .joined;
    s.updateLocalState(42.5, false);

    // Add a remote peer and attempt to add own peer ID
    s.updateOrAddPeer("mpv-test1234", "kroot", 0.0, false); // own peer ID should be ignored!
    s.updateOrAddPeer("remote-peer-1", "ZenMongoose", 45.0, false);

    const count = s.getRosterSnapshot(&out);
    try std.testing.expectEqual(@as(usize, 2), count);

    // Entry 0 is local user
    try std.testing.expectEqualStrings("kroot (You)", out[0].username());
    try std.testing.expectEqual(@as(f64, 42.5), out[0].time_pos);

    // Entry 1 is remote peer
    try std.testing.expectEqualStrings("ZenMongoose", out[1].username());
}

test "Session parseServerUrl and updateServer" {
    const allocator = std.testing.allocator;

    const p1 = Session.parseServerUrl("wss://relay.example.org");
    try std.testing.expectEqualStrings("relay.example.org", p1.host);
    try std.testing.expectEqual(@as(u16, 443), p1.port);
    try std.testing.expect(p1.use_tls);

    const p2 = Session.parseServerUrl("ws://localhost:8080/path");
    try std.testing.expectEqualStrings("localhost", p2.host);
    try std.testing.expectEqual(@as(u16, 8080), p2.port);
    try std.testing.expect(!p2.use_tls);

    var s = try Session.init(
        allocator,
        "wss://official.relay",
        null,
        "",
        "mpv-1234",
        "alice",
    );
    defer s.deinit();

    try std.testing.expectEqualStrings("official.relay", s.server_host);

    const changed = try s.updateServer("wss://custom.relay:8443");
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("custom.relay", s.server_host);
    try std.testing.expectEqual(@as(u16, 8443), s.server_port);

    const no_change = try s.updateServer("wss://custom.relay:8443");
    try std.testing.expect(!no_change);
}

test "Session getRoomInviteLink builds valid link" {
    const allocator = std.testing.allocator;

    var s = try Session.init(
        allocator,
        "wss://syncserver.koalastuff.net",
        "movie-room",
        "mypassword",
        "mpv-1234",
        "alice",
    );
    defer s.deinit();

    const link = s.getRoomInviteLink(allocator, "https://sync.koalastuff.net").?;
    defer allocator.free(link);

    try std.testing.expect(std.mem.startsWith(u8, link, "https://sync.koalastuff.net/join.html#j2:"));

    var parsed = invite.parseInviteText(allocator, link).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("movie-room", parsed.room_id);
    try std.testing.expectEqualStrings("mypassword", parsed.password);
    try std.testing.expect(!parsed.use_custom_server);
}


