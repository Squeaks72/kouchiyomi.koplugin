# Tests

`prev_chapter.lua` needs neither KOReader nor a server -- it runs the
previous-chapter search against a stubbed series list:

```sh
cd /path/to/kouchiyomi.koplugin && lua5.1 tests/prev_chapter.lua
```

The rest run with KOReader's own LuaJIT from an extracted KOReader install (the
Linux AppImage works: `./koreader.AppImage --appimage-extract`), against a live
Uchiyomi server. They create and remove bookmarks and a silent no-op progress
write on the first chapter of the first "blame" search hit; nothing else is
changed.

```sh
cd <koreader dir>   # the folder holding luajit, reader.lua, frontend/, common/
KOUCHIYOMI_DIR=/path/to/kouchiyomi.koplugin \
UCHI_URL=https://your.uchiyomi UCHI_TOKEN=uy_... UCHI_USER=you UCHI_OPDS=<opds token> \
./luajit /path/to/kouchiyomi.koplugin/tests/api_live.lua

KOUCHIYOMI_DIR=/path/to/kouchiyomi.koplugin UCHI_URL=... UCHI_TOKEN=uy_... \
./luajit /path/to/kouchiyomi.koplugin/tests/bookmarks_live.lua
```

`emulator_patch.lua` is a KOReader user patch (drop it in
`<data dir>/patches/2-kouchiyomi-test.lua`, with the plugin installed and
configured) that drives the real KOReader UI headlessly:
browse → download → open → bookmark both ways → progress both ways → stream.
Run KOReader with `SDL_VIDEODRIVER=dummy` and read the `KTEST` lines in the log.
