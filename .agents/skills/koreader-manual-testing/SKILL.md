---
name: koreader-manual-testing
description: Drive the real KOReader emulator GUI (no mouse, no human) to manually / exploratorily / visually test the readeck.koplugin - take screenshots and look at them, dump the visible widgets, tap menus and buttons, type into dialogs, open articles, select text to highlight, sync with a disposable local Readeck server and check the result on that server. Use when asked to "try it in the emulator", check how a dialog or menu looks, reproduce or confirm a UI bug, verify a plugin change end to end by eye, or collect screenshots. Not for automated regression tests (those live in spec/ and e2e/).
---

# KOReader manual testing with `tools/kodrive`

`tools/kodrive` (python3, stdlib only) starts the real KOReader emulator (an SDL window on
the Mac) with a dev-only plugin, `tools/agentdriver.koplugin`, that serves a JSON control
API on `http://127.0.0.1:18950`. Every action command waits until the UI has **settled**
(nothing dirty, no task due within 0.4 s, window stack stable for 3 polls) before it
answers, so you never need `sleep`.

## Safety rule

kodrive only ever points the emulator at **its own disposable local Readeck**
(`e2e/readeck_local.py`, `http://127.0.0.1:18960`, state in
`references/readeck-local-manual/`). It deliberately strips `READECK_*` from the
environment, because the user's shell has `READECK_URL`/`READECK_TOKEN` pointing at a
**production** server. Never type a production URL/token into the emulator, never edit
`references/kodrive/profile/settings/readeck.lua` to point elsewhere, and never pass the
environment's `$READECK_URL` to curl — unless the user explicitly says so for that run.
Use `tools/kodrive api ...` to query the server; it always talks to the local one.

## Prerequisites

- Emulator build: `references/koreader/koreader-emulator-*/koreader/luajit` must exist.
  If not: `mise run setup` (links `references/koreader`) then `mise run emulator-build`
  (slow, needs the Homebrew deps listed in `references/koreader/doc/Building.md`).
- A Readeck binary is downloaded on first use into `references/readeck-bin/` by
  `e2e/readeck_local.py` (needs network once).
- Ports: driver 18950, Readeck 18960, fixture site 18961. (18900-18949 belong to the
  automated e2e suite; do not use them.)

## Start / stop

```bash
tools/kodrive start --fresh --seed 3     # fresh profile + local Readeck with 3 loaded bookmarks
tools/kodrive start                      # reuse profile (articles, highlights, settings survive)
tools/kodrive start --fresh-readeck      # also recreate the Readeck server from scratch
tools/kodrive start --device kindle-paperwhite   # or --size 540x720 --dpi 212 (default "small")
tools/kodrive start --open path/to/file.epub     # start straight in the reader
tools/kodrive status
tools/kodrive stop          # quits KOReader cleanly (settings saved); kills it after 15 s
tools/kodrive stop --all    # ... and stops the local Readeck + fixture server
```

`start` prints JSON with the screen size, profile dir, articles dir, log path and the
Readeck URL. It: starts Readeck if not running (and seeds bookmarks with `--seed N`),
writes a profile under `references/kodrive/profile/` (`KO_HOME`), writes
`settings/readeck.lua` for the local server with downloads in
`references/kodrive/profile/articles/`, links `tools/agentdriver.koplugin` into the
profile's `plugins/` and `readeck.koplugin` into the build's `plugins/` (same link as
`mise run emulator-run`), launches `./luajit reader.lua -d` in the background, and waits
for the driver to answer.

**Sizes are window points; on a Retina Mac the framebuffer is 2x.** The default `small`
(540x720) gives a 1080x1440 screen. All coordinates (tree rects, taps, screenshots) are
in framebuffer pixels, so they always agree with each other — use `kodrive info` for
the real size. Bigger devices make bigger screenshots (kindle-paperwhite: 2144x2896).

Always `tools/kodrive stop --all` when you are done.

## Command reference

Every command prints JSON: `ok`, `result`, `settle` (`idle`, `waited_ms`, `busy` if it
timed out), `top` (class of the topmost window) and `dialog` — the texts of all
non-fullscreen windows, **topmost first**. `dialog` is usually all you need to know what
a tap did; take a screenshot when layout matters. Exit status 2 when `ok` is false.

Extra `k=v` params work on any command:
`shot=FILE.png` (screenshot after settling), `timeout=SECONDS` (settle timeout, default
15; raise it for syncs), `settle=0` (answer immediately), `dialog=0` (skip the summary).

