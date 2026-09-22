# Changelog

## 0.1.1 — 2026-09-22
- Fix: 2FA login sent the one-time code in the wrong field (`totp` instead of `code`), so accounts with 2FA could not sign in. Spaces in the code are now ignored and login errors are spelled out.

## 0.1.0 — 2026-09-21
- First release. Browse, download (OPDS whole-file or page assembly), stream,
  two-way progress sync, two-way page-bookmark sync, next-chapter flow,
  offline library, favourites, mark read/unread, per-series reading direction.
