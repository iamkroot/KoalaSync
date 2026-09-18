/// KoalaSync mpv C plugin — entry point.
///
/// Exports `mpv_open_cplugin` which mpv calls on a dedicated thread
/// when loading the shared library. Sets up property observation,
/// spawns the network thread, and runs the main event loop that
/// translates between mpv events, user controls, and KoalaSync protocol commands.
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
const POLL_INTERVAL: f64 = 0.05;

// ── Loop guard ──────────────────────────────────────────────────
/// When we apply a remote command (e.g. set pause=yes), the resulting
/// property-change event must be suppressed so we don't echo it back
/// to the relay. These flags implement that guard.
const LoopGuard = struct {
    suppress_pause: bool = false,
    suppress_time: bool = false,

    // Timestamp of last remote seek so we can distinguish the
    // property-change echo from genuine user seeks.
    remote_seek_target: f64 = -1,
};

// ── Menu State ──────────────────────────────────────────────────
const OVERLAY_ID_MENU: u32 = 1;
const OVERLAY_ID_HUD: u32 = 2;

const MenuActionKind = enum {
    join_favorite,
    toggle_sync,
    force_sync,
    catch_up,
    fav_add,
    fav_remove,
    join_prompt,
    leave_room,
    close,
};

const MenuAction = struct {
    kind: MenuActionKind,
    fav_idx: usize = 0,
    label: [64]u8 = undefined,
    label_len: usize = 0,

    pub fn text(self: *const MenuAction) []const u8 {
        return self.label[0..self.label_len];
    }
};

fn buildMenuActions(
    actions: []MenuAction,
    session: *protocol.Session,
    favorites: []const config_mod.FavoriteRoom,
) usize {
    var count: usize = 0;
    var r_buf: [64]u8 = undefined;
    const room_name = session.getRoomName(&r_buf);
    const in_standby = (room_name == null);

    if (!in_standby) {
        // Active room actions
        actions[count] = .{ .kind = .force_sync };
        const l1 = "Force Sync Room Position";
        @memcpy(actions[count].label[0..l1.len], l1);
        actions[count].label_len = l1.len;
        count += 1;

        actions[count] = .{ .kind = .toggle_sync };
        const l2 = "Toggle Sync Mute";
        @memcpy(actions[count].label[0..l2.len], l2);
        actions[count].label_len = l2.len;
        count += 1;

        actions[count] = .{ .kind = .catch_up };
        const l3 = "Catch Up to Room";
        @memcpy(actions[count].label[0..l3.len], l3);
        actions[count].label_len = l3.len;
        count += 1;

        var is_fav = false;
        for (favorites) |fav| {
            if (std.mem.eql(u8, fav.room, room_name.?)) {
                is_fav = true;
                break;
            }
        }
        if (is_fav) {
            actions[count] = .{ .kind = .fav_remove };
            const l_rem = "★ Remove Room from Favorites";
            @memcpy(actions[count].label[0..l_rem.len], l_rem);
            actions[count].label_len = l_rem.len;
            count += 1;
        } else {
            actions[count] = .{ .kind = .fav_add };
            const l_add = "★ Save Room to Favorites";
            @memcpy(actions[count].label[0..l_add.len], l_add);
            actions[count].label_len = l_add.len;
            count += 1;
        }

        var switches: usize = 0;
        for (favorites, 0..) |fav, i| {
            if (switches >= 3) break;
            if (!std.mem.eql(u8, fav.room, room_name.?)) {
                actions[count] = .{ .kind = .join_favorite, .fav_idx = i };
                const sw_txt = std.fmt.bufPrint(&actions[count].label, "Switch to: {s}", .{fav.label}) catch fav.label;
                actions[count].label_len = sw_txt.len;
                count += 1;
                switches += 1;
            }
        }

        actions[count] = .{ .kind = .join_prompt };
        const l4 = "Join / Switch Other Room…";
        @memcpy(actions[count].label[0..l4.len], l4);
        actions[count].label_len = l4.len;
        count += 1;

        actions[count] = .{ .kind = .leave_room };
        const l5 = "Leave Room & Standby";
        @memcpy(actions[count].label[0..l5.len], l5);
        actions[count].label_len = l5.len;
        count += 1;
    } else {
        // Standby mode actions
        for (favorites, 0..) |fav, i| {
            if (count >= 5) break;
            actions[count] = .{ .kind = .join_favorite, .fav_idx = i };
            const fav_txt = std.fmt.bufPrint(&actions[count].label, "★ Join: {s}", .{fav.label}) catch fav.label;
            actions[count].label_len = fav_txt.len;
            count += 1;
        }

        actions[count] = .{ .kind = .join_prompt };
        const l_jp = "Join Other Room…";
        @memcpy(actions[count].label[0..l_jp.len], l_jp);
        actions[count].label_len = l_jp.len;
        count += 1;

        actions[count] = .{ .kind = .toggle_sync };
        const l_ts = "Toggle Sync Mute";
        @memcpy(actions[count].label[0..l_ts.len], l_ts);
        actions[count].label_len = l_ts.len;
        count += 1;
    }

    actions[count] = .{ .kind = .close };
    const l_cl = "Close Menu";
    @memcpy(actions[count].label[0..l_cl.len], l_cl);
    actions[count].label_len = l_cl.len;
    count += 1;

    return count;
}

const MenuState = struct {
    is_open: bool = false,
    is_uosc: bool = false,
    selected_index: usize = 0,
};

const HudState = struct {
    is_open: bool = false,
    expires_at: i64 = 0,
};

// ── Helpers ─────────────────────────────────────────────────────

fn formatTime(buf: []u8, seconds: f64) []const u8 {
    const s = @as(u64, @intFromFloat(@max(0, seconds)));
    const hours = s / 3600;
    const mins = (s % 3600) / 60;
    const secs = s % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch "00:00:00";
    } else {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch "00:00";
    }
}

fn formatDiff(buf: []u8, diff_sec: f64) []const u8 {
    const abs_diff = @abs(diff_sec);
    if (abs_diff < 1.0) {
        return "In sync";
    }
    const sign: []const u8 = if (diff_sec > 0) "+" else "-";
    if (abs_diff < 60.0) {
        return std.fmt.bufPrint(buf, "{s}{d:.0}s", .{ sign, abs_diff }) catch "diff";
    } else {
        const s = @as(u64, @intFromFloat(abs_diff));
        const mins = s / 60;
        const secs = s % 60;
        return std.fmt.bufPrint(buf, "{s}{d}m{d:0>2}s", .{ sign, mins, secs }) catch "diff";
    }
}

