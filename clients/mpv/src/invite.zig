/// Parsing and extraction for KoalaSync invite links and hashes.
///
/// Implements full protocol parity with shared/invite-links.js:
///   - Modern #j2: links with room, password, chat key, and optional custom relay
///   - Legacy #join: links
///   - Robust extraction from arbitrary text, URLs, markdown, and delimiters
const std = @import("std");

pub const J2_PREFIX = "#j2:";
pub const LEGACY_PREFIX = "#join:";

pub const ParsedInvite = struct {
    format: enum { j2, legacy },
    room_id: []const u8,
    password: []const u8,
    chat_key: []const u8,
    use_custom_server: bool = false,
    server_url: ?[]const u8 = null,

    pub fn deinit(self: ParsedInvite, allocator: std.mem.Allocator) void {
        allocator.free(self.room_id);
        allocator.free(self.password);
        allocator.free(self.chat_key);
        if (self.server_url) |u| allocator.free(u);
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decodes percent-encoded characters (%XX). If form_mode is true, '+' is decoded as space.
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8, form_mode: bool) ![]const u8 {
    var out = try allocator.alloc(u8, input.len);
    errdefer allocator.free(out);

    var in_i: usize = 0;
    var out_i: usize = 0;

    while (in_i < input.len) {
        const c = input[in_i];
        if (form_mode and c == '+') {
            out[out_i] = ' ';
            out_i += 1;
            in_i += 1;
        } else if (c == '%') {
            if (in_i + 2 >= input.len) return error.InvalidPercentEncoding;
            const h1 = hexVal(input[in_i + 1]) orelse return error.InvalidPercentEncoding;
            const h2 = hexVal(input[in_i + 2]) orelse return error.InvalidPercentEncoding;
            out[out_i] = (h1 << 4) | h2;
            out_i += 1;
            in_i += 3;
        } else {
            out[out_i] = c;
            out_i += 1;
            in_i += 1;
        }
    }

    // Verify valid UTF-8 if desired, or return bytes
    if (!std.unicode.utf8ValidateSlice(out[0..out_i])) {
        return error.InvalidUtf8;
    }

    return try allocator.realloc(out, out_i);
}

pub fn parseJ2Hash(allocator: std.mem.Allocator, hash: []const u8) ?ParsedInvite {
    if (!std.mem.startsWith(u8, hash, J2_PREFIX)) return null;

    const query = hash[J2_PREFIX.len..];
    var room_id: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var chat_key: ?[]const u8 = null;
    var server_url: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;
        const eq_pos = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (eq_pos) |pos| pair[0..pos] else pair;
        const raw_val = if (eq_pos) |pos| pair[pos + 1 ..] else "";

        const key = percentDecode(allocator, raw_key, true) catch continue;
        defer allocator.free(key);
        const val = percentDecode(allocator, raw_val, true) catch continue;

        if (std.mem.eql(u8, key, "r")) {
            if (room_id) |prev| allocator.free(prev);
            room_id = val;
        } else if (std.mem.eql(u8, key, "p")) {
            if (password) |prev| allocator.free(prev);
            password = val;
        } else if (std.mem.eql(u8, key, "k")) {
            if (chat_key) |prev| allocator.free(prev);
            const clean_val = if (std.mem.indexOfScalar(u8, val, '=')) |eq| val[0..eq] else val;
            chat_key = allocator.dupe(u8, clean_val) catch return null;
            allocator.free(val);
        } else if (std.mem.eql(u8, key, "u")) {
            if (server_url) |prev| allocator.free(prev);
            const clean_val = if (std.mem.indexOfScalar(u8, val, '=')) |eq| val[0..eq] else val;
            server_url = allocator.dupe(u8, clean_val) catch return null;
            allocator.free(val);
        } else {
            allocator.free(val);
        }
    }

    const r = room_id orelse {
        if (password) |p| allocator.free(p);
        if (chat_key) |k| allocator.free(k);
        if (server_url) |u| allocator.free(u);
        return null;
    };
    const p = password orelse {
        allocator.free(r);
        if (chat_key) |k| allocator.free(k);
        if (server_url) |u| allocator.free(u);
        return null;
    };
    const k = chat_key orelse {
        allocator.free(r);
        allocator.free(p);
        if (server_url) |u| allocator.free(u);
        return null;
    };

    if (r.len == 0 or p.len == 0 or k.len == 0) {
        allocator.free(r);
        allocator.free(p);
        allocator.free(k);
        if (server_url) |u| allocator.free(u);
        return null;
    }

    const has_custom_server = if (server_url) |u| u.len > 0 else false;

    return .{
        .format = .j2,
        .room_id = r,
        .password = p,
        .chat_key = k,
        .use_custom_server = has_custom_server,
        .server_url = server_url,
    };
}

