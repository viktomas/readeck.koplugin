# Fork work log

Working notes for the `viktomas/readeck.koplugin` fork. Everything below sits on top
of upstream `iceyear/readeck.koplugin` and none of it has been offered upstream yet.

State at the time of writing: 230 busted tests, `mise run check` green, 58 e2e
scenarios green against real Readeck **0.21.6, 0.22.1 and 0.23.4** servers (no XFAIL
left), plus an opt-in real-web-page suite (`E2E_REALWORLD=1`, 12 scenarios over 6
sites, green on all three versions). 0.23.4 is the newest Readeck release and what the
user's server runs.

## How to run things

```bash
mise run setup          # busted + luacheck into references/luarocks, link a KOReader checkout
mise run check          # luacheck + stylua --check + busted  <- the gate for every commit
mise run emulator-build # build the KOReader emulator (slow, needs the Homebrew deps)
```

Verification ladder, cheapest first. Each rung catches things the one below cannot:

| Task | What it proves |
| --- | --- |
| `mise run check` | Unit tests, lint, formatting. Pure logic only. |
| `mise run emulator-smoke` | The plugin loads and builds its menus in a real KOReader runtime. |
| `mise run emulator-network-smoke` | The HTTP client works against `spec/mock_readeck_server.py`, for two server versions. |
| `mise run e2e` | The plugin as a user drives it (menus, dialogs, reader, highlights) against a disposable **local real** Readeck. See `e2e/README.md`. `READECK_VERSIONS="0.21.6 0.22.1 0.23.4"` for the version matrix CI runs. |
| `tools/kodrive` / `mise run emulator-drive` | The real emulator GUI, driven by an agent: screenshots, widget tree, taps, text selection. See `.agents/skills/koreader-manual-testing/SKILL.md`. |
| `mise run emulator-live-probe` | Read-only against a **real** server. |
| `mise run emulator-live-probe-write-mock-smoke` | Rehearses the write probe offline. |
| `mise run emulator-live-probe-write` | **Writes** to a real server. See the safety note below. |
| `mise run emulator-seed` | Writes the emulator's settings so you need not type a token into a touch UI. |
| `mise run emulator-run` | Starts the emulator with the plugin symlinked in. |

```bash
READECK_URL=http://n:8112 READECK_TOKEN=<token> mise run emulator-seed
mise run emulator-run
```

The agent-facing versions of all this are the project skills in `.agents/skills/`
(`readeck-plugin-dev`, `koreader-manual-testing`, `forgejo-ci`). CI runs `check` and
the e2e matrix on every push to `forgejo` (http://n:3000/tomas/readeck.koplugin,
`.forgejo/workflows/ci.yml`); `tools/ci-logs` shows runs and logs.

### The write probe's safety property

`emulator-live-probe-write` creates a bookmark, exports and updates a highlight on it,
and deletes it again. It only ever touches data it created **in that run**, and this is
enforced in code rather than by convention: `getApi()` is replaced with a proxy whose
write methods assert the target id is the one id the run created, so the guarantee
holds for any plugin path that reaches the API, not just the calls the probe makes
directly. `create_bookmark` may fire once. The sequence runs under `pcall`, so the
bookmark is deleted even when an assertion fails partway, and a failed cleanup prints
the leaked id loudly.

It still writes to somebody's real account. Rehearse against the mock first, and do not
point it at an account without the owner's say-so.

## What was done

### Development environment

There was no way to run anything locally. Added a mise-driven setup: a project-local
LuaRocks tree, the task ladder above, a mock Readeck server, and probes that run inside
a real KOReader runtime.

`emulator-run` never actually worked on macOS: `kodev` parses its arguments with
`getopt(1)`, and the BSD getopt macOS ships makes it bail out with "unsupported getopt
version" before doing anything. It needs the Homebrew GNU tools first on `PATH`, the
same way `emulator-build` already did.

### The HTTP layer

Five commits, in this order, each one making the next possible:

