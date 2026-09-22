# Fork work log

Working notes for the `viktomas/readeck.koplugin` fork. Everything below sits on top
of upstream `iceyear/readeck.koplugin` and none of it has been offered upstream yet.

State at the time of writing: 168 busted tests, `mise run check` green, verified
against a real Readeck **0.23.4** server.

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
| `mise run emulator-live-probe` | Read-only against a **real** server. |
| `mise run emulator-live-probe-write-mock-smoke` | Rehearses the write probe offline. |
| `mise run emulator-live-probe-write` | **Writes** to a real server. See the safety note below. |
| `mise run emulator-seed` | Writes the emulator's settings so you need not type a token into a touch UI. |
| `mise run emulator-run` | Starts the emulator with the plugin symlinked in. |

```bash
READECK_URL=http://n:8112 READECK_TOKEN=<token> mise run emulator-seed
mise run emulator-run
```

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

### 3. `callAPI` discards response headers

`client.lua` reads `resp_headers` only to log it. Bookmark creation returns 202 with the
new id in a `Bookmark-Id`/`Location` header, so that id is currently unreachable. No bug
today — `addArticle`'s only consumer checks truthiness — but it blocks "add an article
and then immediately sync it".

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

- The reason carried into the *highlight* summary does not reach the full-sync
  completion summary, which still folds `counts.error` and `counts.import_failed` into
  a single `highlights_failed` number (`sync/articles.lua:371`).

- `export.lua:321` POSTs the entire KOReader annotation table, internal bookkeeping
  fields and all. Harmless — the server ignores unknown fields — but it means the
  outgoing payload is whatever KOReader happens to put in a sidecar.
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