pub fn parseLegacyHash(allocator: std.mem.Allocator, hash: []const u8) ?ParsedInvite {
    if (!std.mem.startsWith(u8, hash, LEGACY_PREFIX)) return null;

    const rest = hash[LEGACY_PREFIX.len..];
    var parts_list: std.ArrayList([]const u8) = .empty;
    defer parts_list.deinit(allocator);

    var iter = std.mem.splitScalar(u8, rest, ':');
    while (iter.next()) |part| {
        parts_list.append(allocator, part) catch return null;
    }

    if (parts_list.items.len < 2) return null;

    const room_id_slice = parts_list.items[0];
    if (room_id_slice.len == 0) return null;

    var use_custom_server = false;
    var server_url: ?[]const u8 = null;
    var pass_end_idx = parts_list.items.len;

    if (parts_list.items.len >= 4) {
        const flag = parts_list.items[parts_list.items.len - 2];
        const raw_url = parts_list.items[parts_list.items.len - 1];

        if (percentDecode(allocator, raw_url, false)) |decoded_url| {
            const is_custom = std.mem.eql(u8, flag, "1") and
                (std.mem.startsWith(u8, decoded_url, "ws://") or std.mem.startsWith(u8, decoded_url, "wss://"));
            const is_official = std.mem.eql(u8, flag, "0") and raw_url.len == 0;

            if (is_custom or is_official) {
                pass_end_idx = parts_list.items.len - 2;
                use_custom_server = is_custom;
                server_url = if (is_custom) decoded_url else blk: {
                    allocator.free(decoded_url);
                    break :blk null;
                };
            } else {
                allocator.free(decoded_url);
            }
        } else |_| {
            return null;
        }
    }

    const pass_parts = parts_list.items[1..pass_end_idx];
    if (pass_parts.len == 0) {
        if (server_url) |u| allocator.free(u);
        return null;
    }

    const password = std.mem.join(allocator, ":", pass_parts) catch {
        if (server_url) |u| allocator.free(u);
        return null;
    };

    if (password.len == 0) {
        allocator.free(password);
        if (server_url) |u| allocator.free(u);
        return null;
    }

    const room_id = allocator.dupe(u8, room_id_slice) catch {
        allocator.free(password);
        if (server_url) |u| allocator.free(u);
        return null;
    };

    const empty_chat_key = allocator.dupe(u8, "") catch {
        allocator.free(room_id);
        allocator.free(password);
        if (server_url) |u| allocator.free(u);
        return null;
    };

    return .{
        .format = .legacy,
        .room_id = room_id,
        .password = password,
        .chat_key = empty_chat_key,
        .use_custom_server = use_custom_server,
        .server_url = server_url,
    };
}

pub fn parseInviteHash(allocator: std.mem.Allocator, hash: []const u8) ?ParsedInvite {
    return parseJ2Hash(allocator, hash) orelse parseLegacyHash(allocator, hash);
}

fn getMatchingCloser(opener: u8) ?u8 {
    return switch (opener) {
        '(' => ')',
        '<' => '>',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        else => null,
    };
}

