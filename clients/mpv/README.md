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
koalasync-username=alice

# By default, mpv starts in Standby mode and will NOT join any room:
koalasync-autojoin=no

# Maintain favorite rooms using numbered keys (room1, room2, etc.):
# Format: roomN=room[:password][=Display Name]
room1=movie-night:secret=Movie Night
room2=anime-club=Anime Club
room3=watch-party
```

### 4. Use

```bash
# Launch mpv with video — launches cleanly in Standby mode by default:
mpv video.mkv
# → Press Ctrl+K for on-screen menu with 1-click favorite rooms!
# → Or press Ctrl+Shift+J to open the console join prompt!

# Autojoin a specific room or invite link from the command line:
mpv --script-opts=koalasync-room=movie-night video.mkv
# Or launch and press Ctrl+V to join directly from an invite link in your clipboard!
```

---

## User Controls & Keybindings

The plugin registers default keybindings via mpv's `define-section` so all controls work out of the box (without requiring edits to `input.conf`), while still allowing custom rebinding:

| Action | Default Hotkey | Script Message | Description |
|---|---|---|---|
| **Toggle Menu** | `Ctrl+k` or `c` | `script-message koalasync-menu` | Interactive in-player menu with 1-click favorite rooms (auto-routes to `uosc` if installed, else ASS overlay) |
| **Paste Invite** | `Ctrl+v` | `script-message koalasync-paste` | Joins room directly from invite link in clipboard (v3.3.1 parity) |
| **Join Prompt** | `Ctrl+Shift+j` | `script-message koalasync-join-prompt` | Opens mpv console prompt pre-filled with your favorite room |
| **Join Room** | — | `script-message koalasync-join <room\|link> [pass]` | Joins a room directly (accepts room names or `#j2:`/`#join:` invite links) |
| **Join Favorite** | — | `script-message koalasync-join-fav <1..N>` | Instantly joins favorite room #1, #2, etc. (bindable in `input.conf`) |
| **Toggle Favorite** | `Ctrl+Shift+f` | `script-message koalasync-fav-toggle` | Adds or removes the currently active room from your favorites |
| **Force Sync** | `Ctrl+Shift+s` or `Alt+s` | `script-message koalasync-force-sync` | Initiates room-wide resync to your current timestamp |
| **Toggle Sync** | `Ctrl+Shift+t` | `script-message koalasync-toggle-sync` | Mutes/unmutes local sync (decouple playback without leaving) |
| **Catch Up** | `Ctrl+Shift+r` | `script-message koalasync-resync` | Snaps local player to latest known room timestamp |
| **Peer HUD** | `Tab` or `Ctrl+Shift+i` | `script-message koalasync-status` | Displays live peer roster overlay card (ping, position, state) |
| **Leave Room** | `Ctrl+Shift+l` | `script-message koalasync-leave` | Cleanly leaves room and returns to standby mode |

### Interactive Menu Navigation
When the built-in ASS menu is open (`Ctrl+K` / `c`):
- `↑` / `k` — Move cursor up
- `↓` / `j` — Move cursor down
- `Enter` — Select option (e.g. join favorite room, switch room, or toggle favorite)
- `Esc` / `Ctrl+K` — Close menu

### `uosc` Integration
If [`uosc`](https://github.com/tomasklaen/uosc) is installed in your mpv setup, pressing `Ctrl+K` will automatically open a native `uosc` menu with icons, hints, mouse clickability, peer submenus, and a dedicated **Favorite Rooms** submenu for 1-click joining and switching. If `uosc` is not present, it seamlessly falls back to the built-in ASS overlay.

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
| Standby mode & dynamic room joining | ✅ |
| Interactive ASS Menu & Peer HUD | ✅ |
| `uosc` menu bridge integration | ✅ |
| Sync Mute / local playback decoupling | ✅ |
| Out-of-the-box keybindings via define-section | ✅ |
| mpv console prompt fallback | ✅ |
| Favorite rooms (numbered) & in-player switching | ✅ |
| Full invite link parsing (#j2, #join, arbitrary URLs) | ✅ |
| Paste invite links & direct clipboard join (Ctrl+V) | ✅ |

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
