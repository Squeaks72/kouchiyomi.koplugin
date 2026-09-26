# Changelog

## 0.9.1 — 2026-09-26
- Which way a spread turns the screen is now a setting: Settings ▸ Reading ▸ "Which way it turns" ▸
  as KOReader does (default, unchanged) / always clockwise / always counter-clockwise. Which of the two
  landscapes puts the page-turn buttons under your thumb depends on which edge you hold the device by,
  so it is a preference rather than something the plugin can work out.
  - "As KOReader does" keeps which way up the device is being held -- upright portrait turns clockwise,
    upside-down portrait counter-clockwise -- the rule its own "Toggle orientation" uses. An unset or
    unrecognised value reads as this, so nothing changes until you pick.
  - The hand toggle ("Uchiyomi: portrait / landscape") follows the setting too.
  - Turning back to portrait always returns to the upright it came from and is never derived from the
    landscape: with a direction forced, deriving it would land on upside-down portrait.

## 0.9.0 — 2026-09-25
- **Double-page spreads turn the screen themselves.** A spread is scanned as one wide image and lands as
  two postage stamps on an upright screen; now a page wider than it is tall (w/h ≥ 1.2) turns the screen
  to landscape as it arrives, and the next single page turns it back. No reaching for the device.
  - Turning it by hand always wins. KOReader's own "Toggle orientation", the gear menu or a G-sensor all
    pass through `SetRotationMode`, which the plugin watches: your orientation stands for as long as the
    pages stay the shape they were when you turned it, so a run of spreads is left exactly as you put it
    and the first single page after it hands control back.
  - The turn happens inside the page-turn's own event, so it costs the one full refresh a rotation needs
    rather than drawing the page twice.
  - Closing a chapter on a spread puts the screen back first -- KOReader writes the rotation it closes in
    into that chapter's settings, so otherwise the next chapter would open sideways.
  - Page mode only: a webtoon read as one long strip has no page to be wide, and turning the screen
    mid-scroll is only disruptive.
  - Settings ▸ Reading ▸ "Turn the screen for double-page spreads" turns it off.