fn isAsciiSchemeChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '+' or c == '.' or c == '-';
}

/// Extracts a KoalaSync room invite from arbitrary pasted text, URL, or markdown.
/// Inspects every #j2: or #join: fragment in text order and returns the first valid invite.
pub fn parseInviteText(allocator: std.mem.Allocator, text: []const u8) ?ParsedInvite {
    if (text.len == 0) return null;

    var cursor: usize = 0;
    while (cursor < text.len) {
        const j2_idx = std.mem.indexOfPos(u8, text, cursor, J2_PREFIX);
        const join_idx = std.mem.indexOfPos(u8, text, cursor, LEGACY_PREFIX);

        var match_idx: usize = 0;
        if (j2_idx != null and join_idx != null) {
            match_idx = @min(j2_idx.?, join_idx.?);
        } else if (j2_idx) |idx| {
            match_idx = idx;
        } else if (join_idx) |idx| {
            match_idx = idx;
        } else {
            break;
        }

        // Slice hash until whitespace
        var end_idx = match_idx;
        while (end_idx < text.len and !std.ascii.isWhitespace(text[end_idx])) : (end_idx += 1) {}
        var hash_slice = text[match_idx..end_idx];

        // Check if the link itself was wrapped (e.g. <https://...>, (https://...))
        const before = text[0..match_idx];
        var link_start: usize = before.len;
        if (std.mem.lastIndexOf(u8, before, "://")) |scheme_sep| {
            var s = scheme_sep;
            while (s > 0 and isAsciiSchemeChar(before[s - 1])) : (s -= 1) {}
            link_start = s;
        }

        if (link_start > 0) {
            const opener = before[link_start - 1];
            if (getMatchingCloser(opener)) |closer| {
                if (hash_slice.len > 0 and hash_slice[hash_slice.len - 1] == closer) {
                    hash_slice = hash_slice[0 .. hash_slice.len - 1];
                }
            }
        }

        // For j2 hashes, strip trailing sentence punctuation / brackets
        if (std.mem.startsWith(u8, hash_slice, J2_PREFIX)) {
            while (hash_slice.len > 0) {
                const last = hash_slice[hash_slice.len - 1];
                if (last == ')' or last == ']' or last == '}' or last == '>' or
                    last == '"' or last == '\'' or last == '.' or last == ',' or
                    last == ';' or last == '!' or last == '?')
                {
                    hash_slice = hash_slice[0 .. hash_slice.len - 1];
                } else {
                    break;
                }
            }
        }

        if (parseInviteHash(allocator, hash_slice)) |invite| {
            return invite;
        }

        cursor = match_idx + 1;
    }

    return null;
}

/// Generates a 16-byte random chat secret and encodes it as a 22-character base64url string.
pub fn generateChatKey(buf: *[22]u8) void {
    var raw: [16]u8 = undefined;
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const seed: u64 = @bitCast(@as(i64, @intCast(tv.sec)) * 1_000_000 + tv.usec);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&raw);
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (src_i + 3 <= 16) : (src_i += 3) {
        const b0 = raw[src_i];
        const b1 = raw[src_i + 1];
        const b2 = raw[src_i + 2];
        buf[dst_i] = alphabet[b0 >> 2];
        buf[dst_i + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        buf[dst_i + 2] = alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        buf[dst_i + 3] = alphabet[b2 & 0x3F];
        dst_i += 4;
    }
    const b = raw[15];
    buf[dst_i] = alphabet[b >> 2];
    buf[dst_i + 1] = alphabet[(b & 0x03) << 4];
}

