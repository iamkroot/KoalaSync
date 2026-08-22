/// KoalaSync mpv C plugin — entry point.
///
/// Exports `mpv_open_cplugin` which mpv calls on a dedicated thread
/// when loading the shared library.  Sets up property observation,
/// spawns the network thread, and runs the main event loop that
/// translates between mpv events and KoalaSync protocol commands.
const std = @import("std");
const mpv = @import("mpv.zig");
const config_mod = @import("config.zig");
const protocol = @import("protocol.zig");
const K = @import("constants.zig");
const time_util = @import("time.zig");
const c = @cImport(@cInclude("mpv/client.h"));

// ── Property observation user-data keys ─────────────────────────
const UD_PAUSE: u64 = 1;
const UD_TIME_POS: u64 = 2;
const UD_MEDIA_TITLE: u64 = 3;

/// Seek detection: if time-pos jumps by more than this many seconds
/// in a single property-change callback, treat it as a seek.
const SEEK_THRESHOLD: f64 = 2.0;

/// mpv event loop poll interval in seconds.
const POLL_INTERVAL: f64 = 0.1;

// ── Loop guard ──────────────────────────────────────────────────
/// When we apply a remote command (e.g. set pause=yes), the resulting
/// property-change event must be suppressed so we don't echo it back
/// to the relay.  These flags implement that guard.
const LoopGuard = struct {
    suppress_pause: bool = false,
    suppress_time: bool = false,

    // Timestamp of last remote seek so we can distinguish the
    // property-change echo from genuine user seeks.
    remote_seek_target: f64 = -1,
};

// ── Entry point ─────────────────────────────────────────────────

export fn mpv_open_cplugin(handle: *c.mpv_handle) callconv(.c) c_int {
    main_impl(@ptrCast(handle)) catch return -1;
    return 0;
}

