# End-to-end suite

The plugin, driven the way a person uses it, inside a real headless KOReader,
against a real Readeck server that is started fresh on your machine for every
test. No mocks: the HTTP client, the menus, the dialogs, crengine rendering and
highlighting, sidecar files and the Readeck API are all the real thing.

```bash
mise run e2e                        # whole suite (~1 minute)
mise run e2e -- sync                # test files whose name contains "sync"
mise run e2e -- -k "bad token"      # tests whose name contains "bad token"
READECK_VERSIONS="0.21.6 0.23.4" mise run e2e   # whole suite per server version
KOREADER_BUILD_DIR=/path/to/koreader mise run e2e   # another KOReader build
```

`e2e/run.sh` is the same thing without mise. It exits non-zero if any test
fails, crashes or unexpectedly passes (see XFAIL below).

For poking at things by hand:

```bash
mise run e2e-server        # local Readeck on :18900 with 3 bookmarks, prints its env
eval "$(python3 e2e/readeck_local.py env)"
mise run e2e-server-stop
```

**Safety.** The suite never talks to a real server. `run.sh` unsets
`READECK_URL`/`READECK_TOKEN`, the harness only uses the env printed by the
server it started, and both the test-side API client and the plugin settings
writer refuse any URL that is not loopback. Ports stay within 18900-18999
(suite default: 18920 for Readeck, 18921 for the fixture site, 18922 for
the truncating proxy).

**Real web pages** (opt-in, needs the internet; not run in CI):

```bash
E2E_REALWORLD=1 mise run e2e -- realworld
E2E_REALWORLD_URLS="https://a https://b" E2E_REALWORLD_COUNT=60 E2E_REALWORLD_SEED=2 mise run e2e -- realworld
```

