---
name: readeck-plugin-dev
description: The development feedback loop for readeck.koplugin (KOReader plugin syncing articles and highlights with Readeck) - which check to run for which change, the headless e2e suite against a disposable local Readeck, running Readeck locally (release binary or a build of ../readeck), the live probes against the user's real server and their safety rules, and the conventions every change must meet. Use before changing anything in this repo, when verifying a change, adding a test, or when asked whether the plugin works.
---

# readeck.koplugin development loop

Read `work.md` first: it is the fork's log (architecture, what was fixed and why,
what is still open). This skill is the *how*; `work.md` is the *what and why*.

## Safety rule (read first)

The shell has `READECK_URL` / `READECK_TOKEN` set to the user's **production**
Readeck. Nothing in the normal loop uses them:

- `mise run e2e`, `mise run e2e-server` and `tools/kodrive` unset them and only
  ever talk to a disposable server on `127.0.0.1` they started themselves.
- For ad-hoc `curl`, always `eval "$(python3 e2e/readeck_local.py env)"` of a
  local server first and check the URL is `127.0.0.1` before you send anything.
  `source <(...)` can fail silently and leave the production values in place.
- `mise run emulator-live-probe` is read-only against production and is fine to
  run when you need ground truth from the real server.
- `mise run emulator-live-probe-write` **writes to production**. Never run it
  unless the user explicitly asks for it in this conversation.

## The ladder: cheapest first

| Command | Time | Proves | Run when |
| --- | --- | --- | --- |
| `mise run check` | ~2 s | luacheck + stylua + busted (unit, pure logic, i18n coverage) | every change; the commit gate |
| `mise run e2e` | ~1 min | the plugin used through its menus/dialogs in a real headless KOReader against a real local Readeck; screenshots of every dialog | any change to sync, net, auth, annotations, UI |
| `READECK_VERSIONS="0.21.6 0.22.1 0.23.4" mise run e2e` | ~3 min | same, per server version (feature gates in `readeck/core/features.lua`) | changes near version gating or payloads; CI runs this |
| `E2E_REALWORLD=1 mise run e2e -- realworld` | ~1 min | highlight positions on real web pages (Wikipedia en/zh/ja, blogs, code), import and re-export, checked against Readeck's own resolution; needs the internet, not in CI | changes to `annotations/` (position map, xhtml, epub source) |
| `tools/kodrive …` (skill `koreader-manual-testing`) | minutes | the real emulator GUI, by eye | layout/UX questions, reproducing a UI bug, final visual check |
| `mise run emulator-smoke` / `emulator-network-smoke` | ~5 s | plugin loads in KOReader; client vs the python mock | legacy smoke, cheap |
| `mise run emulator-live-probe` | ~10 s | read-only against the **real** server | confirming real-server behaviour/shapes |

Prerequisites (once per machine): `mise run setup` (busted/luacheck into
`references/luarocks`, links `references/koreader`), `mise run emulator-build`
(slow; only needed if `references/koreader/koreader-emulator-*/koreader/luajit`
is missing). Readeck binaries download on first use into `references/readeck-bin/`.

## Headless e2e suite (`e2e/`)

Full manual: `e2e/README.md`. Essentials:

```bash
mise run e2e                          # everything, Readeck 0.23.4
mise run e2e -- highlights            # files whose name contains "highlights"
mise run e2e -- -k "bad token"        # tests whose name contains "bad token"
KOREADER_BUILD_DIR=/path mise run e2e # another KOReader (e.g. extracted release tarball: <dir>/lib/koreader)
```

- One KOReader process per test file; a fresh Readeck (new data dir, user,
  token, ~0.4 s) before **every test**.
- Tests drive the UI by visible text: `H.tap_menu(fm, {"Readeck", "Settings", …})`,
  `H.wait_dialog(pattern)`, `H.press("OK")`, `H.long_press_file`, `H.highlight(reader, "words")`,
  and assert both sides: local files/sidecars and the server via `H.api`
  (independent client, `e2e/lib/readeck_api.lua`).