| Command | What it does |
| --- | --- |
| `shot [FILE]` | PNG of the screen (default `references/manual-artifacts/shot-<time>.png`). Look at it with the `read` tool. |
| `tree` | Windows (bottom→top) and visible elements: `#id class "text" icon=… @x,y wxh [tap,disabled,checked,input,focused]`. Windows under a fullscreen one are marked HIDDEN and skipped (`all=1` to include). `full=1` = untruncated text, `--json` = machine-readable. |
| `find TEXT` | Matching elements with their centre, without tapping. |
| `info` | Screen size/DPI, `ui` (`filemanager`/`reader`), open document, page/pages, FM path. |
| `tap X Y` | touch + tap gesture at a point. |
| `tap-text TEXT [INDEX]` | Tap the centre of a visible element whose text contains TEXT (case-insensitive; `exact=1`, `pattern=1` for a Lua pattern, `win=N`). Topmost window first; INDEX (1-based) picks among matches. On failure the error lists every visible text. |
| `tap-icon NAME [INDEX]` | Same, by icon name (`appbar.tools`, `chevron.right`, `home`, `plus`, …; see `tree`). |
| `tap-id ID` | Tap element `#ID` from the last `tree`. |
| `hold X Y` / `hold-text TEXT` | Long-press (`duration=0.3`). E.g. holding a file opens its file dialog. |
| `hold-pan X0 Y0 X1 Y1` | hold at P0, drag to P1, release — raw text selection. |
| `select-text TEXT` | Reader only: finds TEXT on the current page and hold-pans from its first to its last glyph. Leaves the highlight popup (Highlight / Add note / …) open. `goto=1` jumps to the first occurrence if it is not on screen, `index=N` picks the N-th visible occurrence. |
| `doc-find TEXT` | Reader only: xpointers + screen boxes of TEXT (`visible` = on this page). |
| `swipe left\|right\|up\|down` or `swipe X0 Y0 X1 Y1` | Swipe gesture (in the reader, `left` = next page). |
| `pan X0 Y0 X1 Y1` | Slow pan + release (scroll lists). |
| `key NAME` | KeyPress+KeyRelease: `Back`, `Menu`, `Home`, `Up`, `Down`, `Left`, `Right`, `Press`, `LPgFwd`, `LPgBack`, … (`mods=Shift,Ctrl`). `key Back` closes a dialog / goes up a menu level. |
| `type TEXT` | Insert text into the focused input field (else the topmost one). `clear=1` empties it first. Returns the resulting value. Submit by tapping the dialog's button. Use `text=...` if TEXT itself looks like `word=value`. |
| `open PATH` | Open a document in the reader. |
| `home` | Reader → file manager (current file's folder); in the FM, go to the home folder. |
| `wait` | Just wait for the UI to settle. |
| `log [N] [grep=STR]` | Last N lines of the emulator log (`references/kodrive/koreader.log`; the plugin logs at debug level). |
| `eval 'LUA'` / `eval -` | Run Lua inside KOReader (expression or statements; `-` reads stdin). In scope: `ui` (ReaderUI or FileManager), `UIManager`, `Device`, `Screen`, `Event`, `Geom`, `Inspect`, `driver`. |
| `raw CMD k=v…` | Any driver endpoint directly, e.g. `raw tap_text icon=chevron.right win=2`. |
| `api METHOD PATH [JSON]` | curl the **local** Readeck with its token, e.g. `api GET /api/bookmarks`. |
| `readeck-env` | `export` lines for the local server (URL, token, user `e2e`/`e2e-password`, fixture URL). |

The HTTP API is the same without the CLI:
`curl -s 'http://127.0.0.1:18950/tap_text?text=Synchronize&shot=/tmp/a.png'`
(GET query or POST form/JSON; `curl http://127.0.0.1:18950/help` lists commands).

## Finding things

- **Main menu**: tap the top strip (`tap 540 30` on the default screen, i.e. x = centre,
  y ≈ 2 % of height) in both the file manager and the reader. Tabs are icons:
  `appbar.filebrowser` / `appbar.navigation`, `appbar.settings`, `appbar.tools`,
  `appbar.search`, `appbar.menu`.
- **Readeck menu**: tools tab (`tap-icon appbar.tools`) → page 2
  (`tap-icon chevron.right 1 win=2`; page 1 lists other plugins) → `tap-text Readeck`.
  File-manager entries: *Synchronize articles with server*, *Process finished/read
  articles*, *Go to download folder*, *Settings ▸*, *Info*. The reader adds *Sync current
  article highlights*. Server URL etc. are under *Settings ▸ Configure Readeck server ▸*.
- Menus page: when an item is missing, check for `Page 1 of 2` in `dialog` and go to the
  next page with the menu's `chevron.right` (use `win=` of the menu window from `tree`).
- `key Back` goes one level up in a menu and closes dialogs; tapping outside an
  InfoMessage (e.g. `tap 540 1300`) dismisses it.
- The emulator reports a keyboard, so file lists show `Q W E R` shortcut hint boxes and
  input dialogs open **without** an on-screen keyboard. That is KOReader behaviour, not a
  plugin bug. `type` works regardless.
- Page text in the reader is not a widget — `tree` shows only the footer. Use
  `doc-find` / `select-text`.

## Worked walkthrough: sync → open → highlight → export → verify

```bash
K=tools/kodrive; A=references/manual-artifacts/walkthrough; mkdir -p $A
$K start --fresh --seed 3                       # note the bookmark ids it prints
$K shot $A/01-start.png
$K tap 540 30 dialog=0                          # open the main menu
$K tap-icon appbar.tools dialog=0
$K tap-icon chevron.right 1 win=2 dialog=0
$K tap-text Readeck shot=$A/02-readeck-menu.png
$K tap-text "Settings"; $K tap-text "Configure Readeck server"   # dialog shows "Server URL: http://127.0.0.1:18960"
$K key Back; $K key Back
$K tap-text "Synchronize articles" timeout=60 shot=$A/03-sync.png
#   dialog: "Processing finished.\nDownloaded: 3\nSkipped: 0"
$K tap 540 1300 dialog=0                        # dismiss; the 3 EPUBs are listed
ls references/kodrive/profile/articles/         # "<title> [rd-id_<bookmark id>].epub"
$K tap-text "Mechanical Clocks" timeout=30 shot=$A/04-article.png
$K select-text "stores energy in a wound spring" shot=$A/05-selected.png
$K eval 'ui.highlight.selected_text.text'       # confirm exactly what got selected
$K tap-text Highlight exact=1 shot=$A/06-highlighted.png
$K eval 'ui.annotation.annotations[1]'          # pos0/pos1 xpointers, text, datetime
$K tap 540 30 dialog=0; $K tap-icon appbar.tools dialog=0
$K tap-icon chevron.right 1 win=2 dialog=0; $K tap-text Readeck dialog=0
$K tap-text "Sync current article highlights" timeout=60 shot=$A/07-export.png
$K api GET /api/bookmarks/<bookmark id>/annotations   # the highlight should be here
$K stop --all
```

Screenshots of a real run of this are in `references/manual-artifacts/walkthrough/`.
To test server → device: create an annotation with
`$K api POST /api/bookmarks/<id>/annotations '{"start_selector":"section[1]/article[1]/p[1]","start_offset":0,"end_selector":"section[1]/article[1]/p[1]","end_offset":5,"color":"yellow"}'`
(Readeck wants indexed selectors relative to the article), then *Synchronize* and check
`#ui.annotation.annotations` in the opened article and the screenshot.

## Waiting and flakiness

- Don't sleep. Each command returns after the UI settles. If `settle.idle` is `false`,
  `settle.busy` names the task that kept it busy; retry with a larger `timeout=` or call
  `wait`.
- Network work (sync, export) blocks KOReader's UI loop; the request simply takes longer.
  Pass `timeout=60` or more so the settle wait does not give up first; the CLI's HTTP
  timeout is `timeout + 120 s`.
- InfoMessages with a timeout disappear on their own; take the screenshot in the same
  command (`shot=...`) instead of a separate `shot` afterwards.
- `hold-pan` / `select-text` take about 1.3 s: the emulator rate-limits hold-pan
  gestures to 5/s and silently drops faster ones (the driver spaces them for you).
- `tap-text` matches substrings; prefer `exact=1` for short labels (`OK`, `Cancel`,
  `Highlight`, `Info`) and `win=N` when a lower window has the same text.
- After closing a menu, confirm `top.cls` (e.g. `filemanager`, `readerui`) before the
  next step.
- Gestures are injected as KOReader `Gesture` events (the same mechanism as KOReader's
  own tests), so they bypass the gesture detector: there are no accidental double taps,
  but multi-finger gestures are not available.

## Where things go

| What | Where |
| --- | --- |
| Screenshots (default) | `references/manual-artifacts/` (gitignored). Put a run's shots in a subfolder. |
| Emulator log (stdout+stderr, debug) | `references/kodrive/koreader.log` (`kodrive log`) |
| Profile (`KO_HOME`): settings, docsettings (`.sdr` highlights), cache | `references/kodrive/profile/` |
| Downloaded articles | `references/kodrive/profile/articles/` |
| Plugin settings | `references/kodrive/profile/settings/readeck.lua` |
| Local Readeck state/logs/env | `references/readeck-local-manual/` |

## Resetting state

- Device side only: `tools/kodrive stop && tools/kodrive start --fresh` (wipes the
  profile: articles, highlights, plugin settings; the server keeps its data).
- Everything: `tools/kodrive stop --all && tools/kodrive start --fresh-readeck --seed 3`.
- More server bookmarks at any time: `e2e/readeck_local.py seed --dir
  references/readeck-local-manual --count 2`.

## Developing the driver

The driver lives in `tools/agentdriver.koplugin/` (`main.lua` dispatcher,
`agentdriver/{server,commands,inspect,json}.lua`). It is only active when
`AGENTDRIVER_PORT` is set and binds to 127.0.0.1 only. KOReader loads plugins at
startup, so restart the emulator after editing it. `inspect.lua` records every widget's
paint position by wrapping `paintTo`, which is how `tree` knows screen rectangles.
Never ship it with the real plugin.