`tests/realworld_test.lua` bookmarks real pages on the local Readeck, lets
`fixtures/annotation_oracle.py` pick ranges from the stored article HTML
(independently of `position_map.lua`), creates them through the API so Readeck
resolves them, and checks import (crengine shows Readeck's text) and
re-export (Readeck resolves the plugin's selectors to the same text), both on
a plain EPUB and on one downloaded with Readeck's marks and note links.

## Layout

```
e2e/
  run.sh               orchestrator: per version x test file, one KOReader process
  readeck_local.py     provisions a disposable Readeck (binary download, user,
                       API token via the web form, OAuth device approval)
  fixtures/server.py   the web site Readeck bookmarks: static pages, generated
                       /gen/<slug>.html articles, ?delay=N slow pages
  fixtures/site/       static fixture pages (inline.html has <em>/<strong>/<a>;
                       markup.html has nested inline markup, wrapped source
                       lines, entities, <br>, UTF-8 multibyte text and emoji,
                       blockquote and list; empty.html has nothing to extract)
  fixtures/truncating_proxy.py
                       reverse proxy that cuts every EPUB download in half
                       (H.start_truncating_proxy)
  fixtures/annotation_oracle.py
                       picks annotation ranges in real article HTML for
                       realworld_test.lua
  lib/main.lua         entry point run by KOReader's luajit
  lib/bootstrap.lua    headless KOReader: KO_HOME temp dir, dummy framebuffer
                       and input, only readeck.koplugin registered
  lib/harness.lua      runner, assertions, UI recorder, menu/dialog driving,
                       event-loop pumping, screenshots, local-file helpers
  lib/readeck_api.lua  independent Readeck API client for setup and checks
  tests/*_test.lua     the scenarios
```

### How a test runs

`run.sh` starts one KOReader process per test file, with the KOReader build as
working directory and a throwaway `KO_HOME`. Before **every test** the harness
starts a fresh Readeck (about 0.4 s: new data dir, user, token), so tests never
see each other's bookmarks.

`bootstrap.lua` does what KOReader's own `spec/front/unit/commonrequire.lua`
does, without needing it (release tarballs have no `spec/`): dummy framebuffer
(`einkfb.dummy`, it still renders, so screenshots work), dummy input, global
settings in `KO_HOME`, and `PluginLoader` restricted to this repository's
`readeck.koplugin`. `NetworkMgr` is pinned online.

Tests then use KOReader like a user:

- `H.configure_plugin{...}` writes `settings/readeck.lua` before the plugin is
  instantiated (what `mise run emulator-seed` does for the emulator);
- `H.open_filemanager()` / `H.open_reader(path)` use `FileManager:showFiles` and
  `ReaderUI:showReader`, which instantiate the plugin exactly as on a device
  (`fm.readeck`, `reader.readeck`);
- `H.tap_menu(ui, {"Readeck", "Settings", "Article actions", "..."})` opens the
  real touch menu and taps items found by their **visible text**
  (`{"^Pattern"}` matches dynamic labels); `H.set_menu_checkbox` toggles one;
- every `UIManager:show`/`close` is recorded. `H.wait_dialog(pattern)` pumps
  until a matching dialog appears, `H.press("OK", dialog)` presses a button by
  label, `H.fill(dialog, text [, field])` types into an input dialog;
- `H.long_press_file(fm, path)` opens the file browser's long-press dialog
  (status buttons, Delete, ...);
- `H.highlight(reader, "some words", {note = ...})` finds the words with
  crengine, long-presses and drags across them on screen, and presses
  "Highlight" / "Add note" in the real popup. `{"from", "to"}` selects from the
  start of one phrase to the end of another - across paragraphs, and across
  inline elements, which crengine's search does not match over
  (`"Opening emphasis starts"` is not found, `{"Opening emphasis", "starts"}`
  is). Phrases past the current page are found too.

Scheduled work (`UIManager:scheduleIn`, `nextTick`, InfoMessage timeouts,
OAuth polling) runs deterministically: `H.pump(horizon)` runs due tasks and
fast-forwards virtual time up to `horizon` seconds; `H.pump_until(pred)` and
`H.wait_dialog` do so until a condition holds, with a real-time timeout.
Server state is checked with `H.api` (`lib/readeck_api.lua`), which shares no
code with the plugin, and `H.wait_for(pred)` polls it.

Plugin event handlers run in KOReader's sandbox, which logs an error and
carries on, so a crash would be invisible. The harness traps those logs and
fails the test that caused them.

## Adding a test

Create `e2e/tests/<area>_test.lua` (or add to an existing file):

```lua
local H = ...

H.test("finished article is archived on sync", function()
    local id = H.seed_page("lighthouse.html")      -- bookmark a fixture page, wait until loaded
    H.configure_plugin()                           -- server, token, download dir of this test
    local fm = H.open_filemanager()
    H.match(H.sync_via_menu(fm), "Downloaded: 1")  -- taps the menu, returns the summary text
    local path = H.local_article_by_id(id).path
    H.press("Finished", H.long_press_file(fm, path))
    H.match(H.sync_via_menu(fm), "Archived in Readeck: 1")
    H.eq(H.api:get_bookmark(id).is_archived, true)
end)
```

Options (third argument): `xfail = "reason"` for a known plugin bug (must fail;
reported XFAIL, not fatal; if it starts passing it is reported XPASS and fails
the run, so the marker gets removed), `skip = "reason"`,
`server_version = "0.22.1"` to run against a specific Readeck release,
`versions = { ["0.21.6"] = "reason" }` to skip on some versions,
`allow_handler_errors = true`.

Other helpers worth knowing: `H.seed(n, {labels=, title_prefix=})` (generated
articles with distinct titles), `H.api:create_bookmark(H.fixture_url("x.html?delay=4"))`
(a bookmark that stays loading for 4 s), `H.local_articles()`,
`H.epub_title(path)` (validates the EPUB container),
`H.edit_epub_chapter(path, fn)` (rewrite the downloaded article's XHTML, e.g.
to make the local copy differ from the server's), `H.doc_setting(path, key)`,
`H.custom_keywords(path)`, `H.set_book_status(path, status)`,
`H.server_at_least("0.22.0")`, `H.stop_server()`, `H.approve_device(code)`,
`H.screenshot("label")`, `H.log(...)`.

Keep tests independent (each gets its own server and download dir) and poll
with `H.wait_for` / `H.pump_until` instead of sleeping.

## Reading the artifacts

```
references/e2e-artifacts/latest -> <run id>/
  results.tsv                      status, version, file, test, seconds, message
  <version>/<file>.log             full KOReader + plugin log (plugin at debug level)
  <version>/<file>/<NN-test>/
      NN-<kind>-<text>.png         every dialog the plugin showed, as rendered,
                                   plus menus before a tap and named key states
      dialogs.txt                  the text of every dialog, in order
      log.txt                      harness log: menu taps, button presses, dialogs,
                                   assertion failures with traceback
```

A failing test also saves `NN-failure.png` of the screen at the moment of
failure. The PNGs are what the device would show at 600x800 (the emulator
default), so dialog wording and layout can be reviewed without the emulator -
by a person or by an agent that can read images.

## CI (Linux)

Verified in `debian:trixie-slim` (arm64) with the KOReader **release tarball**
`koreader-linux-arm64-v2026.07.1.tar.xz`; the x86_64 tarball has the same
layout. The tarball bundles its libraries (SDL3 included) and fonts, and the
dummy framebuffer needs no display.

```bash
apt-get install -y python3 ca-certificates   # nothing else is needed
tar xf koreader-linux-x86_64-vYYYY.MM.tar.xz
KOREADER_BUILD_DIR=$PWD/lib/koreader e2e/run.sh
```

- `KOREADER_BUILD_DIR` must point at `lib/koreader` inside the extracted
  tarball (the directory with `luajit` and `setupkoenv.lua`).
- Readeck release binaries are downloaded from codeberg.org on first use into
  `references/readeck-bin/` (named per OS/arch); cache that directory.
- Publish `references/e2e-artifacts/` as the job artifact.

## Known limitations

- Highlights are drawn with the KOReader highlight popup, but colour changes
  and note edits after creation set the annotation fields directly (what the
  "Change color" / "Edit note" dialogs store) rather than going through those
  dialogs.
- Readeck leaves bookmarks that are still loading out of `type=article`
  listings, so the plugin's "Still processing on Readeck: N" summary line is
  never reached against a real server; the readiness test asserts the
  user-visible outcome (no failure, downloaded next time) instead.
- The Readeck `-created` sort has one-second resolution; tests that depend on
  order sleep across a second boundary or ask the server for its order.
- One Readeck at a time: files and tests run sequentially.
