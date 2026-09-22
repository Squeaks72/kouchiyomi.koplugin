# Changelog

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