/// Implements URLSearchParams form-url-encoding (space -> '+', unreserved -> literal, others -> %XX).
pub fn formUrlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '*', '-', '.', '_' => count += 1,
            ' ' => count += 1,
            else => count += 3,
        }
    }
    const out = try allocator.alloc(u8, count);
    var i: usize = 0;
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '*', '-', '.', '_' => {
                out[i] = c;
                i += 1;
            },
            ' ' => {
                out[i] = '+';
                i += 1;
            },
            else => {
                out[i] = '%';
                out[i + 1] = hex[c >> 4];
                out[i + 2] = hex[c & 0x0F];
                i += 3;
            },
        }
    }
    return out;
}

/// Standard URI component percent encoding matching encodeURIComponent.
pub fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => count += 1,
            else => count += 3,
        }
    }
    const out = try allocator.alloc(u8, count);
    var i: usize = 0;
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => {
                out[i] = c;
                i += 1;
            },
            else => {
                out[i] = '%';
                out[i + 1] = hex[c >> 4];
                out[i + 2] = hex[c & 0x0F];
                i += 3;
            },
        }
    }
    return out;
}

/// Builds a modern #j2: hash matching buildJ2Hash in shared/invite-links.js.
pub fn buildJ2Hash(
    allocator: std.mem.Allocator,
    room_id: []const u8,
    password: []const u8,
    chat_key: []const u8,
    server_url: ?[]const u8,
) ![]const u8 {
    const enc_r = try formUrlEncode(allocator, room_id);
    defer allocator.free(enc_r);
    const enc_p = try formUrlEncode(allocator, password);
    defer allocator.free(enc_p);
    const enc_k = try formUrlEncode(allocator, chat_key);
    defer allocator.free(enc_k);

    if (server_url) |srv| {
        if (srv.len > 0) {
            const enc_u = try formUrlEncode(allocator, srv);
            defer allocator.free(enc_u);
            return std.fmt.allocPrint(allocator, "{s}r={s}&p={s}&k={s}&u={s}", .{
                J2_PREFIX, enc_r, enc_p, enc_k, enc_u,
            });
        }
    }
    return std.fmt.allocPrint(allocator, "{s}r={s}&p={s}&k={s}", .{
        J2_PREFIX, enc_r, enc_p, enc_k,
    });
}

/// Builds a legacy #join: hash matching shared/invite-links.js.
pub fn buildLegacyHash(
    allocator: std.mem.Allocator,
    room_id: []const u8,
    password: []const u8,
    server_url: ?[]const u8,
) ![]const u8 {
    if (server_url) |srv| {
        if (srv.len > 0) {
            const enc_u = try percentEncode(allocator, srv);
            defer allocator.free(enc_u);
            return std.fmt.allocPrint(allocator, "{s}{s}:{s}:1:{s}", .{
                LEGACY_PREFIX, room_id, password, enc_u,
            });
        }
    }
    return std.fmt.allocPrint(allocator, "{s}{s}:{s}", .{
        LEGACY_PREFIX, room_id, password,
    });
}

/// Builds a complete join URL formatted for sharing (e.g. https://sync.koalastuff.net/join.html#j2:...).
pub fn buildInviteLink(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    room_id: []const u8,
    password: []const u8,
    chat_key: []const u8,
    server_url: ?[]const u8,
) ![]const u8 {
    const clean_base = std.mem.trimEnd(u8, base_url, "/");
    if (chat_key.len > 0) {
        const hash = try buildJ2Hash(allocator, room_id, password, chat_key, server_url);
        defer allocator.free(hash);
        return std.fmt.allocPrint(allocator, "{s}/join.html{s}", .{ clean_base, hash });
    } else {
        const hash = try buildLegacyHash(allocator, room_id, password, server_url);
        defer allocator.free(hash);
        return std.fmt.allocPrint(allocator, "{s}/join.html{s}", .{ clean_base, hash });
    }
}

// ── Tests ───────────────────────────────────────────────────────