fn main_impl(handle: mpv.Handle) !void {
    const allocator = std.heap.c_allocator;

    // ── Load config ─────────────────────────────────────────────
    var cfg = config_mod.load(handle, allocator) catch |e| {
        if (e == error.NoRoomConfigured) {
            mpv.osdMessage(handle, allocator, "KoalaSync: no room configured (set script-opts koalasync-room)", .{}, 5);
            return;
        }
        mpv.osdMessage(handle, allocator, "KoalaSync: config error", .{}, 3);
        return e;
    };
    defer cfg.deinit();

    mpv.osdMessage(handle, allocator, "KoalaSync: connecting to room \"{s}\"…", .{cfg.room}, 3);

    // ── Set up protocol session ─────────────────────────────────
    var session = try protocol.Session.init(
        allocator,
        cfg.server,
        cfg.room,
        cfg.password,
        cfg.peer_id,
        cfg.username,
    );
    defer session.deinit();

    // ── Spawn network thread ────────────────────────────────────
    const net_thread = try std.Thread.spawn(.{}, protocol.Session.networkLoop, .{&session});

    defer {
        session.requestQuit();
        net_thread.join();
    }

    // ── Observe mpv properties ──────────────────────────────────
    try mpv.observeProperty(handle, UD_PAUSE, "pause", c.MPV_FORMAT_FLAG);
    try mpv.observeProperty(handle, UD_TIME_POS, "time-pos", c.MPV_FORMAT_DOUBLE);
    try mpv.observeProperty(handle, UD_MEDIA_TITLE, "media-title", c.MPV_FORMAT_STRING);

    // ── State ───────────────────────────────────────────────────
    var guard = LoopGuard{};
    var last_time: f64 = 0;
    var last_heartbeat = time_util.milliTimestamp();
    var joined_shown = false;
    var last_pause_state: ?bool = null;

    // ── Main event loop ─────────────────────────────────────────
    while (true) {
        const event = mpv.waitEvent(handle, POLL_INTERVAL);

        switch (event.event_id) {
            c.MPV_EVENT_SHUTDOWN => break,

            c.MPV_EVENT_PROPERTY_CHANGE => {
                const prop: *mpv.EventProperty = @ptrCast(@alignCast(event.data));
                switch (event.reply_userdata) {
                    UD_PAUSE => {
                        if (prop.data) |data| {
                            const paused = @as(*const c_int, @ptrCast(@alignCast(data))).* != 0;

                            if (guard.suppress_pause) {
                                guard.suppress_pause = false;
                                last_pause_state = paused;
                                continue;
                            }

                            // Skip duplicate pause states (mpv can fire these)
                            if (last_pause_state) |prev| {
                                if (prev == paused) continue;
                            }
                            last_pause_state = paused;

                            const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
                            if (session.state == .joined) {
                                if (paused) {
                                    session.pushEvent(.{ .kind = .pause, .time = time });
                                } else {
                                    session.pushEvent(.{ .kind = .play, .time = time });
                                }
                            }
                        }
                    },
                    UD_TIME_POS => {
                        if (prop.data) |data| {
                            const time = @as(*const f64, @ptrCast(@alignCast(data))).*;

                            // Detect seek: large jump from last known position
                            const delta = @abs(time - last_time);
                            if (delta > SEEK_THRESHOLD and last_time > 0) {
                                if (guard.suppress_time) {
                                    guard.suppress_time = false;
                                } else if (guard.remote_seek_target >= 0 and
                                    @abs(time - guard.remote_seek_target) < 1.0)
                                {
                                    // This is the echo from a remote seek we applied
                                    guard.remote_seek_target = -1;
                                } else if (session.state == .joined) {
                                    session.pushEvent(.{ .kind = .seek, .time = time });
                                }
                            }
                            last_time = time;
                        }
                    },
                    UD_MEDIA_TITLE => {
                        // Title changed — future: episode sync
                    },
                    else => {},
                }
            },

            else => {},
        }

        // ── Process incoming commands from relay ─────────────────
        while (session.popCommand()) |cmd| {
            switch (cmd.action) {
                .play => {
                    guard.suppress_pause = true;
                    last_pause_state = false;
                    if (cmd.time > 0) {
                        guard.suppress_time = true;
                        mpv.setPropertyDouble(handle, "time-pos", cmd.time) catch {};
                    }
                    mpv.setPropertyFlag(handle, "pause", false) catch {};
                    mpv.osdMessage(handle, allocator, "▶ Synced play", .{}, 1.5);
                },
                .pause => {
                    guard.suppress_pause = true;
                    last_pause_state = true;
                    mpv.setPropertyFlag(handle, "pause", true) catch {};
                    mpv.osdMessage(handle, allocator, "⏸ Synced pause", .{}, 1.5);
                },
                .seek => {
                    guard.remote_seek_target = cmd.time;
                    guard.suppress_time = true;
                    mpv.setPropertyDouble(handle, "time-pos", cmd.time) catch {};
                    mpv.osdMessage(handle, allocator, "⏩ Synced seek", .{}, 1.5);
                },
                .force_sync_prepare => {
                    guard.suppress_pause = true;
                    last_pause_state = true;
                    guard.remote_seek_target = cmd.time;
                    guard.suppress_time = true;
                    mpv.setPropertyFlag(handle, "pause", true) catch {};
                    mpv.setPropertyDouble(handle, "time-pos", cmd.time) catch {};
                    mpv.osdMessage(handle, allocator, "🔄 Force Sync preparing…", .{}, 2.0);
                },
                .force_sync_execute => {
                    guard.suppress_pause = true;
                    last_pause_state = false;
                    mpv.setPropertyFlag(handle, "pause", false) catch {};
                    mpv.osdMessage(handle, allocator, "▶ Synced", .{}, 1.5);
                },
                .noop => {
                    if (!joined_shown) {
                        joined_shown = true;
                        mpv.osdMessage(handle, allocator, "KoalaSync: joined room \"{s}\" ✓", .{cfg.room}, 3);
                        // Send initial playback state immediately upon joining
                        const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
                        const is_paused = mpv.getPropertyFlag(handle, "pause") catch (last_pause_state orelse false);
                        session.pushEvent(.{ .kind = .heartbeat, .time = time, .paused = is_paused });
                    }
                },
            }
        }

        // ── Periodic heartbeat ──────────────────────────────────
        const now = time_util.milliTimestamp();
        if (now - last_heartbeat >= @as(i64, @intCast(K.heartbeat_interval_ms))) {
            last_heartbeat = now;
            if (session.state == .joined) {
                const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
                const is_paused = mpv.getPropertyFlag(handle, "pause") catch (last_pause_state orelse false);
                session.pushEvent(.{ .kind = .heartbeat, .time = time, .paused = is_paused });
            }
        }
    }
}