1. **`callAPI` takes an options table.** It had seven positional arguments in which
   `headers`, `body` and `filepath` all used `""` to mean "absent", so every JSON call
   site hand-rolled the same four headers just to reach the later arguments. Accepting
   a Lua table as the body moved encoding into the client and deleted 24 lines of
   duplicated boilerplate across six call sites. It also fixed a latent bug: the old
   `body ~= ""` guard made an empty request body impossible to send, because the
   sentinel for "absent" and the value for "empty" were the same.
2. **Dialogs moved out of the HTTP client.** `callAPI` decided what the user saw, via
   three `UIManager:show` calls gated on a `quiet` argument that existed only to
   suppress them. The mapping from error to message now lives in
   `readeck/ui/status_messages.lua`, and `quiet` disappeared with the dialogs.
3. **One error shape.** The two transports each returned a different stringly-typed
   triple, with the HTTP code sometimes present and sometimes not; `callOAuthFormAPI`
   returned it as a *third* value on success. Both now return `value, err`, with `err`
   a `{ kind, code, status }` table from the new pure `readeck/net/errors.lua`.
4. **Everything routes through the `Api` seam.** `Api.new(transport)` had a spec but not
   one production caller. This also fixed a bug that was dormant only because nothing
   used it: `Api:request` defaulted `headers` to `{}`, which under `callAPI`'s contract
   means *send no Authorization header* — every authenticated call through `Api` would
   have gone out unauthenticated, and the spec asserted the bug.
5. **Tests for what the refactor had just reshaped.** The 401/403 refresh-and-retry was
   the riskiest logic in the plugin and had no test at all — get the retry guard wrong
   and a server that always answers 401 becomes an infinite request loop.

### Bugs fixed

- **Unconverted articles were reported as download failures.** Readeck converts an
  article asynchronously after a bookmark is created, and `article.epub` 404s until it
  finishes. The plugin read `has_article`, `loaded` and `state` *nowhere*, so it fired
  one GET and reported the 404 as a failure. Add a URL, sync, and the article you just
  saved is "failed" purely because the server was still working on it. Readiness is now
  classified in one pure module; a bookmark missing all three fields counts as ready, so
  nothing regresses against a server that does not report them.

  The subtle part is in the fix, not the bug: the map used for the "remove local files
  missing from Readeck" cleanup is captured *before* the readiness filter. Otherwise a
  still-loading article looks deleted from Readeck and its local file is removed — the
  obvious implementation would have caused data loss.

- **Token expiry trusted a clock e-readers lose.** `token_expiry` is an absolute
  wall-clock timestamp persisted to disk, and a flat battery resets the clock. A
  monotonic clock cannot help, because the value has to survive a reboot; instead the
  plugin now records when the token was stored, and a `now` behind that proves the clock
  moved and the expiry is meaningless. Settings written before this keep the old
  behaviour. The 401 retry remains the real backstop.

- **Dead branch in `getBearerToken`** — the oauth path ran
  `if authorize_with_oauth() then return false end return false`, identical to the
  fallthrough two lines below.

- **`name` in `_meta.lua`** was ignored by KOReader, which derives the name from the
  directory, and logged a deprecation warning on every startup.

- **Every failed GET fetched an HTML error page instead of a reason.** Readeck
  content-negotiates its errors, and the plugin sent no `Accept` header on requests
  without a JSON body — only POST/PATCH got one, as a side effect of `callAPI` setting
  it when it encodes a table. So a failed GET came back as 5.5 KB of HTML where
  `Accept: application/json` gets `{"status":404,"message":"Not Found"}`. Found by
  pointing the new error-reporting check at a real server: the unit tests all used the
  JSON shape `curl` sees by default, so no test could have caught it. The default
  headers now ask for `application/json, */*`; the `*/*` keeps EPUB downloads working,
  which the live probe verifies.