fn isUoscPresent(handle: mpv.Handle, allocator: std.mem.Allocator, has_uosc: bool) bool {
    if (has_uosc) return true;
    if (mpv.getPropertyString(handle, allocator, "input-bindings") catch null) |binds| {
        defer allocator.free(binds);
        if (std.mem.indexOf(u8, binds, "uosc") != null) return true;
    }
    return false;
}

// ── Entry point ─────────────────────────────────────────────────

export fn mpv_open_cplugin(handle: *c.mpv_handle) callconv(.c) c_int {
    main_impl(@ptrCast(handle)) catch return -1;
    return 0;
}

fn main_impl(handle: mpv.Handle) !void {
    const allocator = std.heap.c_allocator;

    // ── Load config ─────────────────────────────────────────────
    var cfg = config_mod.load(handle, allocator) catch |e| {
        mpv.osdMessage(handle, allocator, "KoalaSync: config load error", .{}, 3);
        return e;
    };
    defer cfg.deinit();

    // ── Register default keybindings ────────────────────────────
    const default_bindings =
        "ctrl+k script-message koalasync-menu\n" ++
        "c script-message koalasync-menu\n" ++
        "ctrl+shift+j script-message koalasync-join-prompt\n" ++
        "ctrl+shift+s script-message koalasync-force-sync\n" ++
        "alt+s script-message koalasync-force-sync\n" ++
        "ctrl+shift+t script-message koalasync-toggle-sync\n" ++
        "ctrl+shift+r script-message koalasync-resync\n" ++
        "ctrl+shift+i script-message koalasync-status\n" ++
        "tab script-message koalasync-status\n" ++
        "ctrl+shift+l script-message koalasync-leave\n" ++
        "ctrl+shift+f script-message koalasync-fav-toggle";

    mpv.defineSection(handle, "koalasync", default_bindings, "default");
    mpv.enableSection(handle, "koalasync", "default");

    // ── Register menu navigation keys ───────────────────────────
    const menu_nav_bindings =
        "up script-message koalasync-menu-nav up\n" ++
        "k script-message koalasync-menu-nav up\n" ++
        "down script-message koalasync-menu-nav down\n" ++
        "j script-message koalasync-menu-nav down\n" ++
        "enter script-message koalasync-menu-select\n" ++
        "esc script-message koalasync-menu-close\n" ++
        "ctrl+k script-message koalasync-menu-close\n" ++
        "c script-message koalasync-menu-close";

    mpv.defineSection(handle, "koalasync-menu", menu_nav_bindings, "force");

    // ── Favorites state ─────────────────────────────────────────
    var favorites: std.ArrayList(config_mod.FavoriteRoom) = .empty;
    defer {
        for (favorites.items) |fav| {
            allocator.free(fav.room);
            allocator.free(fav.password);
            allocator.free(fav.label);
        }
        favorites.deinit(allocator);
    }
    for (cfg.favorites) |fav| {
        try favorites.append(allocator, try fav.clone(allocator));
    }

    // ── Initial user feedback ───────────────────────────────────
    const should_autojoin = cfg.autojoin and cfg.room != null;
    if (should_autojoin) {
        mpv.osdMessage(handle, allocator, "KoalaSync: connecting to room \"{s}\"…", .{cfg.room.?}, 3.0);
    } else {
        if (favorites.items.len > 0) {
            mpv.osdMessage(handle, allocator, "KoalaSync: ready • Press Ctrl+K for menu (★ {d} favorites)", .{favorites.items.len}, 4.0);
        } else {
            mpv.osdMessage(handle, allocator, "KoalaSync: ready • Press Ctrl+K for menu or Ctrl+Shift+J to join", .{}, 4.0);
        }
    }

    // ── Set up protocol session ─────────────────────────────────
    var session = try protocol.Session.init(
        allocator,
        cfg.server,
        if (should_autojoin) cfg.room else null,
        if (should_autojoin) cfg.password else "",
        cfg.peer_id,
        cfg.username,
    );
    defer session.deinit();

    // ── Check initial media title if already loaded ────────────
    if (mpv.getPropertyString(handle, allocator, "media-title") catch null) |initial_title| {
        session.setMediaTitle(initial_title);
        allocator.free(initial_title);
    }

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
    var last_pause_state: ?bool = null;

    var menu_state = MenuState{};
    var hud_state = HudState{};
    var has_uosc: bool = false;
    var last_menu_update: i64 = 0;

    // ── Main event loop ─────────────────────────────────────────
    while (true) {
        const event = mpv.waitEvent(handle, POLL_INTERVAL);

        // Check HUD expiration
        const now = time_util.milliTimestamp();
        if (hud_state.is_open and now >= hud_state.expires_at) {
            mpv.clearOsdOverlay(handle, OVERLAY_ID_HUD);
            hud_state.is_open = false;
        }

        switch (event.event_id) {
            c.MPV_EVENT_SHUTDOWN => break,

            c.MPV_EVENT_CLIENT_MESSAGE => {
                const raw_data = event.data orelse continue;
                const msg: *const mpv.EventClientMessage = @ptrCast(@alignCast(raw_data));
                if (msg.num_args > 0) {
                    const args = msg.args orelse continue;
                    const arg0 = args[0] orelse continue;
                    const cmd_name = std.mem.sliceTo(arg0, 0);

                    if (std.mem.eql(u8, cmd_name, "koalasync-join")) {
                        if (msg.num_args > 1 and args[1] != null) {
                            const target_room = std.mem.sliceTo(args[1].?, 0);
                            const target_pass: ?[]const u8 = if (msg.num_args > 2 and args[2] != null) std.mem.sliceTo(args[2].?, 0) else null;
                            session.requestJoin(target_room, target_pass);
                            mpv.osdMessage(handle, allocator, "KoalaSync: connecting to room \"{s}\"…", .{target_room}, 3.0);
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-join-prompt")) {
                        var prompt_buf: [128]u8 = undefined;
                        const default_prompt: [*:0]const u8 = "script-message-to console type \"script-message koalasync-join \"";
                        const prompt_cmd: [*:0]const u8 = if (favorites.items.len > 0)
                            if (std.fmt.bufPrintZ(&prompt_buf, "script-message-to console type \"script-message koalasync-join {s} \"", .{favorites.items[0].room})) |z|
                                z.ptr
                            else |_|
                                default_prompt
                        else
                            default_prompt;
                        mpv.commandString(handle, prompt_cmd) catch {
                            mpv.osdMessage(handle, allocator, "KoalaSync: run :script-message koalasync-join <room> [pass]", .{}, 4.0);
                        };
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-join-fav")) {
                        if (msg.num_args > 1 and args[1] != null) {
                            const arg_str = std.mem.sliceTo(args[1].?, 0);
                            const fav_num = std.fmt.parseInt(usize, arg_str, 10) catch 0;
                            if (fav_num >= 1 and fav_num <= favorites.items.len) {
                                const fav = favorites.items[fav_num - 1];
                                const pass: ?[]const u8 = if (fav.password.len > 0) fav.password else null;
                                session.requestJoin(fav.room, pass);
                                mpv.osdMessage(handle, allocator, "KoalaSync: connecting to ★ \"{s}\"…", .{fav.label}, 3.0);
                            }
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-fav-add")) {
                        var r_buf: [64]u8 = undefined;
                        if (session.getRoomName(&r_buf)) |r_name| {
                            var exists = false;
                            for (favorites.items) |fav| {
                                if (std.mem.eql(u8, fav.room, r_name)) {
                                    exists = true;
                                    break;
                                }
                            }
                            if (!exists) {
                                const new_fav = config_mod.FavoriteRoom{
                                    .room = try allocator.dupe(u8, r_name),
                                    .password = try allocator.dupe(u8, session.password),
                                    .label = try allocator.dupe(u8, r_name),
                                };
                                try favorites.append(allocator, new_fav);
                                config_mod.saveFavorites(allocator, favorites.items);
                                mpv.osdMessage(handle, allocator, "★ Added \"{s}\" to favorites ✓", .{r_name}, 2.5);
                                if (menu_state.is_open) {
                                    if (menu_state.is_uosc) renderUoscMenu(handle, &session, favorites.items, true) else renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-fav-remove")) {
                        var r_buf: [64]u8 = undefined;
                        if (session.getRoomName(&r_buf)) |r_name| {
                            for (favorites.items, 0..) |fav, i| {
                                if (std.mem.eql(u8, fav.room, r_name)) {
                                    allocator.free(fav.room);
                                    allocator.free(fav.password);
                                    allocator.free(fav.label);
                                    _ = favorites.orderedRemove(i);
                                    config_mod.saveFavorites(allocator, favorites.items);
                                    mpv.osdMessage(handle, allocator, "Removed \"{s}\" from favorites", .{r_name}, 2.5);
                                    if (menu_state.is_open) {
                                        if (menu_state.is_uosc) renderUoscMenu(handle, &session, favorites.items, true) else renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                                    }
                                    break;
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-fav-toggle")) {
                        var r_buf: [64]u8 = undefined;
                        if (session.getRoomName(&r_buf)) |r_name| {
                            var found_idx: ?usize = null;
                            for (favorites.items, 0..) |fav, i| {
                                if (std.mem.eql(u8, fav.room, r_name)) {
                                    found_idx = i;
                                    break;
                                }
                            }
                            if (found_idx) |i| {
                                allocator.free(favorites.items[i].room);
                                allocator.free(favorites.items[i].password);
                                allocator.free(favorites.items[i].label);
                                _ = favorites.orderedRemove(i);
                                config_mod.saveFavorites(allocator, favorites.items);
                                mpv.osdMessage(handle, allocator, "Removed \"{s}\" from favorites", .{r_name}, 2.5);
                            } else {
                                const new_fav = config_mod.FavoriteRoom{
                                    .room = try allocator.dupe(u8, r_name),
                                    .password = try allocator.dupe(u8, session.password),
                                    .label = try allocator.dupe(u8, r_name),
                                };
                                try favorites.append(allocator, new_fav);
                                config_mod.saveFavorites(allocator, favorites.items);
                                mpv.osdMessage(handle, allocator, "★ Added \"{s}\" to favorites ✓", .{r_name}, 2.5);
                            }
                            if (menu_state.is_open) {
                                if (menu_state.is_uosc) renderUoscMenu(handle, &session, favorites.items, true) else renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                            }
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-leave")) {
                        session.requestLeave();
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-force-sync")) {
                        const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
                        session.requestForceSync(time);
                        mpv.osdMessage(handle, allocator, "▶▶ Initiating Force Sync at {d:.0}s…", .{time}, 2.5);
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-toggle-sync")) {
                        const muted = session.toggleSyncMute();
                        if (menu_state.is_open) {
                            if (menu_state.is_uosc) {
                                renderUoscMenu(handle, &session, favorites.items, true);
                            } else {
                                renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                            }
                        }
                        if (muted) {
                            mpv.osdMessage(handle, allocator, "⏸ KoalaSync: Sync Muted (local playback decoupled)", .{}, 3.0);
                        } else {
                            mpv.osdMessage(handle, allocator, "▶ KoalaSync: Sync Active (re-coupled)", .{}, 3.0);
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-seek-to")) {
                        if (msg.num_args > 1 and args[1] != null) {
                            const t_str = std.mem.sliceTo(args[1].?, 0);
                            if (std.fmt.parseFloat(f64, t_str)) |target_time| {
                                guard.suppress_time = true;
                                mpv.setPropertyDouble(handle, "time-pos", target_time) catch {};
                                var t_buf: [16]u8 = undefined;
                                mpv.osdMessage(handle, allocator, "⏩ Synced to peer at {s}", .{formatTime(&t_buf, target_time)}, 2.0);
                            } else |_| {}
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-resync")) {
                        const room_time = session.getLastRoomTime();
                        if (room_time > 0) {
                            guard.suppress_time = true;
                            mpv.setPropertyDouble(handle, "time-pos", room_time) catch {};
                            mpv.osdMessage(handle, allocator, "⏩ Caught up to room at {d:.0}s", .{room_time}, 2.0);
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-status")) {
                        toggleHud(handle, allocator, &session, &hud_state);
                    } else if (std.mem.eql(u8, cmd_name, "uosc-version")) {
                        has_uosc = true;
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-menu")) {
                        toggleMenu(handle, allocator, &session, favorites.items, &menu_state, has_uosc);
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-menu-nav")) {
                        if (msg.num_args > 1 and args[1] != null) {
                            const dir = std.mem.sliceTo(args[1].?, 0);
                            var actions: [16]MenuAction = undefined;
                            const action_count = buildMenuActions(&actions, &session, favorites.items);
                            menuNav(&menu_state, dir, action_count);
                            renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                        }
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-menu-select")) {
                        menuSelect(handle, allocator, &session, &favorites, &menu_state, &guard);
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-menu-close")) {
                        closeMenu(handle, &menu_state);
                    } else if (std.mem.eql(u8, cmd_name, "koalasync-menu-closed")) {
                        menu_state.is_open = false;
                    }
                }
            },

            c.MPV_EVENT_PROPERTY_CHANGE => {
                const raw_data = event.data orelse continue;
                const prop: *mpv.EventProperty = @ptrCast(@alignCast(raw_data));
                switch (event.reply_userdata) {
                    UD_PAUSE => {
                        if (prop.data) |data| {
                            const paused = @as(*const c_int, @ptrCast(@alignCast(data))).* != 0;

                            if (guard.suppress_pause) {
                                guard.suppress_pause = false;
                                last_pause_state = paused;
                                continue;
                            }

                            // Skip duplicate pause states
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
                                    // Echo from remote seek
                                    guard.remote_seek_target = -1;
                                } else if (session.state == .joined) {
                                    session.pushEvent(.{ .kind = .seek, .time = time });
                                }
                            }
                            last_time = time;
                        }
                    },
                    UD_MEDIA_TITLE => {
                        if (prop.data) |data| {
                            const str_ptr = @as(*const ?[*:0]const u8, @ptrCast(@alignCast(data))).*;
                            if (str_ptr) |s| {
                                session.setMediaTitle(std.mem.sliceTo(s, 0));
                            } else {
                                session.setMediaTitle("");
                            }
                        }
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
                    mpv.osdMessage(handle, allocator, "▶▶ Force Sync preparing…", .{}, 2.0);
                },
                .force_sync_execute => {
                    guard.suppress_pause = true;
                    last_pause_state = false;
                    mpv.setPropertyFlag(handle, "pause", false) catch {};
                    mpv.osdMessage(handle, allocator, "▶ Synced", .{}, 1.5);
                },
                .force_sync_done => {
                    mpv.osdMessage(handle, allocator, "▶ Room force sync complete", .{}, 2.0);
                },
                .initial_sync => {
                    var r_buf: [64]u8 = undefined;
                    const r_name = session.getRoomName(&r_buf) orelse "room";

                    const is_playing = (cmd.playback_state orelse .paused) == .playing;
                    guard.remote_seek_target = cmd.time;
                    guard.suppress_time = true;
                    guard.suppress_pause = true;
                    last_pause_state = !is_playing;
                    mpv.setPropertyDouble(handle, "time-pos", cmd.time) catch {};
                    mpv.setPropertyFlag(handle, "pause", !is_playing) catch {};

                    const symbol: []const u8 = if (is_playing) "▶" else "⏸";
                    mpv.osdMessage(handle, allocator, "KoalaSync: joined \"{s}\" ({s} {d:.0}s) ✓", .{ r_name, symbol, cmd.time }, 3.5);
                },
                .peer_joined => {
                    mpv.osdMessage(handle, allocator, "• {s} joined the room", .{cmd.text()}, 3.0);
                    if (menu_state.is_open) {
                        if (menu_state.is_uosc) {
                            renderUoscMenu(handle, &session, favorites.items, true);
                        } else {
                            renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                        }
                    }
                },
                .peer_left => {
                    mpv.osdMessage(handle, allocator, "• {s} left the room", .{cmd.text()}, 3.0);
                    if (menu_state.is_open) {
                        if (menu_state.is_uosc) {
                            renderUoscMenu(handle, &session, favorites.items, true);
                        } else {
                            renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                        }
                    }
                },
                .left_room => {
                    mpv.osdMessage(handle, allocator, "KoalaSync: left room • Disconnected", .{}, 3.0);
                    if (menu_state.is_open) {
                        if (menu_state.is_uosc) {
                            renderUoscMenu(handle, &session, favorites.items, true);
                        } else {
                            renderMenu(handle, allocator, &session, favorites.items, &menu_state);
                        }
                    }
                },
                .control_mode_changed => {
                    mpv.osdMessage(handle, allocator, "KoalaSync: control mode is \"{s}\"", .{cmd.text()}, 3.0);
                },
                .error_msg => {
                    mpv.osdMessage(handle, allocator, "KoalaSync error: {s}", .{cmd.text()}, 5.0);
                    mpv.log(handle, allocator, "Error from relay: {s}", .{cmd.text()});
                },
                .noop => {
                    var r_buf: [64]u8 = undefined;
                    const r_name = session.getRoomName(&r_buf) orelse "room";
                    mpv.osdMessage(handle, allocator, "KoalaSync: joined room \"{s}\" ✓", .{r_name}, 3.0);

                    const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
                    const is_paused = mpv.getPropertyFlag(handle, "pause") catch (last_pause_state orelse false);
                    session.pushEvent(.{ .kind = .heartbeat, .time = time, .paused = is_paused });
                },
            }
        }

        // ── Keep session local playback state fresh ─────────────
        const cur_time = mpv.getPropertyDouble(handle, "time-pos") catch last_time;
        const cur_paused = mpv.getPropertyFlag(handle, "pause") catch (last_pause_state orelse false);
        session.updateLocalState(cur_time, cur_paused);

        // ── Periodic live menu refresh (1000ms, only when open) ─
        if (menu_state.is_open and now - last_menu_update >= 1000) {
            last_menu_update = now;
            if (menu_state.is_uosc) {
                var is_still_open = true;
                if (mpv.getPropertyString(handle, allocator, "user-data/uosc/menu/type") catch null) |mtype| {
                    defer allocator.free(mtype);
                    if (!std.mem.eql(u8, mtype, "koalasync")) {
                        is_still_open = false;
                    }
                }
                if (is_still_open) {
                    renderUoscMenu(handle, &session, favorites.items, true);
                } else {
                    menu_state.is_open = false;
                }
            } else {
                renderMenu(handle, allocator, &session, favorites.items, &menu_state);
            }
        }

        // ── Periodic heartbeat ──────────────────────────────────
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

// ── UI Controller Functions ─────────────────────────────────────

fn toggleMenu(
    handle: mpv.Handle,
    allocator: std.mem.Allocator,
    session: *protocol.Session,
    favorites: []const config_mod.FavoriteRoom,
    state: *MenuState,
    has_uosc: bool,
) void {
    if (state.is_open) {
        closeMenu(handle, state);
        return;
    }

    state.is_open = true;

    // Check if uosc is running
    if (isUoscPresent(handle, allocator, has_uosc)) {
        state.is_uosc = true;
        renderUoscMenu(handle, session, favorites, false);
        return;
    }

    // Fall back to built-in ASS menu
    state.is_uosc = false;
    state.selected_index = 0;
    mpv.enableSection(handle, "koalasync-menu", "force");
    renderMenu(handle, allocator, session, favorites, state);
}

fn closeMenu(handle: mpv.Handle, state: *MenuState) void {
    if (!state.is_open) return;
    state.is_open = false;
    if (state.is_uosc) {
        const cmd = [_:null]?[*:0]const u8{ "script-message-to", "uosc", "close-menu", "koalasync", null };
        _ = mpv.command(handle, cmd);
    } else {
        mpv.disableSection(handle, "koalasync-menu");
        mpv.clearOsdOverlay(handle, OVERLAY_ID_MENU);
    }
}

fn menuNav(state: *MenuState, dir: []const u8, action_count: usize) void {
    if (!state.is_open or action_count == 0) return;
    if (std.mem.eql(u8, dir, "up")) {
        if (state.selected_index == 0) {
            state.selected_index = action_count - 1;
        } else {
            state.selected_index -= 1;
        }
    } else if (std.mem.eql(u8, dir, "down")) {
        state.selected_index = (state.selected_index + 1) % action_count;
    }
}

fn menuSelect(
    handle: mpv.Handle,
    allocator: std.mem.Allocator,
    session: *protocol.Session,
    favorites: *std.ArrayList(config_mod.FavoriteRoom),
    state: *MenuState,
    guard: *LoopGuard,
) void {
    if (!state.is_open) return;

    var actions: [16]MenuAction = undefined;
    const action_count = buildMenuActions(&actions, session, favorites.items);
    if (state.selected_index >= action_count) state.selected_index = 0;

    const action = actions[state.selected_index];
    switch (action.kind) {
        .join_favorite => {
            closeMenu(handle, state);
            if (action.fav_idx < favorites.items.len) {
                const fav = favorites.items[action.fav_idx];
                const pass: ?[]const u8 = if (fav.password.len > 0) fav.password else null;
                session.requestJoin(fav.room, pass);
                mpv.osdMessage(handle, allocator, "KoalaSync: connecting to room \"{s}\"…", .{fav.room}, 3.0);
            }
        },
        .fav_add => {
            var r_buf: [64]u8 = undefined;
            if (session.getRoomName(&r_buf)) |r_name| {
                const new_fav = config_mod.FavoriteRoom{
                    .room = allocator.dupe(u8, r_name) catch return,
                    .password = allocator.dupe(u8, session.password) catch "",
                    .label = allocator.dupe(u8, r_name) catch "",
                };
                favorites.append(allocator, new_fav) catch {};
                config_mod.saveFavorites(allocator, favorites.items);
                mpv.osdMessage(handle, allocator, "★ Added \"{s}\" to favorites ✓", .{r_name}, 2.0);
                renderMenu(handle, allocator, session, favorites.items, state);
            }
        },
        .fav_remove => {
            var r_buf: [64]u8 = undefined;
            if (session.getRoomName(&r_buf)) |r_name| {
                for (favorites.items, 0..) |fav, i| {
                    if (std.mem.eql(u8, fav.room, r_name)) {
                        allocator.free(fav.room);
                        allocator.free(fav.password);
                        allocator.free(fav.label);
                        _ = favorites.orderedRemove(i);
                        config_mod.saveFavorites(allocator, favorites.items);
                        mpv.osdMessage(handle, allocator, "Removed \"{s}\" from favorites", .{r_name}, 2.0);
                        renderMenu(handle, allocator, session, favorites.items, state);
                        break;
                    }
                }
            }
        },
        .force_sync => {
            closeMenu(handle, state);
            const time = mpv.getPropertyDouble(handle, "time-pos") catch 0;
            session.requestForceSync(time);
            mpv.osdMessage(handle, allocator, "▶▶ Initiating Force Sync at {d:.0}s…", .{time}, 2.5);
        },
        .toggle_sync => {
            const muted = session.toggleSyncMute();
            renderMenu(handle, allocator, session, favorites.items, state);
            if (muted) {
                mpv.osdMessage(handle, allocator, "⏸ Sync Muted", .{}, 1.5);
            } else {
                mpv.osdMessage(handle, allocator, "▶ Sync Active", .{}, 1.5);
            }
        },
        .catch_up => {
            closeMenu(handle, state);
            const room_time = session.getLastRoomTime();
            if (room_time > 0) {
                guard.suppress_time = true;
                mpv.setPropertyDouble(handle, "time-pos", room_time) catch {};
                mpv.osdMessage(handle, allocator, "⏩ Caught up to {d:.0}s", .{room_time}, 2.0);
            }
        },
        .join_prompt => {
            closeMenu(handle, state);
            var prompt_buf: [128]u8 = undefined;
            const default_prompt: [*:0]const u8 = "script-message-to console type \"script-message koalasync-join \"";
            const prompt_cmd: [*:0]const u8 = if (favorites.items.len > 0)
                if (std.fmt.bufPrintZ(&prompt_buf, "script-message-to console type \"script-message koalasync-join {s} \"", .{favorites.items[0].room})) |z|
                    z.ptr
                else |_|
                    default_prompt
            else
                default_prompt;
            mpv.commandString(handle, prompt_cmd) catch {
                mpv.osdMessage(handle, allocator, "KoalaSync: run :script-message koalasync-join <room>", .{}, 3.0);
            };
        },
        .leave_room => {
            closeMenu(handle, state);
            session.requestLeave();
        },
        .close => {
            closeMenu(handle, state);
        },
    }
}

fn renderMenu(
    handle: mpv.Handle,
    allocator: std.mem.Allocator,
    session: *protocol.Session,
    favorites: []const config_mod.FavoriteRoom,
    state: *MenuState,
) void {
    _ = allocator;
    if (!state.is_open) return;

    var r_buf: [64]u8 = undefined;
    const room_name = session.getRoomName(&r_buf) orelse "(none - standby)";

    var peers_buf: [16]protocol.PeerInfo = undefined;
    const peer_count = session.getRosterSnapshot(&peers_buf);
    const ping = session.getServerPing();
    const is_muted = session.isSyncMuted();
    const sync_status_str = if (is_muted) "MUTED ⏸" else "ACTIVE ▶";

    var actions: [16]MenuAction = undefined;
    const action_count = buildMenuActions(&actions, session, favorites);
    if (state.selected_index >= action_count) state.selected_index = 0;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Box header
    const header = std.fmt.bufPrint(
        buf[pos..],
        "{{\\an5\\bord2\\shad1\\fs28\\c&HFFFFFF&}}" ++
            "{{\\b1\\c&H00D7FF&}}[KoalaSync]{{\\c&HFFFFFF&\\b0}} • Room: {{\\c&H00FF88&}}\"{s}\"{{\\c&HFFFFFF&}} • {d} in room\\N" ++
            "{{\\fs22}}Ping: {d}ms • Sync: {{\\b1}}{s}{{\\b0}}\\N\\N",
        .{ room_name, peer_count, ping, sync_status_str },
    ) catch return;
    pos += header.len;

    // Menu options
    for (actions[0..action_count], 0..) |*act, idx| {
        const selected = (idx == state.selected_index);
        const line = if (selected)
            std.fmt.bufPrint(buf[pos..], "{{\\fs24\\c&H00D7FF&\\b1}}  ► [{d}] {s}{{\\b0\\c&HFFFFFF&}}\\N", .{ idx + 1, act.text() }) catch return
        else
            std.fmt.bufPrint(buf[pos..], "{{\\fs24\\c&HCCCCCC&}}    [{d}] {s}\\N", .{ idx + 1, act.text() }) catch return;
        pos += line.len;
    }

    // Peers section
    if (peer_count > 0) {
        const title = std.fmt.bufPrint(buf[pos..], "\\N{{\\fs20\\c&H999999&}}--- Room members ---\\N", .{}) catch return;
        pos += title.len;

        // Entry 0: You
        {
            var t_buf: [16]u8 = undefined;
            const t_str = formatTime(&t_buf, peers_buf[0].time_pos);
            const p_symbol = if (peers_buf[0].is_paused) "⏸" else "▶";
            const line = std.fmt.bufPrint(buf[pos..], "{{\\fs22}}  • {{\\c&H00FF88&}}{s}{{\\c&HFFFFFF&}} ({s} {s})\\N", .{ peers_buf[0].username(), p_symbol, t_str }) catch return;
            pos += line.len;
        }

        // Entries 1..N: Remote peers
        if (peer_count > 1) {
            for (peers_buf[1..peer_count]) |p| {
                const diff = p.time_pos - session.local_time;
                var d_buf: [16]u8 = undefined;
                const d_str = formatDiff(&d_buf, diff);
                const p_symbol = if (p.is_paused) "⏸" else "▶";

                if (p.is_paused) {
                    var t_buf: [16]u8 = undefined;
                    const t_str = formatTime(&t_buf, p.time_pos);
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs22}}  • {s} (⏸ Paused at {s}) [{d}ms]\\N", .{ p.username(), t_str, p.ping_ms }) catch return;
                    pos += line.len;
                } else if (@abs(diff) < 1.0) {
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs22}}  • {s} (▶ In sync) [{d}ms]\\N", .{ p.username(), p.ping_ms }) catch return;
                    pos += line.len;
                } else {
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs22}}  • {s} ({s} {s}) [{d}ms]\\N", .{ p.username(), p_symbol, d_str, p.ping_ms }) catch return;
                    pos += line.len;
                }
            }
        }
    }

    // Footer
    const footer = std.fmt.bufPrint(buf[pos..], "\\N{{\\fs18\\c&H777777&}}[↑/↓] Navigate • [Enter] Select • [Esc] Close", .{}) catch return;
    pos += footer.len;

    buf[pos] = 0;
    const z_str: [:0]const u8 = buf[0..pos :0];
    mpv.showOsdOverlay(handle, OVERLAY_ID_MENU, z_str.ptr);
}

fn toggleHud(handle: mpv.Handle, allocator: std.mem.Allocator, session: *protocol.Session, hud: *HudState) void {
    _ = allocator;
    if (hud.is_open) {
        mpv.clearOsdOverlay(handle, OVERLAY_ID_HUD);
        hud.is_open = false;
        return;
    }

    var r_buf: [64]u8 = undefined;
    const room_name = session.getRoomName(&r_buf) orelse "(none - standby)";

    var peers_buf: [16]protocol.PeerInfo = undefined;
    const peer_count = session.getRosterSnapshot(&peers_buf);
    const ping = session.getServerPing();
    const is_muted = session.isSyncMuted();
    const sync_status_str = if (is_muted) "MUTED ⏸" else "ACTIVE ▶";

    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    const header = std.fmt.bufPrint(
        buf[pos..],
        "{{\\an7\\pos(30,45)\\bord2\\shad1\\fs22\\c&HFFFFFF&}}" ++
            "{{\\b1\\c&H00D7FF&}}[KoalaSync]{{\\c&HFFFFFF&\\b0}} • Room: {{\\c&H00FF88&}}\"{s}\"{{\\c&HFFFFFF&}} • Ping: {d}ms • Sync: {s}\\N",
        .{ room_name, ping, sync_status_str },
    ) catch return;
    pos += header.len;

    if (peer_count > 0) {
        const title = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}Peers:\\N", .{}) catch return;
        pos += title.len;

        // Entry 0: You
        {
            var t_buf: [16]u8 = undefined;
            const t_str = formatTime(&t_buf, peers_buf[0].time_pos);
            const p_symbol = if (peers_buf[0].is_paused) "⏸" else "▶";
            const line = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}  • {{\\c&H00FF88&}}{s}{{\\c&HFFFFFF&}}: {s} {s}\\N", .{ peers_buf[0].username(), p_symbol, t_str }) catch return;
            pos += line.len;
        }

        // Entries 1..N: Remote peers
        if (peer_count > 1) {
            for (peers_buf[1..peer_count]) |p| {
                const diff = p.time_pos - session.local_time;
                var d_buf: [16]u8 = undefined;
                const d_str = formatDiff(&d_buf, diff);
                const p_symbol = if (p.is_paused) "⏸" else "▶";

                if (p.is_paused) {
                    var t_buf: [16]u8 = undefined;
                    const t_str = formatTime(&t_buf, p.time_pos);
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}  • {s}: ⏸ Paused at {s} [{d}ms]\\N", .{ p.username(), t_str, p.ping_ms }) catch return;
                    pos += line.len;
                } else if (@abs(diff) < 1.0) {
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}  • {s}: ▶ In sync [{d}ms]\\N", .{ p.username(), p.ping_ms }) catch return;
                    pos += line.len;
                } else {
                    var t_buf: [16]u8 = undefined;
                    const t_str = formatTime(&t_buf, p.time_pos);
                    const line = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}  • {s}: {s} {s} ({s}) [{d}ms]\\N", .{ p.username(), p_symbol, d_str, t_str, p.ping_ms }) catch return;
                    pos += line.len;
                }
            }
        }
    } else {
        const title = std.fmt.bufPrint(buf[pos..], "{{\\fs20}}Peers: (alone in room)\\N", .{}) catch return;
        pos += title.len;
    }

    buf[pos] = 0;
    const z_str: [:0]const u8 = buf[0..pos :0];
    mpv.showOsdOverlay(handle, OVERLAY_ID_HUD, z_str.ptr);
    hud.is_open = true;
    hud.expires_at = time_util.milliTimestamp() + 4000;
}

fn renderUoscMenu(handle: mpv.Handle, session: *protocol.Session, favorites: []const config_mod.FavoriteRoom, is_update: bool) void {
    var r_buf: [64]u8 = undefined;
    const active_room = session.getRoomName(&r_buf);
    const in_standby = (active_room == null);

    var peers_buf: [16]protocol.PeerInfo = undefined;
    const peer_count = session.getRosterSnapshot(&peers_buf);
    const is_muted = session.isSyncMuted();
    const sync_hint = if (is_muted) "Muted" else "Active";

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    var title_buf: [64]u8 = undefined;
    const menu_title = if (in_standby)
        "KoalaSync (Standby)"
    else
        std.fmt.bufPrint(&title_buf, "KoalaSync (Room: {s})", .{active_room.?}) catch "KoalaSync";

    const base = std.fmt.bufPrint(
        buf[pos..],
        "{{" ++
            "\"type\":\"koalasync\"," ++
            "\"title\":\"{s}\"," ++
            "\"on_close\":\"script-message koalasync-menu-closed\"," ++
            "\"items\":[",
        .{menu_title},
    ) catch return;
    pos += base.len;

    var need_comma = false;

    if (!in_standby) {
        const p_actions = std.fmt.bufPrint(
            buf[pos..],
            "{{\"title\":\"Force Sync Room Position\",\"icon\":\"sync\",\"value\":\"script-message koalasync-force-sync\"}}," ++
                "{{\"title\":\"Toggle Sync Mute\",\"hint\":\"{s}\",\"icon\":\"tune\",\"value\":\"script-message koalasync-toggle-sync\",\"keep_open\":true}}," ++
                "{{\"title\":\"Catch Up to Room\",\"icon\":\"fast_forward\",\"value\":\"script-message koalasync-resync\"}}",
            .{sync_hint},
        ) catch return;
        pos += p_actions.len;
        need_comma = true;
    }

    // Favorite Rooms submenu
    if (favorites.len > 0 or !in_standby) {
        if (need_comma) {
            buf[pos] = ',';
            pos += 1;
        }

        var fav_hint_buf: [32]u8 = undefined;
        const fav_hint = std.fmt.bufPrint(&fav_hint_buf, "{d} saved", .{favorites.len}) catch "";
        const fav_head = std.fmt.bufPrint(
            buf[pos..],
            "{{\"id\":\"favorites\",\"title\":\"Favorite Rooms\",\"hint\":\"{s}\",\"icon\":\"bookmark\",\"items\":[",
            .{fav_hint},
        ) catch return;
        pos += fav_head.len;

        var sub_need_comma = false;
        for (favorites) |fav| {
            if (sub_need_comma) {
                buf[pos] = ',';
                pos += 1;
            }
            const is_cur = (!in_standby and std.mem.eql(u8, fav.room, active_room.?));
            if (is_cur) {
                const item = std.fmt.bufPrint(
                    buf[pos..],
                    "{{\"title\":\"{s}\",\"hint\":\"Current Room\",\"icon\":\"check\"}}",
                    .{fav.label},
                ) catch return;
                pos += item.len;
            } else {
                const pass_param = if (fav.password.len > 0) fav.password else "";
                const item = std.fmt.bufPrint(
                    buf[pos..],
                    "{{\"title\":\"{s}\",\"hint\":\"{s}\",\"icon\":\"login\",\"value\":\"script-message koalasync-join {s} {s}\"}}",
                    .{ fav.label, fav.room, fav.room, pass_param },
                ) catch return;
                pos += item.len;
            }
            sub_need_comma = true;
        }

        if (!in_standby) {
            if (sub_need_comma) {
                buf[pos] = ',';
                pos += 1;
            }
            var is_fav = false;
            for (favorites) |fav| {
                if (std.mem.eql(u8, fav.room, active_room.?)) {
                    is_fav = true;
                    break;
                }
            }
            if (is_fav) {
                const rem_item = std.fmt.bufPrint(
                    buf[pos..],
                    "{{\"title\":\"Remove from Favorites\",\"icon\":\"star_border\",\"value\":\"script-message koalasync-fav-remove\",\"keep_open\":true}}",
                    .{},
                ) catch return;
                pos += rem_item.len;
            } else {
                const add_item = std.fmt.bufPrint(
                    buf[pos..],
                    "{{\"title\":\"Add Current Room to Favorites\",\"icon\":\"star\",\"value\":\"script-message koalasync-fav-add\",\"keep_open\":true}}",
                    .{},
                ) catch return;
                pos += add_item.len;
            }
        }

        const fav_tail = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return;
        pos += fav_tail.len;
        need_comma = true;
    }

    // Join / Switch Room prompt
    if (need_comma) {
        buf[pos] = ',';
        pos += 1;
    }
    const jp_item = std.fmt.bufPrint(
        buf[pos..],
        "{{\"title\":\"Join / Switch Room…\",\"icon\":\"meeting_room\",\"value\":\"script-message koalasync-join-prompt\"}}",
        .{},
    ) catch return;
    pos += jp_item.len;
    need_comma = true;

    // Standby mute toggle
    if (in_standby) {
        if (need_comma) {
            buf[pos] = ',';
            pos += 1;
        }
        const sm_item = std.fmt.bufPrint(
            buf[pos..],
            "{{\"title\":\"Toggle Sync Mute\",\"hint\":\"{s}\",\"icon\":\"tune\",\"value\":\"script-message koalasync-toggle-sync\",\"keep_open\":true}}",
            .{sync_hint},
        ) catch return;
        pos += sm_item.len;
        need_comma = true;
    }

    // Peers section
    if (!in_standby and peer_count > 0) {
        var all_in_sync = true;
        var max_diff: f64 = 0;
        if (peer_count > 1) {
            for (peers_buf[1..peer_count]) |p| {
                const diff = p.time_pos - session.local_time;
                if (@abs(diff) >= 1.0 or p.is_paused != session.local_paused) {
                    all_in_sync = false;
                    if (@abs(diff) > max_diff) max_diff = diff;
                }
            }
        }
        var h_diff_buf: [16]u8 = undefined;
        const peers_hint: []const u8 = if (peer_count <= 1)
            "Alone"
        else if (all_in_sync)
            "In sync"
        else
            formatDiff(&h_diff_buf, max_diff);

        if (need_comma) {
            buf[pos] = ',';
            pos += 1;
        }

        const p_head = std.fmt.bufPrint(
            buf[pos..],
            "{{\"id\":\"peers\",\"title\":\"Peers ({d} in room)\",\"hint\":\"{s}\",\"icon\":\"group\",\"items\":[",
            .{ peer_count, peers_hint },
        ) catch return;
        pos += p_head.len;

        // Entry 0: Local player (You)
        {
            var t_buf: [16]u8 = undefined;
            const t_str = formatTime(&t_buf, peers_buf[0].time_pos);
            const state_label = if (peers_buf[0].is_paused) "Paused" else "Playing";
            var hint_buf: [32]u8 = undefined;
            const hint_str = std.fmt.bufPrint(&hint_buf, "{s} • {s}", .{ t_str, state_label }) catch t_str;
            const comma = if (peer_count > 1) "," else "";
            const you_item = std.fmt.bufPrint(
                buf[pos..],
                "{{\"title\":\"{s}\",\"hint\":\"{s}\",\"icon\":\"person\"}}{s}",
                .{ peers_buf[0].username(), hint_str, comma },
            ) catch return;
            pos += you_item.len;
        }

        // Entries 1..N: Remote peers
        if (peer_count > 1) {
            for (peers_buf[1..peer_count], 1..) |p, i| {
                const diff = p.time_pos - session.local_time;
                var t_buf: [16]u8 = undefined;
                const t_str = formatTime(&t_buf, p.time_pos);
                var d_buf: [16]u8 = undefined;
                const d_str = formatDiff(&d_buf, diff);

                var p_title_buf: [64]u8 = undefined;
                var p_hint_buf: [64]u8 = undefined;
                var icon_str: []const u8 = "person";
                var title_slice: []const u8 = p.username();
                var hint_slice: []const u8 = "";

                if (p.is_paused) {
                    title_slice = std.fmt.bufPrint(&p_title_buf, "{s} (Paused)", .{p.username()}) catch p.username();
                    hint_slice = std.fmt.bufPrint(&p_hint_buf, "{s} • {d}ms", .{ t_str, p.ping_ms }) catch "";
                    icon_str = "pause";
                } else if (@abs(diff) < 1.0) {
                    title_slice = p.username();
                    hint_slice = std.fmt.bufPrint(&p_hint_buf, "In sync • {d}ms", .{p.ping_ms}) catch "";
                    icon_str = "play_arrow";
                } else if (diff >= 1.0) {
                    title_slice = std.fmt.bufPrint(&p_title_buf, "{s} ({s} ahead)", .{ p.username(), d_str }) catch p.username();
                    hint_slice = std.fmt.bufPrint(&p_hint_buf, "Catch up • {d}ms", .{p.ping_ms}) catch "";
                    icon_str = "fast_forward";
                } else {
                    title_slice = std.fmt.bufPrint(&p_title_buf, "{s} ({s} behind)", .{ p.username(), d_str }) catch p.username();
                    hint_slice = std.fmt.bufPrint(&p_hint_buf, "Jump back • {d}ms", .{p.ping_ms}) catch "";
                    icon_str = "fast_rewind";
                }
                const comma = if (i + 1 < peer_count) "," else "";
                const p_item = std.fmt.bufPrint(
                    buf[pos..],
                    "{{\"title\":\"{s}\",\"hint\":\"{s}\",\"icon\":\"{s}\",\"value\":\"script-message koalasync-seek-to {d:.3}\"}}{s}",
                    .{ title_slice, hint_slice, icon_str, p.time_pos, comma },
                ) catch return;
                pos += p_item.len;
            }
        }

        const p_tail = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return;
        pos += p_tail.len;
        need_comma = true;
    }

    if (!in_standby) {
        if (need_comma) {
            buf[pos] = ',';
            pos += 1;
        }
        const leave_item = std.fmt.bufPrint(
            buf[pos..],
            "{{\"title\":\"Leave Room\",\"icon\":\"logout\",\"value\":\"script-message koalasync-leave\"}}",
            .{},
        ) catch return;
        pos += leave_item.len;
    }

    const menu_end = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return;
    pos += menu_end.len;

    buf[pos] = 0;
    const z_json: [:0]const u8 = buf[0..pos :0];
    const action_str: [*:0]const u8 = if (is_update) "update-menu" else "open-menu";
    const cmd = [_:null]?[*:0]const u8{ "script-message-to", "uosc", action_str, z_json.ptr, null };
    _ = mpv.command(handle, cmd);
}