test "percentDecode basic and form mode" {
    const allocator = std.testing.allocator;

    const s1 = try percentDecode(allocator, "hello%20world", false);
    defer allocator.free(s1);
    try std.testing.expectEqualStrings("hello world", s1);

    const s2 = try percentDecode(allocator, "hello+world", true);
    defer allocator.free(s2);
    try std.testing.expectEqualStrings("hello world", s2);

    const s3 = try percentDecode(allocator, "wss%3A%2F%2Frelay.test", false);
    defer allocator.free(s3);
    try std.testing.expectEqualStrings("wss://relay.test", s3);
}

test "round-trips modern j2 links with official and custom servers" {
    const allocator = std.testing.allocator;

    const official_hash = "#j2:r=SILENT-EAGLE-90&p=30PXPD&k=R5Ti1nxp0crfAFHf3gVncw";
    var inv1 = parseInviteHash(allocator, official_hash).?;
    defer inv1.deinit(allocator);
    try std.testing.expectEqual(inv1.format, .j2);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", inv1.room_id);
    try std.testing.expectEqualStrings("30PXPD", inv1.password);
    try std.testing.expectEqualStrings("R5Ti1nxp0crfAFHf3gVncw", inv1.chat_key);
    try std.testing.expect(!inv1.use_custom_server);
    try std.testing.expect(inv1.server_url == null);

    const custom_hash = "#j2:r=SILENT-EAGLE-90&p=30PXPD&k=R5Ti1nxp0crfAFHf3gVncw&u=wss%3A%2F%2Frelay.example.test";
    var inv2 = parseInviteHash(allocator, custom_hash).?;
    defer inv2.deinit(allocator);
    try std.testing.expectEqual(inv2.format, .j2);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", inv2.room_id);
    try std.testing.expectEqualStrings("30PXPD", inv2.password);
    try std.testing.expect(inv2.use_custom_server);
    try std.testing.expectEqualStrings("wss://relay.example.test", inv2.server_url.?);
}

test "preserves punctuation in j2 passwords" {
    const allocator = std.testing.allocator;

    const hash = "#j2:r=ROOM&p=p%3A1%26p%3D2%3D3&k=KEY";
    var inv = parseInviteHash(allocator, hash).?;
    defer inv.deinit(allocator);
    try std.testing.expectEqualStrings("ROOM", inv.room_id);
    try std.testing.expectEqualStrings("p:1&p=2=3", inv.password);
    try std.testing.expectEqualStrings("KEY", inv.chat_key);
}

test "parses legacy format with official and custom server" {
    const allocator = std.testing.allocator;

    var leg1 = parseInviteHash(allocator, "#join:SILENT-EAGLE-90:30PXPD").?;
    defer leg1.deinit(allocator);
    try std.testing.expectEqual(leg1.format, .legacy);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", leg1.room_id);
    try std.testing.expectEqualStrings("30PXPD", leg1.password);
    try std.testing.expect(!leg1.use_custom_server);

    var leg2 = parseInviteHash(allocator, "#join:ROOM:PASS:1:wss%3A%2F%2Frelay.example.test").?;
    defer leg2.deinit(allocator);
    try std.testing.expectEqual(leg2.format, .legacy);
    try std.testing.expectEqualStrings("ROOM", leg2.room_id);
    try std.testing.expectEqualStrings("PASS", leg2.password);
    try std.testing.expect(leg2.use_custom_server);
    try std.testing.expectEqualStrings("wss://relay.example.test", leg2.server_url.?);

    var leg3 = parseInviteHash(allocator, "#join:ROOM:part1:part2:part3").?;
    defer leg3.deinit(allocator);
    try std.testing.expectEqualStrings("part1:part2:part3", leg3.password);

    var leg4 = parseInviteHash(allocator, "#join:ROOM:part1:part2:1:wss%3A%2F%2Frelay.example.test").?;
    defer leg4.deinit(allocator);
    try std.testing.expectEqualStrings("part1:part2", leg4.password);
    try std.testing.expect(leg4.use_custom_server);
}