- **A rejected highlight was indistinguishable from a network drop.** `callAPI` read
  the error body only for a `Log:debug` line and then discarded it, so the user got
  `Failed: 1` whatever went wrong. `Errors` now carries an optional `message`, parsed
  from the body by a pure `Errors.message_from_body`, and it surfaces both in the API
  error dialog (`Server said: %1`, framing the server's untranslated wording) and next
  to the highlight failure count (`Failed: 1 (element "section/p[1]" not found)`).

  Three things made this less mechanical than it looks. Readeck answers in three
  different shapes — `{"message":...}` for a 400, a `fields.<name>.errors` form shape
  for a 422 with *no* top-level message, and plain text for 401/404 — so a parser that
  only read `.message` would have missed two of them. KOReader's `json.decode` is a
  callable *table*, so a `type(decode) == "function"` guard silently rejects the real
  decoder; the first live run showed raw JSON to the user because of it. And
  `add_highlight_counts` merges per-article counts with `tonumber(value) or 0`, which
  turns a text reason into `0` the moment two articles are merged — the reason had to
  be exempted from the summing rule.

### Testing against reality

Everything used to be tested against `spec/mock_readeck_server.py` — a fake written from
the same assumptions as the plugin, so it could only ever confirm them. Two probes now
run against a real server inside the real KOReader runtime.

The write probe **failed the first time it saw a real server**, which was the point.
Readeck resolves annotation selectors against the DOM of the article it stored and
answered `400 {"message": "element \"...\" not found"}`; the mock validated nothing and
accepted any selector. The mock now rejects selectors that do not resolve, using the
real server's error shape.

Confirmed against 0.23.4, by measurement rather than assumption:

- the slashless `section/p[1]` form that `clean_selector` produces **is** accepted
  server-side — the compatibility question the whole highlight design rests on;
- every field `highlights.lua` expects comes back with the type it expects; `note` and
  the `"none"` colour that the version gate enables both round-trip exactly;
- bookmark creation answers **202** with the id in a header, not the body;
- `article.epub` becomes fetchable *before* the readable article HTML, and the HTML
  answers **500, not 404**, while still being stored (probe-only concern: the plugin
  only fetches the EPUB, which is ready first);
- a fresh bookmark really does report `state=2 loaded=false has_article=false`;
- the version gate extrapolates correctly past the newest version the mock models;
- error bodies depend on `Accept`: with `application/json` a 404 is
  `{"status":404,"message":"Not Found"}` and a 422 is a `fields.<name>.errors` form
  shape with no top-level message; without it, an HTML page.

Unknown fields in an annotation POST are ignored by the server, so the KOReader-internal
keys that `export.lua` blindly includes are harmless — worth knowing, but it was my first
and wrong hypothesis for the 400.

### The end-to-end suite and what it found

`e2e/` runs the plugin headlessly inside real KOReader (emulator build or the
Linux release tarball) against a fresh local Readeck per test, driving it
through the touch menu, dialogs, file browser and a real crengine reader, and
checking both local files and the server. 44 scenarios, about a minute. It
retires most of item 1 below. Bugs it found, all against real servers:

- **Every highlight export failed.** Current crengine writes xpointers with an
  explicit index on every step (`/body[1]/DocFragment[1]/body[1]/main[1]/...`)
  and `clean_selector` only stripped the bare prefix, so Readeck answered
  `element "/body[1]/..." not found` for every highlight. The live write probe
  never saw it because it hand-built `section/p[1]` selectors. Fixed.
- **Text after inline markup was exported onto the wrong words.** KOReader's
  `p[2]/text()[2].39` counts from the second text node, Readeck's `p[2]` offset
  from the start of the paragraph; the plugin sent 39 as-is (and a unit test
  asserted it). Fixed by the position map below.
- **"Remove local files missing from Readeck" deleted articles that still
  exist**: anything outside the fetched batch (`articles_per_sync`), and
  bookmarks still loading, which Readeck leaves out of `type=article`
  listings - so the readiness fix above never protected them. Candidates are
  now confirmed per bookmark with the server (404, archived or pending
  deletion) before a file is removed; `readeck/sync/remote_presence.lua`.
- **"Tags to add to new articles" broke adding any article, "Send review as
  tags" broke every sync**: `table.insert(tags, tag:gsub(...))` passed gsub's
  match count as a position. The error was swallowed by KOReader's handler
  sandbox, so the user saw nothing. `readeck/core/tags.lua`.
- **A wrong API token read as "Requesting article list failed."** The retried
  401 came back as a generic HTTP error. It is now an auth error, and the
  list failure names the cause (auth, unreachable server, server's reason).
- **Notes were stripped for Readeck 0.22.0/0.22.1.** Measured with release
  binaries: notes arrived in 0.22.0 (0.21.6 drops them), the gate said 0.22.2.

- **A finished article deleted on the server failed its completion action on
  every sync, with no reason shown.** `removeArticle` guards the archive/delete
  step with a highlight sync so highlights are not lost, and that guard's
  `list_annotations` call 404s once the bookmark is gone - previously reported
  as a bare, permanent "Completion action failed: 1". A 404/410 on a
  bookmark-scoped request means the goal ("this bookmark is
  archived/deleted") is already met, not that the request failed:
  `Errors.is_not_found` names that check, `syncHighlightsForArticle` now
  returns it as `bookmark_missing` instead of an error, and `removeArticle`
  (both at the guard and, for the race where the bookmark disappears between
  the guard and the archive/delete call itself) finishes the local side and
  counts it as done rather than retrying forever. e2e:
  `e2e/tests/errors_test.lua`, "finished article deleted on the server".
- **The full-sync summary dropped the highlight failure reason.** The
  per-article highlight summary already carried it (`error_message` /
  `import_error_message`); `finishSyncWithArticles` only ever copied the bare
  counts into `highlights_failed`. `Export.highlight_failure_message` picks
  the one reason worth keeping, and the summary now reads
  `Highlight sync failed: 1 (element "..." not found)` like the per-article
  one already did.

Both were XFAIL in `e2e/tests/errors_test.lua`; both are normal passing tests
now.

### Highlight positions: a bidirectional KOReader <-> Readeck mapping

Imported Readeck annotations were stored with the Readeck selector as the
KOReader position (`section[1]/article[1]/p[4].4`), which crengine cannot
resolve, so they were never drawn; and exports were only right for the first
text node of an element. Both are fixed by
`readeck/annotations/position_map.lua`, which translates in both directions
from the downloaded EPUB alone, and is used by export, import, overlap/dedupe
and a one-time repair of highlights imported by earlier versions.

**What the two sides count** (read in `../readeck` and measured against real
servers and a real crengine, not assumed):

- Readeck (`pkg/annotate`, `getTextNodeBoundary`) evaluates the selector as an
  XPath relative to the `<body>` of the *stored article HTML*, and the offset
  counts **Unicode code points** (`[]rune`) over **all** descendant text nodes
  of that element, **raw**: `"paragraph\n   was wrapped"` is 25 characters.
  Its web reader uses the text node's parent element as the selector.
- crengine xpointers name one **text node** (`p[2]/text()[2].5`,
  `p[1]/em[1]/text()[1].3`), offsets are code points too (lChar32; verified
  with CJK and emoji), but **after parse-time whitespace handling**
  (`PreProcessXmlString`): runs of space/tab/CR/LF collapse to one space, and
  whitespace-only text nodes are dropped when they are the first child of a
  block or sit among block children (`ldomElementWriter::onText`, autoboxing),
  so they do not count in `text()[n]`. NBSP is kept. The format depends on the
  DOM version: current KOReader writes `/body[1]/DocFragment[1]/body[1]/...`
  with every index, older DOM versions the bare form; both are read.
- The EPUB (`internal/bookmarks/converter/epub.go`, template `x-epub.templ`,
  `epub/bookmark.jet.html` in 0.21) is one spine document per bookmark
  (`DocFragment[1]`): a header (`h1.title`, `p.desc`, `ul.info`) and then the
  stored article HTML copied verbatim into `<main class="content">` (class list
  in 0.21; a photo/video bookmark has a `main.photo` first, which is why the
  map looks for the class). **Since 0.22 the EPUB also contains the annotations
  that existed at export time**: each annotated run wrapped in an
  attribute-less `<mark>`, and a footnote link `<a epub:type="noteref">N</a>`
  after an annotation with a note (plus an `<aside>` list of notes after
  `main`). Readeck's DOM has neither, so with a naive mapping every EPUB
  downloaded after a highlight sync would shift positions (`p[2]/mark[1]`
  does not exist on the server, the noteref's "1" is not in its text). The map
  treats those marks as transparent and noteref text as absent.

**Design: compute the mapping in Lua from the EPUB's XHTML** (option (a)).
`readeck/annotations/epub_source.lua` reads `container.xml` -> OPF spine ->
the chapter holding `<main>` with `ffi/archiver` (or the open crengine
document's `getDocumentFileContent`), `readeck/annotations/xhtml.lua` builds
a tree (raw text, entities decoded), and the map indexes every text node
once with both its crengine identity (element indexes counting every sibling,
`text()[k]` among kept text nodes, a collapsed<->raw offset table) and its
Readeck identity (element indexes without marks/noterefs, position in the
article's raw text). A position is converted through that global raw offset.
Boundaries follow Readeck: a start at the end of a node moves to the next
node, an end stays at the end of the previous one. Why this rather than the
alternatives:

- (b) "pending until the book is open" would leave a full sync's imports
  invisible in the history/bookmark list until the book is opened, needs a new
  pending state in sidecars and a hook in `onReaderReady`, and crengine cannot
  do the arithmetic anyway: it has thrown the raw whitespace away, and Readeck
  offsets are raw. Some raw source is needed whatever happens.
- (c) opening a crengine document headlessly per article during sync is slow
  on e-readers, touches the crengine cache, and still has the raw-whitespace
  problem.
- The crengine-specific part of (a) is small (collapse rule + which
  whitespace-only nodes are dropped), and it is **verified against the real
  crengine**: during development every text node of the fixtures was
  compared (predicted xpointer valid, `+1` invalid, same text), and the e2e
  suite asserts every imported highlight with
  `document:getTextFromXPointers(pos0, pos1)`. When the book is open the
  plugin also checks each import with crengine before adding it, and uses
  crengine's text as the highlight text.

Imported highlights now get: xpointer `pos0`/`pos1`/`page`, `text`, `chapter`
(TOC title when open, the chapter `<title>` otherwise), colour and note, and
`datetime` in **local time** (Readeck's `created` is UTC; it used to be stored
as if it were local). An annotation that cannot be placed is not imported and
the summary says why (`Import failed: 1 (its text is not in the downloaded
article)`). Linked sync and edits already went by `readeck_annotation_id`, so
import -> edit in KOReader -> sync updates the same annotation (e2e-tested,
and by hand in the emulator: screenshots in
`references/manual-artifacts/highlight-import/`). Highlights imported by
earlier versions (position not starting with `/`) are repaired from the
server's annotation on the next sync. Overlap/dedupe compares ranges of the
article text, so `p[2]/em[1]` and `p[2]` selectors compare correctly.

Tests: `spec/position_map_spec.lua` runs on chapter files of real EPUBs
(`spec/fixtures/readeck_epub/`: plain, with marks, with noterefs, 0.21.6
template) and round-trips every crengine position of every fixture; each
rule was checked by breaking it. e2e: inline markup at start/middle/end,
wrapped lines, entities, `<br>`, blockquote, list, multibyte and emoji
(offsets asserted in characters), import drawn (open book and sidecar/full
sync), import -> edit -> same annotation updated, and a round trip export ->
import on a second device profile whose EPUB carries Readeck's marks and a
noteref.

Limits: an attribute-less `<mark>` that was in the original article is
indistinguishable from Readeck's and treated as transparent; tabs inside
`<pre>` (crengine expands them) are not modelled; if the article changed on
the server after the download, positions are computed against the local copy
(the server then rejects or mis-places them, and the reason is shown); the
whitespace-dropping rule uses HTML's default inline/block split, so CSS that
changes `display` could shift `text()[n]` in mixed block content. Without a
readable EPUB, export falls back to the old textual rewrite and import refuses.

### Readeck compatibility pass (read against `../readeck`, measured locally)

Each found with a failing e2e test first, against a real local Readeck:

- **Long titles could not be saved.** The title was cut to 230 bytes and
  ` [rd-id_<22 chars>].epub` (36 bytes) appended after it: 266 bytes, over the
  255 of ext4/APFS/vfat, so `io.open` failed with "File name too long" (about 77
  CJK characters is enough). The title is now budgeted against the whole name
  (`Defaults.MAX_FILENAME_BYTES = 240`).
- **The filter tag was a search string.** Readeck parses `labels=` with
  `internal/searchstring`: `to read` meant labels `to` AND `read`, a leading `-`
  excluded, `*` was a wildcard. `Api.label_filter` sends it as one quoted exact term.
- **Failed extraction read as "Still processing" forever.** Readeck does not use
  `state=1` for it: an empty page, a 404 or an unreachable host finish with
  `state=0, loaded=true, has_article=false` and `errors` set (`loaded` is
  `state != loading`, `has_article` is "the article file exists"). Now classified
  as extraction failed.
- **Notes were cut at 1024 bytes.** Readeck trims and caps at 1024 *runes*
  (`forms_annotations.go`, `MaxLen`); a 500-character CJK note lost two thirds and
  could be split mid-character. `normalize_note` now trims and counts characters.
- **OAuth users were logged out by a clock change.** Readeck's OAuth tokens have no
  `expires_in` and come without a refresh token; the plugin assumed 365 days, and any
  clock anomaly (the flat-battery case) or a year passing discarded the only
  credential and started a new device login. Without a refresh token the stored
  token is now used until the server answers 401 (which still re-authorizes; e2e
  covers both).
- **A dropped connection left a truncated EPUB** under the article's name, which
  every later sync skipped as "already downloaded" (the blocking path returned a
  network error without removing the file). All three downloaders now write
  `.readeck-<id>.part` (hidden, no ` [rd-id_` marker so nothing scans it as an
  article) and rename on success; `readeck/storage/partial_file.lua`. e2e uses
  `e2e/fixtures/truncating_proxy.py` to cut downloads in half.
- **Web-reader annotations on a new article arrived one sync late.** The highlight
  step runs before downloads, so it only saw articles already on the device; the
  sync now imports highlights for the articles it just downloaded.
- **Server URL and token as typed on an e-reader**: surrounding spaces and a pasted
  `/api` suffix are stripped (`Api.normalize_server_url`).
- `mise run e2e -- -k ...` reported every file without a matching test as CRASH.

Checked and fine: sort options match Readeck's `forms_bookmarks.go` list; bookmarks
pending deletion are skipped; the KOReader default download path is the blocking
client (`DUSE_TURBO_LIB = false`), which is what e2e exercises.

### Readeck upstream bugs (not reported yet)

**EPUB export drops the article when a note precedes an annotation through `a[n]`**
(0.22.0 - 0.23.4, `internal/bookmarks/converter/epub.go` + `pkg/annotate`). The EPUB
converter's annotation callback inserts `<a epub:type="noteref">N</a>` after a noted
annotation *while* `BookmarkAnnotations.AddToNode` is still applying the rest, so for
later annotations in the same element:

1. a selector through `a[n]` now counts the noteref: `index "11" is out of range`,
   `addBookmark` returns before `AddChapter`, and the already-streaming response is
   **HTTP 200 with a chapter-less EPUB** (server log: `server error`);
2. offsets count the noteref's digits, so later marks in that element are shifted by
   one character per earlier note (a footnote number can land inside another
   highlight).

Repro on a fresh server: bookmark `e2e/fixtures/site/markup.html`, annotate
`p[1]/em[1]`@8..`p[1]`@22 **with a note**, then `p[1]`@102..`p[1]/a[1]`@11; the
`article.epub` spine is now empty. Happened on 1 of 6 real pages in
`realworld_test` (danluu.com). Fix upstream: insert noterefs after all annotations
are applied, or resolve every annotation's boundaries before mutating the DOM.
The plugin now checks each download (`EpubSource.has_chapter`), discards a
chapter-less EPUB, says "Readeck sent an EPUB without the article, will retry" and
retries on later syncs instead of keeping a blank book that no sync would replace.
The web reader is not affected (no noterefs there).

## What still has to be done

### 1. Run a full interactive sync against a real server — the only untested surface left

The probes drive the API layer directly; nothing has ever exercised the plugin through
its own UI, which is where 14 mixins and 177 methods actually compose. This needs a
human at the emulator, so no probe can substitute for it:

```bash
READECK_URL=... READECK_TOKEN=... mise run emulator-seed && mise run emulator-run
```

Worth covering in one sitting: a list sync of 20+ bookmarks; add a URL and sync
immediately (the readiness fix under real timing); highlight an article including one
overlapping and one block-spanning selection; sync highlights back; archive one server-
side and re-sync; delete one locally and re-sync. The error messages added above are
what make the resulting failures legible, which is why they were done first.

### 2. `Trapper` instead of `wrapSinkWithUIRefresh`

`readeck/net/client.lua:16` wraps the download sink to call `UIManager:forceRePaint()`
about once a second. KOReader's own idiom for slow work is `Trapper` plus coroutine
yields — see `newsdownloader.koplugin/main.lua:202` — which would also make a long sync
**cancellable**, which matters on slow e-ink. The catch is that Trapper needs to run
inside a coroutine, so every entry point into sync has to be audited; this is a real
refactor, not a swap.

### 3. `callAPI` discards response headers — fixed for bookmark creation

`client.lua` used to read `resp_headers` only to log it. `callAPI` now returns them as a
third value (existing two-value callers are unaffected; Lua ignores the extra return),
and `Api:create_bookmark` uses `Api.bookmark_id_from_headers` (checked against `../readeck`:
`internal/bookmarks/... ` answers 202 with the id in `Bookmark-Id`, falling back to the
trailing segment of `Location`) to put the id onto its result even though the body is
empty. `addArticle`'s result can now carry the id; nothing yet uses it for "add an
article and sync it immediately" — that workflow is still open, but the id it needs is
no longer unreachable. Tests: `spec/api_spec.lua`.

### 4. The mixin-by-side-effect pattern

`main.lua` makes 14 `install(Readeck, deps)` calls, each writing methods into one shared
class: 177 `function Readeck:` definitions across one namespace, where a collision is
silent and no module's boundary is visible. The `Api` seam makes the request-layer
boundaries visible, which is what makes this tractable.

This is maintainability only, with no user-facing effect, which is why it keeps losing
to the items above. When it happens, do it as a pilot on one leaf module rather than a
14-module big bang — `auth/form.lua` is a good candidate: small, few dependencies, and
already covered by `spec/form_spec.lua`.

### 5. Smaller things

- Fixed: the reason carried into the *highlight* summary now also reaches the
  full-sync completion summary (was: `sync/articles.lua` folded `counts.error` and
  `counts.import_failed` into a bare `highlights_failed` number). See above.
- Checked and already fine: `export.lua`'s highlight create/update payload is not the
  raw KOReader annotation table — `Highlights.build_payload`/`finish_payload` builds a
  curated payload (`text`, `color`, `start_selector`, `start_offset`, `end_selector`,
  `end_offset`, `note`) that matches `BookmarkAnnotation` in `../readeck`'s
  `internal/bookmarks/annotations.go` field for field. The note in an earlier version of
  this file describing a blind pass-through predates the highlight-position rework
  above, which is what introduced this curated payload.
- Report the Readeck EPUB bug above upstream (Codeberg), with the repro.
- Readeck only sorts by the chosen key, without a tiebreaker; offset paging over ties
  (same site, same duration) relies on SQLite returning them in a stable order.
- Selectors are capped at 256 characters server-side; a very deeply nested
  paragraph would be rejected (the reason is shown).
- Imported highlights take crengine's text when the book is open, so a Readeck
  footnote number misplaced inside the range (bug 2 above) shows in the text.
- Photo and video bookmarks are never synced (`type=article`); Readeck does
  produce EPUBs for them.
- The mock still ignores every query filter (`is_archived`, `type`, `labels`, `sort`)
  and returns the whole store, so no test exercises filtering.
- The mock answers errors in the JSON shape only. The real server picks its shape from
  `Accept`, which is exactly the class of bug the mock cannot model.
- Nothing here has been offered upstream.

## Conventions

- `mise run check` must be green before every commit; the live probes are the gate for
  anything touching the network or annotation layers.
- New user-visible strings go through `L(...)` and need a `zh_cn` translation —
  `spec/i18n_spec.lua` enforces coverage.
- New tests are worth verifying by breaking the code they cover and confirming they
  fail. Most of the tests added here were checked that way.
- Never commit a token. The probes read credentials from `READECK_URL` /
  `READECK_TOKEN` or the emulator's seeded settings file, and keep them out of their
  output.
