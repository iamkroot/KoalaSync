/// WebSocket client over TCP + TLS using standard POSIX networking and OpenSSL.
///
/// Implements RFC 6455 framing (text, ping/pong, close) and the
/// HTTP/1.1 upgrade handshake. Client frames are masked per spec.
const std = @import("std");
const time = @import("time.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const Error = error{
    ConnectionFailed,
    UpgradeFailed,
    FrameTooLarge,
    ConnectionClosed,
    InvalidFrame,
    Unexpected,
} || std.mem.Allocator.Error;

pub const Message = struct {
    data: []const u8,
    owned: bool,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.data);
    }
};

const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// Maximum payload we accept in a single frame (64 KiB).
const MAX_PAYLOAD: usize = 64 * 1024;

pub const Client = struct {
    fd: c_int,
    ssl_ctx: ?*c.SSL_CTX = null,
    ssl: ?*c.SSL = null,
    allocator: std.mem.Allocator,
    closed: bool = false,

    // ── Connection ──────────────────────────────────────────────

    /// Connect to a WebSocket endpoint.
    /// `host` — hostname for TLS SNI and Host header.
    /// `port` — TCP port (443 for wss, 80 for ws).
    /// `path` — request path including query string.
    /// `use_tls` — whether to wrap in TLS.
    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
        use_tls: bool,
    ) Error!Client {
        // 1. Resolve host and connect via TCP
        const host_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{host}, 0);
        defer allocator.free(host_z);

        const port_z = try std.fmt.allocPrintSentinel(allocator, "{d}", .{port}, 0);
        defer allocator.free(port_z);

        var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;

        var res: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0 or res == null) {
            return error.ConnectionFailed;
        }
        defer c.freeaddrinfo(res);

        var sock_fd: c_int = -1;
        var p = res;
        while (p) |ai| : (p = ai.ai_next) {
            sock_fd = c.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
            if (sock_fd < 0) continue;

            // Enable TCP_NODELAY for lower latency
            var flag: c_int = 1;
            _ = c.setsockopt(sock_fd, c.IPPROTO_TCP, c.TCP_NODELAY, @ptrCast(&flag), @sizeOf(c_int));

            if (c.connect(sock_fd, ai.ai_addr, ai.ai_addrlen) == 0) {
                break; // connected
            }
            _ = c.close(sock_fd);
            sock_fd = -1;
        }

        if (sock_fd < 0) return error.ConnectionFailed;

        var ssl_ctx: ?*c.SSL_CTX = null;
        var ssl: ?*c.SSL = null;

        // 2. Set up TLS if requested
        if (use_tls) {
            const method = c.TLS_client_method();
            ssl_ctx = c.SSL_CTX_new(method);
            if (ssl_ctx == null) {
                _ = c.close(sock_fd);
                return error.ConnectionFailed;
            }

            // Load system default CA certs
            _ = c.SSL_CTX_set_default_verify_paths(ssl_ctx.?);

            ssl = c.SSL_new(ssl_ctx.?);
            if (ssl == null) {
                c.SSL_CTX_free(ssl_ctx.?);
                _ = c.close(sock_fd);
                return error.ConnectionFailed;
            }

            // Set SNI hostname
            _ = c.SSL_set_tlsext_host_name(ssl.?, host_z.ptr);
            _ = c.SSL_set_fd(ssl.?, sock_fd);

            if (c.SSL_connect(ssl.?) <= 0) {
                c.SSL_free(ssl.?);
                c.SSL_CTX_free(ssl_ctx.?);
                _ = c.close(sock_fd);
                return error.ConnectionFailed;
            }
        }

        var self = Client{
            .fd = sock_fd,
            .ssl_ctx = ssl_ctx,
            .ssl = ssl,
            .allocator = allocator,
        };

        // 3. Perform HTTP upgrade handshake
        self.doUpgrade(host, path) catch |err| {
            self.deinit();
            return err;
        };

        return self;
    }

    /// Perform the HTTP/1.1 → WebSocket upgrade handshake.
    fn doUpgrade(self: *Client, host: []const u8, path: []const u8) Error!void {
        var key_bytes: [16]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
        prng.random().bytes(&key_bytes);

        var key_buf: [24]u8 = undefined;
        const ws_key_str = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        const req = std.fmt.allocPrint(self.allocator,
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{ path, host, ws_key_str },
        ) catch return error.ConnectionFailed;
        defer self.allocator.free(req);

        self.rawWriteAll(req) catch return error.ConnectionFailed;

        // Read response — verify "101"
        var resp_buf: [1024]u8 = undefined;
        var resp_len: usize = 0;
        while (resp_len < resp_buf.len) {
            const n = self.rawRead(resp_buf[resp_len..]) catch return error.UpgradeFailed;
            if (n == 0) return error.UpgradeFailed;
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n") != null) break;
        }

        const resp = resp_buf[0..resp_len];
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) {
            return error.UpgradeFailed;
        }
    }

    // ── Sending ─────────────────────────────────────────────────

    /// Send a text frame (FIN=1, opcode=text, masked).
    pub fn sendText(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.text, payload);
    }

    /// Send a pong frame (in response to a ping).
    pub fn sendPong(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.pong, payload);
    }

    /// Send a close frame and mark the connection as closed.
    pub fn sendClose(self: *Client) void {
        self.sendFrame(.close, &.{}) catch {};
        self.closed = true;
    }

    fn sendFrame(self: *Client, opcode: Opcode, payload: []const u8) Error!void {
        if (self.closed) return error.ConnectionClosed;

        // Header: FIN + opcode
        var header: [14]u8 = undefined;
        var hlen: usize = 0;
        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        hlen = 1;

        // Length + MASK bit (client MUST mask)
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
            hlen = 2;
        } else if (payload.len <= 65535) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            hlen = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            hlen = 10;
        }

        // Mask key (4 random bytes)
        var mask: [4]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@bitCast(time.milliTimestamp()));
        prng.random().bytes(&mask);
        @memcpy(header[hlen .. hlen + 4], &mask);
        hlen += 4;

        // Mask the payload
        const masked = self.allocator.alloc(u8, payload.len) catch return error.ConnectionFailed;
        defer self.allocator.free(masked);
        for (masked, 0..) |*b, i| {
            b.* = payload[i] ^ mask[i % 4];
        }

        self.rawWriteAll(header[0..hlen]) catch return error.ConnectionFailed;
        self.rawWriteAll(masked) catch return error.ConnectionFailed;
    }

    // ── Receiving ───────────────────────────────────────────────

    /// Wait until data is available on the socket, or timeout_ms expires.
    fn waitForData(self: *Client, timeout_ms: i32) Error!bool {
        if (self.closed or self.fd < 0) return error.ConnectionClosed;

        if (self.ssl) |s| {
            if (c.SSL_pending(s) > 0) return true;
        }

        var pfd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const count = std.posix.poll(&pfd, timeout_ms) catch |err| {
            if (err == error.Interrupted) return false;
            return error.ConnectionClosed;
        };

        if (count == 0) return false; // timed out

        if ((pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
            if ((pfd[0].revents & std.posix.POLL.IN) == 0) return error.ConnectionClosed;
        }

        return true;
    }

    /// Read the next complete text message. Handles ping/pong and close frames.
    /// If timeout_ms is reached without incoming data, returns null.
    pub fn readMessage(self: *Client, timeout_ms: i32) Error!?Message {
        while (true) {
            if (self.closed) return error.ConnectionClosed;

            const has_data = try self.waitForData(timeout_ms);
            if (!has_data) return null;

            var hdr: [2]u8 = undefined;
            try self.rawReadExact(&hdr);

            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(hdr[0] & 0x0F)));
            const has_mask = (hdr[1] & 0x80) != 0;
            var payload_len: u64 = hdr[1] & 0x7F;

            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                try self.rawReadExact(&ext);
                payload_len = std.mem.readInt(u16, &ext, .big);
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                try self.rawReadExact(&ext);
                payload_len = std.mem.readInt(u64, &ext, .big);
            }

            if (payload_len > MAX_PAYLOAD) return error.FrameTooLarge;
            const len: usize = @intCast(payload_len);

            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (has_mask) try self.rawReadExact(&mask);

            const payload = self.allocator.alloc(u8, len) catch return error.ConnectionFailed;
            errdefer self.allocator.free(payload);
            if (len > 0) try self.rawReadExact(payload);

            if (has_mask) {
                for (payload, 0..) |*b, i| b.* = b.* ^ mask[i % 4];
            }

            switch (opcode) {
                .text => return Message{ .data = payload, .owned = true },
                .ping => {
                    self.sendPong(payload) catch {};
                    self.allocator.free(payload);
                    continue;
                },
                .close => {
                    self.allocator.free(payload);
                    self.closed = true;
                    return error.ConnectionClosed;
                },
                .pong => {
                    self.allocator.free(payload);
                    continue;
                },
                else => {
                    self.allocator.free(payload);
                    continue;
                },
            }
        }
    }

    // ── Teardown ────────────────────────────────────────────────

    pub fn deinit(self: *Client) void {
        if (!self.closed) self.sendClose();
        if (self.ssl) |s| c.SSL_free(s);
        if (self.ssl_ctx) |ctx| c.SSL_CTX_free(ctx);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.ssl = null;
        self.ssl_ctx = null;
        self.fd = -1;
    }

    // ── Raw I/O ─────────────────────────────────────────────────

    fn rawRead(self: *Client, buf: []u8) Error!usize {
        if (self.ssl) |s| {
            const n = c.SSL_read(s, buf.ptr, @intCast(buf.len));
            if (n <= 0) return error.ConnectionClosed;
            return @intCast(n);
        } else {
            const n = c.recv(self.fd, buf.ptr, buf.len, 0);
            if (n <= 0) return error.ConnectionClosed;
            return @intCast(n);
        }
    }

    fn rawReadExact(self: *Client, buf: []u8) Error!void {
        var filled: usize = 0;
        while (filled < buf.len) {
            if (filled > 0) {
                const has_data = try self.waitForData(5000);
                if (!has_data) return error.ConnectionClosed;
            }
            const n = try self.rawRead(buf[filled..]);
            if (n == 0) return error.ConnectionClosed;
            filled += n;
        }
    }

    fn rawWriteAll(self: *Client, data: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining = data[sent..];
            if (self.ssl) |s| {
                const n = c.SSL_write(s, remaining.ptr, @intCast(remaining.len));
                if (n <= 0) return error.ConnectionFailed;
                sent += @intCast(n);
            } else {
                const n = c.send(self.fd, remaining.ptr, remaining.len, 0);
                if (n <= 0) return error.ConnectionFailed;
                sent += @intCast(n);
            }
        }
    }
};