test "rejects malformed hashes" {
    const allocator = std.testing.allocator;

    try std.testing.expect(parseInviteHash(allocator, "") == null);
    try std.testing.expect(parseInviteHash(allocator, "not-a-hash") == null);
    try std.testing.expect(parseInviteHash(allocator, "#j2:") == null);
    try std.testing.expect(parseInviteHash(allocator, "#j2:r=ROOM&p=PASS") == null);
    try std.testing.expect(parseInviteHash(allocator, "#j2:r=ROOM&k=KEY") == null);
    try std.testing.expect(parseInviteHash(allocator, "#j2:p=PASS&k=KEY") == null);
    try std.testing.expect(parseInviteHash(allocator, "#join:") == null);
    try std.testing.expect(parseInviteHash(allocator, "#join:ROOM") == null);
    try std.testing.expect(parseInviteHash(allocator, "#join:ROOM:") == null);
    try std.testing.expect(parseInviteHash(allocator, "#join::PASS") == null);
    try std.testing.expect(parseInviteHash(allocator, "#other:r=ROOM&p=PASS&k=KEY") == null);
}

test "extracts invites from arbitrary pasted text and wrapping" {
    const allocator = std.testing.allocator;

    const hash = "#j2:r=SILENT-EAGLE-90&p=30PXPD&k=R5Ti1nxp0crfAFHf3gVncw&u=wss%3A%2F%2Frelay.example.test";

    var t1 = parseInviteText(allocator, "https://sync.koalastuff.net/join.html" ++ hash).?;
    defer t1.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t1.room_id);
    try std.testing.expectEqualStrings("wss://relay.example.test", t1.server_url.?);

    var t2 = parseInviteText(allocator, "  join us: https://any.example/x" ++ hash ++ "\nsee you  ").?;
    defer t2.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t2.room_id);

    var t3 = parseInviteText(allocator, "(https://any.example/join" ++ hash ++ ")").?;
    defer t3.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t3.room_id);

    var t4 = parseInviteText(allocator, "<https://any.example/join" ++ hash ++ ">").?;
    defer t4.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t4.room_id);

    var t5 = parseInviteText(allocator, "Join here: https://any.example/join" ++ hash ++ ".").?;
    defer t5.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t5.room_id);

    var t6 = parseInviteText(allocator, "format is #j2:r=ROOM&p=PASS, mine: https://x.example/join" ++ hash).?;
    defer t6.deinit(allocator);
    try std.testing.expectEqualStrings("SILENT-EAGLE-90", t6.room_id);

    var t7 = parseInviteText(allocator, "<https://example.com/#join:ROOM-1:PASS>").?;
    defer t7.deinit(allocator);
    try std.testing.expectEqualStrings("ROOM-1", t7.room_id);
    try std.testing.expectEqualStrings("PASS", t7.password);

    var t8 = parseInviteText(allocator, "https://example.com/#join:ROOM-1:pass!)").?;
    defer t8.deinit(allocator);
    try std.testing.expectEqualStrings("pass!)", t8.password);

    var t9 = parseInviteText(allocator, "[invite](https://example.com/#join:ROOM-1:PASS)").?;
    defer t9.deinit(allocator);
    try std.testing.expectEqualStrings("ROOM-1", t9.room_id);
    try std.testing.expectEqualStrings("PASS", t9.password);

    var t10 = parseInviteText(allocator, "(#join:ROOM-1:PASS)").?;
    defer t10.deinit(allocator);
    try std.testing.expectEqualStrings("ROOM-1", t10.room_id);
    try std.testing.expectEqualStrings("PASS", t10.password);

    var t11 = parseInviteText(allocator, "https://example.com/#join:ROOM-1:pass.").?;
    defer t11.deinit(allocator);
    try std.testing.expectEqualStrings("pass.", t11.password);

    var t12 = parseInviteText(allocator, "#join:BROKEN then https://x.example/#join:ROOM-1:PASS").?;
    defer t12.deinit(allocator);
    try std.testing.expectEqualStrings("ROOM-1", t12.room_id);
    try std.testing.expectEqualStrings("PASS", t12.password);

    try std.testing.expect(parseInviteText(allocator, "SILENT-EAGLE-90") == null);
    try std.testing.expect(parseInviteText(allocator, "https://example.com/#section") == null);
    try std.testing.expect(parseInviteText(allocator, "https://example.com/join#j2:r=ROOM&p=PASS") == null);
    try std.testing.expect(parseInviteText(allocator, "") == null);
}

