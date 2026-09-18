# KoalaSync mpv Client

A native mpv C plugin (written in Zig) that lets mpv join a KoalaSync room and synchronize play/pause/seek with browser extension peers.

**Zero runtime dependencies** — just a single `.so` / `.dylib` / `.dll` file dropped into mpv's scripts directory.

---

## Quick Start

### 1. Build

```bash
cd clients/mpv

# Generate constants from shared/ (requires Node.js)
node scripts/sync-constants.js

# Build the plugin
zig build -Doptimize=ReleaseSafe
```

The compiled library will be at `zig-out/lib/libkoalasync.so` (Linux), `libkoalasync.dylib` (macOS), or `koalasync.dll` (Windows).

### 2. Install

```bash
# Automatic
zig build install-mpv

# Or manual
cp zig-out/lib/libkoalasync.so ~/.config/mpv/scripts/koalasync.so
```

### 3. Configure

Create `~/.config/mpv/script-opts/koalasync.conf`:

```ini
koalasync-server=wss://syncserver.koalastuff.net
koalasync-room=movie-night
koalasync-password=secret
koalasync-username=alice
```

### 4. Use

```bash
mpv video.mkv
# → OSD: "KoalaSync: joined room "movie-night" ✓"
```

Or pass options via CLI:

```bash
mpv --script-opts=koalasync-room=test,koalasync-username=bob video.mkv
```

---

## Cross-Compilation

Zig makes cross-compilation trivial:

```bash
# Linux x86_64 (default)
zig build -Doptimize=ReleaseSafe

# Linux aarch64 (e.g. Raspberry Pi)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu

# macOS (Apple Silicon)
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos

# macOS (Intel)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos

# Windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu
```

---

## How It Works

```
┌─────────────────────────────────────────────┐
│  mpv process                                │
│                                             │
│  koalasync.so (Zig → C ABI)                │
│  ┌───────────┐       ┌──────────────────┐   │
│  │ mpv hooks │ ◄───► │ WebSocket client │ ──┼──► KoalaSync Relay
│  │ (client.h)│       │ TLS + WS + SIO   │ ◄─┼── (Socket.IO EIO=4)
│  └───────────┘       └──────────────────┘   │
└─────────────────────────────────────────────┘
```

The plugin runs entirely inside mpv's process:

1. **mpv hooks** — Observes `pause`, `time-pos`, and `media-title` properties via `mpv_observe_property`.
2. **WebSocket + TLS** — Connects to the relay using POSIX sockets and OpenSSL for TLS.
3. **Socket.IO EIO=4** — Speaks the same wire protocol as the browser extension.
4. **Loop guard** — Suppresses echo events when applying remote commands (same pattern as the browser extension's `expectedEvents`).
5. **Heartbeat** — Sends `peer_status` every 15 seconds.

### Threading Model

- **mpv thread** (cplugin thread): Runs `mpv_wait_event` loop, processes property changes, applies incoming remote commands.
- **Network thread**: Manages WebSocket connection, reads relay messages, sends queued events.
- **Shared state**: Mutex-protected ring buffer queues for bidirectional communication.

---

## Constants Synchronization

Protocol constants (event names, version, server token) are generated from `shared/constants.js`:

```bash
node scripts/sync-constants.js
# → Generates src/constants.zig
```

This preserves the repository's **single source of truth** principle. Run this after any protocol change, or wire it into `npm run build:extension`.

---

## MVP Features

| Feature | Status |
|---------|--------|
| Connect to relay (WS + TLS + Socket.IO) | ✅ |
| Join room with password & capabilities | ✅ |
| Send/receive play, pause, seek | ✅ |
| Canonical Media State v1 recovery | ✅ |
| Event ACK & peer RTT ping/pong | ✅ |
| Media title tracking & broadcast | ✅ |
| Peer status heartbeat (15s) | ✅ |
| Host Control Mode status display | ✅ |
| Reconnection with backoff | ✅ |
| Loop guard (echo suppression) | ✅ |
| Relay error reporting via OSD | ✅ |
| Config via script-opts & conf file | ✅ |
| Cross-platform builds | ✅ |
| Force sync (prepare & execute) | ✅ |

### Planned

- Episode auto-sync
- Chat via OSD
- Host control mode (active moderation)

---

## Requirements

- **Build**: [Zig](https://ziglang.org/download/) ≥ 0.16.0, Node.js (for constants sync), OpenSSL (`libssl`, `libcrypto`)
- **Runtime**: mpv with cplugin support (standard in mpv builds since 0.35)

---

## License

Same as the parent KoalaSync project — [MIT](../../LICENSE).
