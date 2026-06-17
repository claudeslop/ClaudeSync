# ClaudeSync — KOReader Sync Plugin

> ⚠️ **A note on origins:** This plugin was written entirely by [Claude](https://claude.ai) (Anthropic's AI assistant), in collaboration with a non-developer user. It has not been reviewed by the KOReader development team. Please read the [Before Your First Sync](#before-your-first-sync) section and make a backup before using it.

---

## 📖 What Does It Do?

KOReader remembers your reading progress, highlights, and notes — but only on the device you're reading on. ClaudeSync connects your KOReader installations to a cloud storage server and keeps that data in sync across all your devices automatically.

Finish a chapter on your Kobo before bed → pick up your tablet the next morning → your position is already there.

**What gets synced, per book:**
- 📑 Reading position (page / percentage)
- ✅ Reading status (reading / finished)
- ✏️ Highlights and annotations (notes you've added)
- 🔖 Bookmarks
- 📊 Reading statistics
- 🧠 Vocabulary builder

**What does NOT get synced by default:**
- The book files themselves
- KOReader app settings, themes, or fonts
- Reading statistics *(can be enabled — see Auto-sync options)*
- Vocabulary builder *(can be enabled — see Auto-sync options)*

---

## 🌐 Choosing a Service

ClaudeSync uses **WebDAV** — a standard protocol supported by a wide range of cloud storage services. Setup requires only a server address, username, and password. No developer apps, no OAuth tokens.

### Free hosted services (no server required)

These services offer free WebDAV access with just an email address and password — sign up on their website and you're ready:

| Service | WebDAV URL to enter | Free storage |
|---------|-------------------|-------------|
| **Koofr** | `https://app.koofr.net/dav/Koofr` | 10 GB |
| **Infomaniak kDrive** | `https://connect.drive.infomaniak.com` | 15 GB |

Both are privacy-friendly European companies (Koofr is Slovenian; kDrive is Swiss). Either is a great choice for most people.

Sign up at [koofr.eu](https://koofr.eu) or [infomaniak.com](https://www.infomaniak.com/en/storage/drive).

### 🏠 Self-hosted (Nextcloud / OwnCloud)

If you run your own Nextcloud or OwnCloud server:

| Software | WebDAV URL |
|----------|-----------|
| **Nextcloud** | `https://your-server/remote.php/dav/files/YOUR_USERNAME` |
| **OwnCloud** (recent) | `https://your-server/remote.php/dav/files/YOUR_USERNAME` |
| **OwnCloud** (older installs) | `https://your-server/remote.php/webdav/` |

> 💡 Not sure which URL your Nextcloud uses? Log into the web UI → click your avatar (top right) → Personal settings → Security. The WebDAV URL is listed at the bottom of that page.

---

## 📦 Installation

1. Download or copy the `claudesync.koplugin` folder
2. Place the entire folder inside your KOReader `plugins` directory:
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/claudesync.koplugin/`
   - **Android:** `/sdcard/koreader/plugins/claudesync.koplugin/`
   - Other platforms: look for the `plugins` folder inside your KOReader installation
3. Restart KOReader
4. The plugin appears under the **Tools menu → More tools → ClaudeSync** (the Tools menu is the wrench-and-screwdriver icon in the top bar — tap the center of the screen while reading to reveal it)

---

## 💾 Before Your First Sync

Make a manual backup first. Connect your device to a computer and copy the entire:
- **Kobo:** `.adds/koreader/` folder (it's hidden — enable "Show hidden files" in your file manager)
- **Android:** `koreader/` folder from internal storage

Keep this copy somewhere safe. If anything ever goes wrong, you can restore it by copying the files back.

---

## ⚙️ Setup

Tap **Tools menu → More tools → ClaudeSync → Server settings…** and fill in the four fields:

**Koofr example:**
```
Server address:  https://app.koofr.net/dav/Koofr
Username:        your Koofr email address
Password:        your Koofr password
Remote folder:   koreader-sync
```

**Infomaniak kDrive example:**
```
Server address:  https://connect.drive.infomaniak.com
Username:        your Infomaniak username
Password:        your Infomaniak password
Remote folder:   koreader-sync
```

**Nextcloud / OwnCloud example:**
```
Server address:  https://cloud.yourserver.com/remote.php/dav/files/YourUsername
Username:        YourUsername
Password:        your password
Remote folder:   koreader-sync
```

The remote folder is created on the server automatically — no need to create it first. Tap **Save** when done.

---

## 🔄 Using the Plugin

Everything lives under **Tools menu → More tools → ClaudeSync**.

### Syncing

| Option | What it does |
|--------|-------------|
| **Sync now** | Runs a sync immediately — including the book you're currently reading |
| **Auto-sync: on/off** | Master switch for all automatic syncing |
| **Auto-sync options →** | Granular control over *what* and *when* to auto-sync (see below) |

> **Syncing while reading:** Tapping *Sync now* while a book is open uploads your latest book progress and annotations immediately, and downloads anything new from other devices. New highlights from other devices won't appear on the page in real time — close and reopen the book to see them.

### Status indicator

A small indicator shows what's happening during and after a sync:

| Icon | Meaning |
|------|---------|
| ⟳ Syncing… | Sync in progress |
| ✓ Sync complete | Finished successfully (fades after a few seconds) |
| ⚠ Device Offline | Wi-Fi is off or unavailable |
| ⚠ Server error: 401 | Wrong username or password |
| ⚠ Server error: 404 | Server address or path is wrong |
| ⚠ Server error: 5xx | Server-side problem |

You can customise the indicator under **Status indicator →**:
- **Position:** overlay in the top-left corner of the reading screen, or switch to the status bar at the bottom instead (requires **External content** to be enabled under **Status bar → Status bar items →** in the main menu)
- **Format:** icon + text (default), icon only, or text only — applies to both corner and status bar positions
- **Default on first install:** corner overlay, icon + text

> **Tip:** In *icon only* mode, error codes (401, 404) aren't visible — the icon just shows ⚠. Switch to *icon + text* or *text only* to see the specific error code in the corner overlay.

### Auto-sync options

Under **Auto-sync options →** you can fine-tune what gets synced and when.

#### What to auto-sync

These items are included in both "Sync now" and automatic syncs. Book progress and annotations are always synced; tick any extras you want:

- Reading statistics
- Vocabulary builder
- Reading profiles
- Book collections ⚠ — stores file paths that may not match on other devices
- Reading history ⚠ — same caveat

> **How non-book items sync:**
> - **Reading statistics** and **Vocabulary builder** use a true three-way merge: new words and reading sessions from every device are combined. Deleting a word on one device propagates to the others on the next sync.
> - **Reading profiles** also merge: new profiles from other devices are added to yours. If the same profile name exists on both sides, your local version wins.
> - **Book collections** and **Reading history** are uploaded only — they use absolute file paths as identifiers, which differ between device types (e.g., `/mnt/onboard/` on Kobo vs. `/sdcard/` on Android), making automatic merging unreliable. To get another device's collections or history, use **Push / Pull → Pull from server** with those items checked.

#### When to auto-sync

Choose which events trigger an automatic sync (all require **Auto-sync** to be on):

- **On launch** — when KOReader starts
- **On book open** — each time you open a book
- **On book close** — each time you close a book (syncs your latest position before you leave)
- **On resume** — when the device wakes from sleep
- **When Wi-Fi connects** — if a sync was pending while offline, it runs as soon as you're back online

#### Reading position sync mode

Under **Auto-sync options → Reading position sync mode** you can control what happens when two devices disagree on how far you've read:

- **Furthest page read wins** *(default)* — good for linear reading. If you've read further on another device, you'll always pick up at the furthest point.
- **Keep my current position** — good for non-linear reading (studying, reference books, re-reading). Your local position is never overwritten by the server; highlights and bookmarks still merge from both sides.

### Push / Pull

Under **Push / Pull →** you'll find one-time manual operations for when you need to force a specific direction. Unlike "Sync now", these **overwrite** — they do not merge.

Check exactly what you want to push or pull (each item is off by default):

- Book progress & annotations
- Reading statistics
- Vocabulary builder
- Reading profiles
- Book collections ⚠
- Reading history ⚠
- KOReader settings ⚠ — contains device-specific values (screen DPI, frontlight levels). Only use this to migrate to a new device.

Then tap **Push to server** or **Pull from server** (both are disabled until at least one item is checked). Both ask for confirmation first. ⚠️ **These cannot be undone.**

After tapping Push or Pull, the button label shows ⟳ while the operation runs, then ✓ on success or ⚠ on error — the same feedback as "Sync now".

### Gesture / button shortcuts

*Sync Now* and *Toggle Auto-sync* are registered as Dispatcher actions. You can bind them to a swipe, tap zone, or hardware button under the KOReader gesture/button settings.

---

## 🔀 How the Merge Works

**Book progress and annotations** — for each book, ClaudeSync:
1. Downloads the server's copy of that book's data
2. Merges it with your local copy
3. Uploads the result back to the server

Merge rules:
- 📑 **Reading position** — controlled by your *Reading position sync mode* setting (furthest ahead wins by default)
- ✏️ **Highlights, annotations, and bookmarks** — use a three-way merge (see below)
- ✅ **Reading status** — "finished" propagates if either side has marked the book complete

### Three-way merge for highlights and bookmarks

ClaudeSync tracks which highlights and bookmarks both devices last agreed on (stored invisibly in each book's settings file). On every sync it compares three versions — what you have now, what was agreed on last time, and what the server has — and resolves them as follows:

| Situation | Result |
|-----------|--------|
| Highlight exists on both devices | Kept; the more recently edited version wins |
| Highlight added on one device since last sync | Added to the other device on next sync |
| Highlight deleted on one device since last sync | Removed from the other device on next sync |
| Note edited on one device | The newer edit wins (or the server's version on a tie) |

**First sync:** When two devices sync for the first time, highlights from both sides are combined (no deletions are propagated yet — there's no baseline to compare against). After the first sync completes, the baseline is saved and all future syncs use the full three-way logic above.

**After syncing while reading:** New highlights downloaded from another device are saved to the book's settings file immediately, but won't appear highlighted on the page until you close and reopen the book.

**Vocabulary builder and reading statistics** use the same three-way merge principle: new words and reading sessions from every device are combined, and deletions propagate across devices.

---

## 🔧 Troubleshooting

**⚠ Device Offline**
Your device is offline or Wi-Fi isn't connected. ClaudeSync will retry automatically when a connection is available.

**⚠ Server error: 401**
Wrong username or password. Go to **Server settings…** and re-enter your credentials.

**⚠ Server error: 404**
The server address or path is wrong. Double-check your WebDAV URL against the examples in the [Setup](#️-setup) section above.

**Sync runs but nothing changes on the other device**
Make sure both devices have the same book file (same edition, same file). ClaudeSync identifies books by a fingerprint of the file content — a different copy of the same book won't match.

**I synced but highlights from another device aren't showing on the page**
This is expected — new highlights are downloaded and saved immediately, but the page doesn't re-draw while the book is open. Close the book and reopen it; the highlights will appear.

**Status indicator isn't appearing**
The corner overlay is on by default. If you've switched it off, go to **Status indicator** and select **Corner icon** or **Status bar**. The status bar option only shows inside the reading view when the footer bar is visible, and requires **External content** to be enabled: go to the main menu → **Status bar → Configure items** and tick **External content**.

---

## 🤖 Fine Print

Written by [Claude](https://claude.ai) in collaboration with a non-developer user. No human developer has reviewed the code independently. Provided as-is, without warranty. Back up your data before use.

<<<<<<< HEAD
If you hit a bug, check the KOReader log file (`koreader.log` or `crash.log` in your KOReader directory) for lines starting with `ClaudeSync:` — those will tell you exactly what went wrong.
=======
If you hit a bug, check the KOReader log file (`koreader.log` or `crash.log` in your KOReader directory) for lines starting with `ClaudeSync:` — those will tell you exactly what went wrong.
>>>>>>> 431fd385119231f20be84f10ec6a92393ad57fde