- Two new gesture actions (Gestures / Profiles, or Dispatcher anywhere it is used):
  **"Uchiyomi: portrait / landscape"** and **"Uchiyomi: rotate for wide pages on/off"**. The first is a
  plain orientation toggle that also stands the automatic rotation down, so it does not undo you on the
  next page. (KOReader's built-in "Toggle orientation" works too, and is watched the same way.)
- Diagnostics gains the current rotation, the open page's width/height ratio and whether the automatic
  rotation is standing down.
- `tests/rotation.lua` covers the orientation arithmetic, the spread threshold and the stand-down rule;
  like the other offline tests it needs neither KOReader nor a device.

## 0.8.0 — 2026-09-25
- A second reason to keep a finished chapter, alongside the grace period: **the last 3 chapters you
  read in a series** stay on the device however long ago you read them (Settings ▸ Reading ▸ "Always
  keep the last N chapter(s) read in a series": off / 1 / 2 / 3 / 5 / 10). Either rule holding is
  enough to keep a chapter, so the grace period bounds how *long* one survives and this bounds how
  *many* -- a series you are working through never thins out behind you, and one you left months ago
  still has its last few chapters when you come back.
  - Finishing another chapter releases the oldest one, so a series settles at exactly N kept chapters.
  - Ranked among the chapters awaiting cleanup -- the ones you have read and still have. Chapters
    waiting *ahead* of you from the read-ahead are not in that set and cannot eat the budget, and one
    series cannot spend another's (it counts per download folder).
  - Set it to off for 0.7.0's behaviour, where the grace period is the only thing holding a chapter.
- `tests/cleanup.lua` now covers both rules and how they combine, including the settle-at-N invariant.

## 0.7.0 — 2026-09-25
- A finished chapter is no longer deleted the moment Uchiyomi confirms it read. It is now kept for
  **7 days** first (Settings ▸ Reading ▸ "Grace period before it goes": none / 1 / 3 / 7 / 14 / 30 days).
  The chapter you just read is the one you are most likely to want straight back -- turning back from
  the first page opens it, and catching up with Uchiyomi can land in it -- and re-downloading it over
  Wi-Fi to read one page backwards was a poor trade for the space.
  - Opening the chapter again restarts its grace period.
  - Nothing is asked of the server while a chapter is inside its period, so a week of pending files
    costs no requests; the read check still happens at the end, so a chapter you un-read on Uchiyomi is
    kept as before.
  - Chapters already queued for deletion by an older version start a fresh period instead of being
    swept on the upgrade.
  - The storage cap (Settings ▸ Downloads) still evicts oldest-first regardless, so a long grace period
    cannot quietly fill the device when a cap is set.
  - "Delete a finished chapter once Uchiyomi has it marked read" is unchanged and still turns the whole
    thing off; "none" reproduces the old delete-straight-away behaviour exactly.
  - `tests/cleanup.lua` covers the retention rule; like the other two offline tests it needs neither
    KOReader nor a server.

## 0.6.0 — 2026-09-24
- Catching up now works across chapters, not just inside one. Reading five chapters on the phone used
  to leave the Kobo opening the old chapter with nothing to say -- its own page really was the page you
  left it on. Opening any chapter of that series now asks the series-level question instead: "Uchiyomi
  is further along in this series: Ch. 12, page 8 of 20. Go there?" -- and going there opens that
  chapter at that page.
  - The chapter is downloaded first when it is only on the server, or streamed when streaming is your
    open mode; a chapter already downloading in the background is waited for rather than fetched twice.
  - Where you are in a series comes from Uchiyomi's own "Keep reading" rail (`/api/home` onDeck), which
    already means "the chapter you are part-way through, or the next unread one" -- one request, and the
    same answer the web app shows you. A series that has fallen off the rail falls back to `/api/history`.
  - Forward only: an older position on the server never closes the chapter you deliberately opened, and
    "Stay here" is remembered for that chapter until KOReader restarts.
  - Settings ▸ Sync ▸ "When Uchiyomi is on a later chapter": ask (default), jump silently, or ignore.
    Tools ▸ Uchiyomi ▸ "Jump to where Uchiyomi left off" asks on demand.
  - `tests/series_position.lua` covers the position lookup and the forward-only rule; like
    `prev_chapter.lua` it needs neither KOReader nor a server.
- Fixed: opening at a specific page did not survive the open. A bookmark tapped in the browser recorded
  its page on the plugin instance that was about to be replaced by the one for the new document, so the
  page was lost and the chapter opened wherever it had been left -- and the per-chapter progress pull
  ran anyway and argued with it. Both now go through the same place as the previous-chapter jump.

## 0.5.0 — 2026-09-24
- Turning back on the first page of a chapter now opens the previous chapter at its last page, the
  mirror of turning forward past the last one. Swipe, tap zone and page keys all do it; streaming does
  it too. Nothing is marked read and nothing is deleted going backwards -- it is only reading back
  across a chapter break.
  - The chapter is downloaded first when it is only on the server (or streamed, when streaming is your
    open mode), and a chapter already read once is remembered, so the usual back-turn costs no request.
  - Uchiyomi routes `/api/books/:id/next` but nothing for `previous`, although the server implements it
    (`bookPrevious`), so the plugin works it out from the series' own chapter list -- which comes back in
    exactly the order the server defines adjacency in. `tests/prev_chapter.lua` covers that search and
    needs neither KOReader nor a server.
  - Settings ▸ Reading ▸ "Turn back from page 1 to the previous chapter" turns it off.

## 0.4.7 — 2026-09-22
- View mode now decides per series instead of per library: a chapter's pages are measured when it
  opens, and Toonily/Manhwa18-style long strips get continuous scroll while manga pages keep one page
  per turn. The answer is remembered for the series, so its later chapters arrive already set.
  - The threshold (height ≥ 2.5× width) comes from measuring the library: manga sources run 1.40-1.50
    with one page at 1.99, the webtoon sources sit at a median of ~20 and reach 45.
  - Three pages are sampled and the middle one decides, so a normal-looking cover inside a long-strip
    chapter (or one tall spread in a manga) cannot swing it.
- "One page per turn", "Continuous scroll" and "Leave KOReader alone" are all still there to override it.

## 0.4.6 — 2026-09-22
- Chapters now open one page per turn by default. KOReader opens a comic in continuous scroll, which
  reads a webtoon's long strips but turns manga pages into a scroll. Settings ▸ Reading ▸ New chapters ▸
  View mode switches back to continuous (or out of the plugin's hands) per library habit.
- Chapters already on the device follow on their next open, the same as the page turning direction.

## 0.4.5 — 2026-09-22
- Settings ▸ Reading ▸ Progress bar and interface: mirror the reader's own furniture to match
  right-to-left page turning (`invert_ui_layout`), never mirror it, or leave KOReader alone. Like the
  page turning itself, this reaches chapters already on the device the next time they open.

## 0.4.4 — 2026-09-22
- Manga reads right to left, and now so does the plugin: chapters open with right-to-left page turning
  by default (the tap zone on the right turns forward). Settings ▸ Reading ▸ Page turning can set it to
  left to right, to follow the series' own reading direction, or to leave KOReader alone.
  - Why the old "follow the series" setting never did this: Uchiyomi's server reports `WEBTOON` as the
    reading direction for every series it owns, so there was never an RTL to follow.
- New chapters can be seeded with a view mode (one page per turn vs continuous scroll), page crop and
  hardware dithering, under Settings ▸ Reading ▸ New chapters. Written into the chapter's sidecar as it
  downloads, so it is right on the first paint.
- Chapters already on the device get the reading direction (and view mode) on their next open; crop and
  dithering apply to new downloads only, and a setting changed by hand on a chapter is never overwritten.

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