- Results: `references/e2e-artifacts/latest/results.tsv`; per test a folder with
  `NN-<dialog>.png` screenshots, `dialogs.txt` (every dialog's text in order) and
  `log.txt`; per file `<version>/<file>.log` (full KOReader log, plugin at debug).
  **Look at the PNGs** (the `read` tool shows them) when a dialog's wording or
  layout matters.
- `H.xfail("reason", fn)` marks a known bug: it must fail; if it starts passing
  the run fails with XPASS so the marker gets removed.
- Fixtures: `e2e/fixtures/site/*.html` static articles, `e2e/fixtures/server.py`
  also serves generated `/gen/<slug>.html` pages and `?delay=N` slow pages.

### Adding a test for a bug

1. Reproduce it as an e2e test (or a busted spec if it is pure logic) and watch it fail.
2. Fix it in `readeck.koplugin/`; add a unit test for the pure part.
3. Break the fix on purpose and confirm the test fails, then restore.
4. `mise run check && mise run e2e`.

## Local Readeck by hand

```bash
mise run e2e-server                  # :18900 (+fixtures :18901), 3 bookmarks, prints env
eval "$(python3 e2e/readeck_local.py env)"
python3 e2e/readeck_local.py seed --count 5 --labels koreader
curl -s -H "Authorization: Bearer $READECK_TOKEN" "$READECK_URL/api/bookmarks" | jq '.[].title'
mise run e2e-server-stop
```

User `e2e` / `e2e-password` (web UI at the URL). Readeck may bookmark
`127.0.0.1` because the config empties `extractor.denied_ips`; bookmark the
fixture site at `$READECK_FIXTURE_URL/<page>.html`.

**Unreleased Readeck / reading the server code**: `../readeck` is the Readeck
source (Go). It is the ground truth for API behaviour (routes and annotation
selector resolution under `internal/bookmarks/`, OAuth under
`internal/auth/oauth2/`). To run it: `mise run readeck-build-local` (runs
`make setup all` there; needs Go + Node), then
`python3 e2e/readeck_local.py start --bin ../readeck/dist/readeck` or
`READECK_BIN=../readeck/dist/readeck mise run e2e`. Its version string looks like
`0.23.4-1-g9dc99711`.

## Where things are

| Path | What |
| --- | --- |
| `readeck.koplugin/main.lua` | entry; installs ~14 mixins into one `Readeck` class (see work.md) |
| `readeck.koplugin/readeck/net/` | HTTP client, `Api` seam, error shapes |
| `readeck.koplugin/readeck/sync/` | article sync, downloads, local actions, remote presence |
| `readeck.koplugin/readeck/annotations/` | highlight export/import, selector mapping |
| `readeck.koplugin/readeck/ui/` | menus, settings dialogs, status messages |
| `spec/` | busted unit specs (+ python mock server, legacy probes) |
| `e2e/` | headless e2e suite + `readeck_local.py` |
| `tools/kodrive`, `tools/agentdriver.koplugin/` | emulator driver (dev only, never shipped) |
| `tools/ci-logs` | Forgejo CI runs and logs (skill `forgejo-ci`) |
| `references/` | gitignored: KOReader checkout, luarocks, readeck binaries, artifacts |

## Conventions

- `mise run check` green before every commit; `mise run e2e` green for anything
  touching network, sync, annotations or UI. CI (`.forgejo/workflows/ci.yml`)
  runs both, e2e across three Readeck versions.
- New user-visible strings go through `L(...)` and need a `zh_cn` entry in
  `readeck/i18n/zh_cn.lua` (`spec/i18n_spec.lua` enforces it).
- Never commit tokens. Never commit unless the user asks.
- Record notable findings/fixes in `work.md` (keep "What still has to be done" current).
- Upstream is `origin` (iceyear/readeck.koplugin, GitHub), `fork` is
  viktomas' GitHub fork, `forgejo` is `ssh://fg/tomas/readeck.koplugin.git`
  (CI runs there).
