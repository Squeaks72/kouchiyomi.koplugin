# Changelog

## 0.4.3 — 2026-09-22
- Fix: with kokomga installed alongside, the end of a chapter always showed KOReader's own dialog. kokomga loads first (alphabetical) and hooks the same handler with the same marker field, so ours stood down. Ours now wraps whatever handler is present and runs first; a fallback also catches the event as a reader module and closes KOReader's dialog if it slipped through. Diagnostics names the other plugin.

## 0.4.2 — 2026-09-22
- Auto-advance (Reading setting, on by default): turning past the last page opens the next chapter with no dialog when it is on the device, downloads it first when it is only on the server (or streams it when streaming is your open mode), or waits for a running read-ahead. The chapter-end dialog still appears when offline without the chapter, on the last chapter, or when the server fails.

## 0.4.1 — 2026-09-22
- Read-ahead is fully silent: no notice when a background download finishes, when the storage cap evicts an old chapter during one, or when a finished chapter is cleaned up. All of it still goes to the log and Diagnostics.

## 0.4.0 — 2026-09-22
- Read ahead: after a chapter opens, the next N chapters (setting, default 1) are downloaded in a forked background process, so the reader never waits and the end-of-chapter prompt usually says "ready". Counts against the storage cap.
- Cleanup: when you move on from a finished chapter, its file is deleted once Uchiyomi confirms it is read (setting, default on). Progress and bookmarks live on the server.
- One chapter-end dialog for downloaded and streamed chapters: next chapter's cover, what was finished, what is next and its state (ready / downloading / not on device / last), with matching actions.
- Reader footer shows "⇅N" while changes wait to sync and "↓N" while background downloads run (setting).
- Browser home is now Uchiyomi's home: Keep reading first, then new chapters in favourites, then the browse entries. A pending-sync line appears on top when needed.
- Chapter labels everywhere read like Uchiyomi: "One Piece · Ch. 944", "Vol. 3" for volume archives; a chapter's own title, when it has one, becomes the second line.

## 0.3.2 — 2026-09-22
- Offline end of chapter no longer opens "the next downloaded file in the series", which skipped chapters when some were missing (944 → 947). Only the chapter Uchiyomi named as next is ever opened. The plugin now caches that answer every time a linked chapter is opened online.
- When that chapter is not on the device (or is unknown), the dialog says so and offers "Turn on Wi-Fi and fetch it": KOReader's reconnect prompt, then the finished chapter is synced, the next one downloaded and opened.

## 0.3.1 — 2026-09-22
- Chapters that reached the device outside the plugin (syncthing, USB, another client) were never linked to Uchiyomi, so finishing one fell through to KOReader's own end-of-document dialog with no explanation. Files inside the download folder are now auto-linked on open by series folder and chapter title/number.
- End of chapter on an unlinked chapter in the download folder now says so and offers "Link it now..." instead of silently showing KOReader's dialog. A handler error is shown on screen, not just logged.
- Tools ▸ Uchiyomi ▸ Diagnostics: version, server, open file, link state, hook state and the outcome of the last end-of-chapter, for bug reports.

## 0.3.0 — 2026-09-22
- End of chapter (downloaded): turning past the last page now always marks the chapter finished in KOReader and read on Uchiyomi (the push is buffered and retried if it fails), then offers the next chapter. A server error no longer falls through to KOReader's own end-of-document dialog. The handler is guarded so a failure can never block the page turn.
- End of chapter (streaming): turning past the last page marks the chapter read immediately and offers the next chapter, instead of waiting until the viewer is closed. Offers "Open" when the next chapter is already downloaded.
- Browser: "New chapters (favourites)" now lists the next unread chapter of every favourite with unread chapters (newly added chapters first), and opens it on tap.
- Browser: "Keep reading" replaces "Continue reading" and mirrors Uchiyomi's own rail (`/api/home`): per series read lately, the chapter you are part-way through or the next unread one.

## 0.2.0 — 2026-09-22
- Self-updater: Tools ▸ Uchiyomi ▸ Plugin update checks GitHub (daily when online, or on demand), installs the latest files and restarts KOReader. Optional token for private forks.

## 0.1.1 — 2026-09-22
- Fix: 2FA login sent the one-time code in the wrong field (`totp` instead of `code`), so accounts with 2FA could not sign in. Spaces in the code are now ignored and login errors are spelled out.

## 0.1.0 — 2026-09-21
- First release. Browse, download (OPDS whole-file or page assembly), stream,
  two-way progress sync, two-way page-bookmark sync, next-chapter flow,
  offline library, favourites, mark read/unread, per-series reading direction.
