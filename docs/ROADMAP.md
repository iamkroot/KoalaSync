# KoalaSync Roadmap

> Feature priorities, planned work, backlog, and rejected ideas for KoalaSync.

---

## Status Legend

| Badge | Meaning |
|---|---|
| 🚧 In Progress | Currently being developed |
| 📋 Planned | Prioritized for an upcoming phase |
| 💡 Backlog | Under evaluation, not yet prioritized |
| ❌ Rejected | Declined (with rationale) |
| ✅ Completed | Shipped |

---

## 🚧 In Progress

*Currently being worked on.*

| Feature | Priority | Area |
|---|---|---|
| mpv C plugin client (Zig) | P1 | Clients / Local Players |

---

## 📋 Planned

*Prioritized for upcoming phases.*

### Invite link with target URL for auto-redirect

- **Priority:** P2
- **Category:** UX / Ease of Sharing
- **Background:** The invite link currently only contains the room ID. The invited person has to manually open the page. Ideally, the link would include the shared tab's URL so the invitee gets redirected to the right page and the tab is auto-selected (auto-matching via tab title already exists).
- **Known challenges:**
  - Many streaming sites (e.g., Emby, Jellyfin) don't have unique URLs per content — once inside the player, the URL stays the same.
  - Dozens of such edge cases exist; a generic solution is difficult.
  - Would likely need site-specific extractor logic (similar to the existing sync service adapters).
- **Possible approaches:**
  - Fallback: if no unique URL can be determined, only pass the tab title.
  - Site-specific URL extraction for known services.

---

## 💡 Backlog

*Ideas and feature requests under evaluation.*

### Sticky player selection

- **Priority:** P3
- **Category:** Compatibility / Player Selection
- **Background:** `findVideo()` is stateless and re-ranks on every call, including inside the 150 ms seek poll. On a page whose candidate set changes mid-session (an ad frame appearing, the player briefly losing its source between episodes) the ranking can in principle move to a different element and back.
- **Possible approach:** Keep the attached element while it is still connected, still has a source and is not disqualified, and only switch when another candidate is playing and it is not. Belongs in the attach lifecycle rather than in the ranking.
- **Status:** Deliberately left out of the v3.1.0 ranking rework. No observed flapping; the ordered signals are stable enough that this is prevention, not a fix. Needs its own fixtures for the episode-change case.

### Firefox E2E coverage

- **Priority:** P2
- **Category:** Testing / Release Confidence
- **Background:** The E2E suite drives the Chromium build only. The Firefox artifact is built and checked by `addons-linter` on every run, but no browser flow exercises it, so a Firefox-only regression in injection or frame handling would not be caught.
- **Possible approach:** Playwright can launch Firefox with a temporary add-on; the detection specs are browser-agnostic already and would come along for free.
- **Status:** Backlog. Recorded because the current suite reads as broader coverage than it is.

### Two-peer relay E2E

- **Priority:** P3
- **Category:** Testing / Release Confidence
- **Background:** The extension specs drive injection and `SERVER_COMMAND` directly, without a relay and without a second peer. The actual sync loop between two browsers is only ever verified by hand.
- **Possible approach:** Start the local relay from `server/`, launch two extension contexts, join the same room and assert that a seek on one lands on the other.
- **Status:** Backlog.

### Sync a second video source per room

- **Priority:** P3
- **Category:** Compatibility / Player Selection
- **Background:** Detection picks exactly one `<video>` per tab. Pages that legitimately show two players side by side (a lecture feed plus slides, a multi-camera stream) can only ever sync one of them.
- **Status:** Backlog, no demand yet. Listed so the single-player assumption in the ranking is a recorded decision rather than an accident.

---

## ✅ Completed

### Cross-origin frame video detection and control

- **Priority:** P3
- **Category:** Compatibility / Embedded Players
- **Completed:** v3.1.2
- **Outcome:** The background probes accessible frames, elects the visible HTML5 player without trusting child-frame claims, and routes injection, ordered commands, state, chat, audio and teardown to the selected document. Hidden equal candidates without visibility evidence are rejected. A tab-wide frame sentinel plus subframe-navigation events recover CSS visibility switches, document reloads, lazy video insertion and failed delivery. Google Drive and YummyAnime were manually verified on their live services with v3.1.2 and are also covered by packed-Chromium E2E fixtures. Automated two-peer relay E2E remains tracked separately under Testing / Release Confidence.

---

## ❌ Rejected

*Declined features with rationale — keeps decisions documented so they don't get re-debated.*

| Feature | Reason |
|---|---|
| *(none yet)* | |
