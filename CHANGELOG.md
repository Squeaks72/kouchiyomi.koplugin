# Changelog

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
