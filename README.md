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
- **A BookOrbit-styled browser, when BookOrbit is installed**: the Uchiyomi browser and chapter lists are drawn with
  BookOrbit's own primitives instead of stock KOReader widgets -- grid cards everywhere a thumbnail-and-title-beside-it
  list row used to be, a search bar pinned to Home, Keep reading and your chosen lists as horizontally-paged shelves,
  Browse as a grid of icon tiles, and a settings shortcut in every header. Entirely optional and detected at runtime
  (`uchi/ui_theme.lua`); without BookOrbit installed the original stock-widget browser renders exactly as before.
  Settings ▸ "Choose home screen lists" (also reachable from Browse) picks which lists show as shelves. Hold a Keep
  reading card for quick actions: remove it from the row without marking it read, or mark read (which advances the
  card to the series' next unread chapter instead of just dropping it).
- **An Uchiyomi icon in KOReader's top menu bar**, in the reader and the file browser (Settings ▸ Layout turns it
  off). In a chapter it opens a sheet: **Series page** and **Library** (straight back to where this series lives),
  Browse (home, new chapters, favourites, bookmarks, libraries, search, downloads), previous chapter, mark read and go
  to the next, right-to-left page turning, rotate, sync now, favourite, add to a list, and every series action below.
  Outside a chapter it opens the browser's sections. Drawn in BookOrbit's style when BookOrbit is installed.
- **Hold a series thumbnail** for: continue reading, download the next unread chapters, favourite, add to a list (or a
  new one), mark all read / unread (one request), series info, open its library, delete its downloaded chapters from
  the device, check for new chapters, monitor / stop monitoring, and **remove from library** (hides it on the server;
  files and progress are kept and an admin can put it back). The last three are Uchiyomi admin actions, which this
  device's read + write token is refused on purpose: they ask for the admin password once, use the 15-minute session
  it returns and keep it in memory only. Hold any chapter outside its series (new chapters, bookmarks, Keep reading)
  for Open series / Series actions.
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
  Uchiyomi confirms it is read and nothing is still holding it. Two things can
  hold it, and either is enough — a **grace period** (7 days by default;
  opening the chapter again restarts it) and **the last few chapters you read
  in that series** (3 by default, released one at a time as you finish more).
  The first bounds how long a read chapter survives, the second how many, so
  the chapters just behind you are always there to turn back into. Settings ▸
  Reading tunes both or turns the removal off entirely; progress and bookmarks
  live on Uchiyomi either way, so a deleted chapter is one download away.
- **Spreads turn the screen**: a double-page spread is one wide image, and on an
  upright screen it lands as two postage stamps. A page wider than it is tall
  turns the screen to landscape as it arrives; the next single page turns it
  back. Turning the device by hand always wins — your orientation stands while
  the pages stay that shape, so a run of spreads is left as you put it. Which
  landscape it turns to is a setting (as KOReader does / always clockwise /
  always counter-clockwise — whichever puts the buttons under your thumb). Page
  mode only; Settings ▸ Reading turns it off. Gestures: "Uchiyomi: portrait /
  landscape" and "Uchiyomi: rotate for wide pages on/off" (KOReader's own
  "Toggle orientation" is understood too).
- **Two pages side by side in landscape**: turn the device on its side and the
  page you are on is shown with the next one beside it, like an open book —
  for reading double pages even when the source did not scan them as one.
  Works downloaded and streamed. Right-to-left puts the page you are on on the
  right; a page turn moves past both, and a real (wide) spread keeps the screen
  to itself. A screen the plugin turned for a spread stays single; this is for
  a screen you turned yourself. Settings ▸ Reading turns it off.
- **18+ is listed only when asked, and read like anything else**: 18+ series are not listed on the home screen, in
  updates, favourites, history, bookmarks or a plain search, because the plugin stops asking the server to include
  them (Settings ▸ Server: "Show 18+ in search and lists" turns that around; "Let me open 18+ libraries" covers a
  library marked 18+). A chapter you open streams or downloads according to the ordinary open mode. (An admin can also
  mark genres as adult server-side; that list is not exposed by the API, so only libraries and per-series age ratings
  are detected.) While an 18+ chapter is on screen, KOReader's sleep screen is held at a covered panel — the
  screensaver is painted before a plugin hears about the suspend, so it has to be arranged in advance — and released
  when the chapter closes. "Remove downloaded 18+ chapters now" clears any that are on the device.
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
| 18+ hidden from listings              | not sending `?adult=1` (server's `browsable()`) |
| is this series 18+                    | `adult` on `/api/libraries`, `metadata.ageRating` |
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