test "generateChatKey generates 22-char valid base64url keys" {
    var k1: [22]u8 = undefined;
    var k2: [22]u8 = undefined;
    generateChatKey(&k1);
    generateChatKey(&k2);

    try std.testing.expectEqual(@as(usize, 22), k1.len);
    try std.testing.expectEqual(@as(usize, 22), k2.len);
    // Two random 16-byte keys should not be identical
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));

    for (k1) |c| {
        const is_b64url = std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '-' or c == '_';
        try std.testing.expect(is_b64url);
    }
}

test "formUrlEncode encodes spaces, symbols, and preserves alphanumerics" {
    const allocator = std.testing.allocator;

    const enc = try formUrlEncode(allocator, "Room 1 & Pass!");
    defer allocator.free(enc);
    try std.testing.expectEqualStrings("Room+1+%26+Pass%21", enc);
}

test "buildJ2Hash and buildInviteLink round-trip with parseInviteText" {
    const allocator = std.testing.allocator;

    const link = try buildInviteLink(
        allocator,
        "https://sync.koalastuff.net",
        "MOVIE-NIGHT",
        "secret pass",
        "R5Ti1nxp0crfAFHf3gVncw",
        null,
    );
    defer allocator.free(link);

    try std.testing.expect(std.mem.startsWith(u8, link, "https://sync.koalastuff.net/join.html#j2:"));

    var parsed = parseInviteText(allocator, link).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("MOVIE-NIGHT", parsed.room_id);
    try std.testing.expectEqualStrings("secret pass", parsed.password);
    try std.testing.expectEqualStrings("R5Ti1nxp0crfAFHf3gVncw", parsed.chat_key);
    try std.testing.expect(!parsed.use_custom_server);
    try std.testing.expect(parsed.server_url == null);
}

test "buildInviteLink with custom server round-trips" {
    const allocator = std.testing.allocator;

    const link = try buildInviteLink(
        allocator,
        "https://sync.koalastuff.net/",
        "CUSTOM-ROOM",
        "p@ss:word",
        "AQEBAQEBAQEBAQEBAQEBAQ",
        "wss://custom.relay.org:8443",
    );
    defer allocator.free(link);

    var parsed = parseInviteText(allocator, link).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("CUSTOM-ROOM", parsed.room_id);
    try std.testing.expectEqualStrings("p@ss:word", parsed.password);
    try std.testing.expectEqualStrings("AQEBAQEBAQEBAQEBAQEBAQ", parsed.chat_key);
    try std.testing.expect(parsed.use_custom_server);
    try std.testing.expectEqualStrings("wss://custom.relay.org:8443", parsed.server_url.?);
}

test "buildLegacyHash and buildInviteLink round-trips" {
    const allocator = std.testing.allocator;

    const link = try buildInviteLink(
        allocator,
        "https://sync.koalastuff.net",
        "LEGACY-ROOM",
        "legacypass",
        "",
        "wss://legacy.relay",
    );
    defer allocator.free(link);

    try std.testing.expect(std.mem.startsWith(u8, link, "https://sync.koalastuff.net/join.html#join:"));

    var parsed = parseInviteText(allocator, link).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("LEGACY-ROOM", parsed.room_id);
    try std.testing.expectEqualStrings("legacypass", parsed.password);
    try std.testing.expect(parsed.use_custom_server);
    try std.testing.expectEqualStrings("wss://legacy.relay", parsed.server_url.?);
}

