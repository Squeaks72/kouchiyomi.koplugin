# kouchiyomi — KOReader client for Uchiyomi

Browse your [Uchiyomi](https://github.com/AngeloSha/uchiyomi) manga library from
KOReader, download chapters to the device or stream them page by page, and keep
**reading progress and page bookmarks in sync in both directions**.

Derived from [kokomga](https://github.com/JimDBh/kokomga.koplugin) (MIT, Jim
Davis), reworked for Uchiyomi's native API.

## Features

- **Home like Uchiyomi's**: Keep reading (where you left off in each
  series) first, then new chapters in your favourites, then browsing:
  favourites, server bookmarks, recently updated, all series, per-library,
  search, and an offline view of everything downloaded.
- **Read your way**: tap a chapter to download it (default) or stream it from
  the server; the choice is a setting, or ask every time. Hold a chapter for
  download / stream / download this + next N / mark read or unread.
- **Progress sync**: KOReader pushes your page as you read (every N pages, on
  close and on suspend). Opening a chapter pulls Uchiyomi's position; when the
  server is further ahead the reader jumps there (configurable: jump / ask /
  ignore). Offline reads are buffered and flushed when Wi-Fi returns.
  Uchiyomi's state wins ties and is never regressed.
- **Catch up across chapters**: read on your phone and the Kobo notices it is
  a whole chapter behind, not just a page. Opening any chapter of that series
  asks "Uchiyomi is further along in this series: Ch. 12, page 8 of 20. Go
  there?" and opens that chapter on that page, downloading (or streaming) it
  first when it is not on the device. Tools ▸ Uchiyomi ▸ **Jump to where
  Uchiyomi left off** asks on demand; Settings ▸ Sync ▸ "When Uchiyomi is on a
  later chapter" switches it to jumping silently, or off. Forward only -- an
  older position on the server never closes the chapter you just opened.
- **Bookmark sync (two-way)**: KOReader dogear bookmarks ⇄ Uchiyomi page
  bookmarks, reconciled with a three-way merge per chapter, so a bookmark added
  or removed on either side shows up on the other. Works for the open chapter
  and, on reconnect, for every downloaded chapter.
- **Server → device**: "Pull Uchiyomi state into downloaded chapters" (also
  runs automatically when Wi-Fi connects) copies progress and bookmarks into
  every downloaded chapter that is not currently open.
- **Next chapter**: turning past the last page marks the chapter finished
  (in KOReader and on Uchiyomi) and shows one chapter-end dialog: the next
  chapter, its cover and whether it is ready, downloading or missing, with
  open / download / stream actions. Offline, only the chapter Uchiyomi
  named as next is opened (never a later file that would skip chapters);
  if it is missing, the plugin offers to turn Wi-Fi on and fetch it.
- **Auto-advance**: with the setting on (default), the next chapter opens
  without a dialog when it is on the device, and is downloaded first when it
  is only on the server. The dialog is kept for offline-and-missing, last
  chapter and server errors.
- **Previous chapter**: turning back on the first page (swipe, tap zone or
  page key) opens the previous chapter at its last page, downloading it first
  when it is only on the server. Nothing is marked read or deleted going
  backwards. Settings ▸ Reading turns it off.
- **Read ahead & cleanup**: the next chapter(s) download quietly in the
  background after one opens; a finished chapter's file is removed once
  Uchiyomi confirms it is read **and a grace period has passed** (7 days by
  default, because the chapter you just read is the one you are most likely to
  turn back into). Opening it again restarts the clock. Settings ▸ Reading sets
  the period (none / 1 / 3 / 7 / 14 / 30 days) or turns the removal off
  entirely; progress and bookmarks live on Uchiyomi either way, so a deleted
  chapter is always one download away.
- **Footer**: "⇅N" while changes wait to sync, "↓N" while downloads run.
- **Series actions**: favourite, download next unread N, mark all read.
- **Reads like manga**: chapters open with right-to-left page turning, so the
  right side of the screen turns forward. Settings ▸ Reading ▸ Page turning
  changes it (Uchiyomi's server calls every series a webtoon, so "follow the
  series" cannot be trusted to know). The progress bar and the reader's layout
  can mirror to match. Manga opens one page per turn and long-strip webtoons
  open in continuous scroll, decided from the shape of the pages themselves
  (the server calls everything a webtoon, so it cannot be asked). New chapters
  can also be seeded with a page crop and hardware dithering.
- Covers, list/grid views, series subfolders, storage cap, 18+ libraries opt-in.

## Install

1. Copy the `kouchiyomi.koplugin` folder to `koreader/plugins/` on the device
   (Kobo: `/.adds/koreader/plugins/kouchiyomi.koplugin`).
2. Restart KOReader.
3. Tools ▸ **Uchiyomi** ▸ Server ▸ *Server: not set* and enter the server URL,
   username and password. The password is used once to mint a long-lived API
   token (visible in Uchiyomi under Profile ▸ Connections ▸ API tokens) and,
   with your consent, an OPDS token for fast whole-file CBZ downloads.
   Without an OPDS token chapters are still downloadable, page by page.
4. Open Tools ▸ Uchiyomi ▸ **Uchiyomi browser**.

Requires KOReader 2024.11 or newer (annotations model). Tested against
Uchiyomi v0.39.

## How it maps

| KOReader                              | Uchiyomi                                   |
|---------------------------------------|--------------------------------------------|
| page N of a downloaded/streamed CBZ   | `PUT /api/books/{id}/progress {page, completed}` |
| where you are in a series             | `/api/home` onDeck, else `/api/history`     |
| dogear bookmark on page N             | `PUT/DELETE /api/bookmarks/{bookId}/{page}` |
| downloaded file ⇄ chapter             | `uchiyomi_book_id` in the sidecar          |
| whole-chapter download                | `/opds/book/{id}/file` (OPDS token)        |
| streaming pages                       | `/api/v1/books/{id}/pages/{n}`             |

Notes attached to bookmarks are not synced (no write path in Uchiyomi's API).
While streaming, bookmarks are unavailable (KOReader's image viewer is not a
document); download the chapter for the full experience.

## Updating

Tools ▸ Uchiyomi ▸ **Plugin update** ▸ *Check for updates now* fetches the
latest files straight from this repository and restarts KOReader. The plugin
also checks once a day when online and shows a notice if a newer version exists.
A private fork needs a fine-grained GitHub token (Contents: read) entered under
the same menu; this public repository needs none.

## Settings file

`koreader/settings/kouchiyomi.lua`. Covers are cached in
`koreader/kouchiyomi_covers/`.

## Licence

MIT. See `LICENSE`.
