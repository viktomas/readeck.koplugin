<div align="center">

# 📚 Readeck Plugin for KOReader

**A fork of [iceyear/readeck.koplugin](https://github.com/iceyear/readeck.koplugin)**

![GitHub License](https://img.shields.io/github/license/viktomas/readeck.koplugin)

English   |   [简体中文](README_ZH.md)

</div>

## 📚 Overview

Readeck Plugin for KOReader is a plugin that allows you to synchronize articles from a Readeck server directly to your KOReader-powered e-reader. Readeck is a simple yet powerful web application that lets you save web content you want to keep forever. This plugin brings that content to your E-ink screen for a focused, distraction-free reading experience.

## 🍴 About This Fork

This repository ([github.com/viktomas/readeck.koplugin](https://github.com/viktomas/readeck.koplugin)) is a fork of [iceyear/readeck.koplugin](https://github.com/iceyear/readeck.koplugin), the original plugin by [@iceyear](https://github.com/iceyear) and its contributors. The plugin and its features are their work.

The fork focuses on correctness against real Readeck servers: highlight positions that match between KOReader and Readeck, safer file cleanup and downloads, clearer error messages, and an end-to-end test suite that runs the plugin inside KOReader against real Readeck releases. None of these changes have been offered upstream yet.

For the original project, its issue tracker and its releases, go to [iceyear/readeck.koplugin](https://github.com/iceyear/readeck.koplugin). Report problems specific to this fork on the fork.

## 🌟 Features

* 🔄 **Sync & Download**: Download articles from your Readeck server to a dedicated folder on your KOReader device. Articles Readeck is still processing are skipped and picked up by a later sync; articles Readeck could not extract are reported separately from download failures.
* 🏷️ **Tag Filtering**: Only download articles with a specific label (matched exactly, spaces included), ignore articles with certain tags, and auto-add tags to newly created bookmarks.
* ↕️ **Sorting**: Sort server articles by added/published date, duration, site name, or title.
* 🗄️ **Completion Actions**: Optionally archive or delete finished/100%-read articles in Readeck, and remove local files only after the server action succeeds.
* 🧾 **History Cleanup**: Optionally remove finished/fully-read Readeck documents from KOReader history.
* 🌐 **Add to Readeck (with Queue)**: Add links from KOReader; if offline, links are stored in a queue and retried next time you’re online.
* 📝 **Review → Tags**: Write comma-separated tags in the **Review** field and send them back to Readeck as labels.
* ⭐ **Star / Like Sync**: Optionally mark entries as liked on Readeck based on your KOReader star rating threshold, and/or label entries with their star rating (e.g. `3-star`).
* 📊 **Reading Progress Sync (beta)**: Sync KOReader reading progress below 100% back to Readeck, and apply newer incomplete Readeck progress to local sidecars. Disabled by default.
* 🖍️ **Highlight Sync**: Merge Readeck annotations into KOReader highlights and export local KOReader highlights, notes, and mapped colors back to Readeck. Positions are translated between KOReader and Readeck using the downloaded EPUB, so highlights land on the same words on both sides, including text after inline markup. The plugin reads `/api/info` and sends notes and the transparent color only to Readeck 0.22 or newer.
* 🕒 **Metadata Sync**: Set downloaded file timestamps from Readeck metadata and add estimated reading time as a KOReader keyword.
* 🔁 **Periodic Sync (beta)**: Optionally let KOReader schedule recurring Readeck syncs while the app is running.
* ⚡ **Cooperative Downloads**: Download articles through a bounded async queue. Concurrency is configurable from 1 to 3 so slower devices can stay responsive.
* 🌍 **Plugin i18n Fallbacks**: Reuse KOReader gettext when available, then fall back to plugin-provided English/Chinese strings.

## 📥 Installation

1. Clone or download this repository.
2. Locate your KOReader plugins directory (usually `koreader/plugins/`).
3. Copy the `readeck.koplugin` folder into the plugins directory.
4. Restart KOReader completely (use **Exit** from the menu, then relaunch).

> **Compatibility warning:** Settings from early experimental builds are not fully compatible. If you see odd sync or authentication behavior after upgrading from one, clear the `readeck.lua` plugin settings and configure the plugin again before filing a bug.

## ⚙️ Configuration

To use this plugin, you need:

1. A running Readeck server (learn more at [readeck.org](https://readeck.org)). The plugin is tested against Readeck 0.21.6, 0.22.1 and 0.23.4; highlight notes need 0.22 or newer.
2. A dedicated download folder configured on your KOReader

### Initial Setup

1. Go to **Main Menu > Readeck > Settings > Configure Readeck server**
2. Enter the server URL (surrounding spaces and a trailing `/api` are stripped)
3. Choose one authentication method:

   * **OAuth (Device Flow)** (recommended for convenience; used when the server advertises OAuth support), or
   * **API Token**
4. Set a dedicated **Download folder**
5. (Optional) Configure:

   * **Only download articles with tag**
   * **Sort articles by**
   * **Tags to ignore**
   * **Tags to add to new articles**

## 🛠️ Usage Instructions

### Downloading New Articles

1. Go to **Main Menu > Readeck > Synchronize articles with server**
2. Articles will be downloaded according to your tag filter / ignore settings

> Tip: If **Process completion actions when syncing** is enabled, archiving/deleting in Readeck can be handled automatically during sync.

### Marking Articles as Finished

When you finish reading an article:

1. Mark it as finished (e.g., set status to **complete**) and/or read it to **100%**
2. Go to **Main Menu > Readeck > Process finished/read articles**
3. The plugin will apply your configured completion action, sync highlights first, and remove local files only after Readeck confirms the action. An article that has already been deleted on the server counts as done and its local file is removed.

### Adding Articles

When browsing the web:

1. Open a link in KOReader's browser
2. Select **Add to Readeck** from the external link menu

If you are offline:

1. The link will be added to a **download queue**
2. It will be retried automatically the next time you’re online (during sync)

### Syncing Highlights

1. Open a downloaded Readeck article in KOReader
2. Go to **Main Menu > Readeck > Sync current article highlights**
3. Readeck annotations are imported into KOReader highlights, local KOReader highlights with supported notes/colors are uploaded to Readeck, and already linked annotations are incrementally updated both ways.

A full sync also imports the Readeck annotations of articles it has just downloaded. An annotation that cannot be placed in the downloaded article is not imported, and the sync summary gives the reason; the same goes for highlights the server rejects. Readeck stores notes of up to 1024 characters.

For linked highlights, **Highlight update strategy** defaults to merging local and remote note/color changes using the last synced state. You can also force **Readeck overwrites KOReader** or **KOReader overwrites Readeck**.

By default, remote-deleted highlights are preserved locally and may be restored to Readeck on the next sync. Set **Remote-deleted highlights** to **Respect remote deletions** if you prefer deleted Readeck annotations to stay local-only and not be re-uploaded.

### Syncing Reading Progress

During sync, the plugin can send KOReader's local reading progress below 100% back to Readeck without archiving the article. It also applies newer incomplete Readeck `read_progress` values to KOReader sidecars when articles are downloaded or skipped because they already exist locally. Articles that are being processed by completion actions are handled by the archive/delete flow instead.

## ⚠️ Notes

* The download directory should be exclusively used by the Readeck plugin; existing files in it may be deleted
* Username/password login is not supported; use OAuth or an API token
* An OAuth token is used until the server rejects it, then the plugin starts a new device login
* Only article bookmarks are synced; photo and video bookmarks are not downloaded
* Downloads are written to a hidden `.part` file and renamed when complete, so an interrupted download is retried on the next sync. An EPUB that Readeck sends without the article content is discarded and retried too
* The **Send review as tags** option allows you to add tags while reading

## 🔧 Advanced Settings

### Readeck Server / Authentication

* **Configure Readeck server > Server URL**: Set the base Readeck URL without `/api`
* **Configure Readeck server > Readeck server features**: Auto-detect from `/api/info`, force modern Readeck 0.22+ annotation fields (notes, transparent color), or force legacy compatibility
* **Authentication > Authorize with OAuth**: Use device-flow OAuth login (with optional QR code)
* **Authentication > Reset access token**: Clear token so the plugin re-authenticates
* **Authentication > Clear all cached tokens**: Remove cached OAuth/token data
* **Authentication > API token**: Configure a Readeck API token

### Readeck Client

* **Download limits**: Set the number of articles processed per sync and the download concurrency
* **Experimental subprocess downloads**: Try parallel downloads without KOReader's async HTTP looper. If this backend fails, the plugin disables it for the current run and retries with the blocking downloader.
* **Network timeouts**: Tune network timeouts for slow connections or large downloads
* **Language**: Follow KOReader's language, or force the plugin UI to English / Simplified Chinese
* **Log level**: Filter plugin logs (`Info` by default, `Debug` for troubleshooting)

### Article Selection

* **Download folder**: Choose the KOReader folder used for downloaded articles
* **Only download articles with tag**: Only download entries with a specific label
* **Sort articles by**: Choose the server-side ordering (added/published/duration/site/title)
* **Tags to ignore**: Skip entries containing any of the specified tags
* **Tags to add to new articles**: Auto-label newly added bookmarks (including links added from KOReader)

### Article Actions

* **Process finished articles in Readeck**: Process entries marked as finished
* **Process 100% read articles in Readeck**: Process entries that reached 100% progress
* **Archive completion actions instead of deleting**: Archive entries instead of permanently deleting them
* **Process completion actions when syncing**: Run completion actions automatically during sync
* **Sync reading progress to Readeck (beta)**: Update Readeck's reading progress below 100% for local articles that remain on the device, and accept newer incomplete Readeck progress locally
* **Remove local files missing from Readeck**: Remove a local article once the server confirms its bookmark is deleted, archived, or pending deletion. Articles the server cannot be asked about (network or auth errors) are kept
* **Remove finished articles from history**: Clean up KOReader history for completed entries
* **Remove 100% read articles from history**: Clean up history for fully read entries

### Highlights / Periodic Sync

* **Sync highlights before article sync**: Export/import highlights before retrieving articles
* **Sync highlights when closing a document**: Sync the current Readeck article's highlights when closing it
* **Periodic sync (beta)**: Enable a KOReader timer and choose the interval in minutes
* **Highlight update strategy**: Merge linked note/color edits, or force Readeck/KOReader to overwrite the other side
* **Remote-deleted highlights**: Choose whether deleted Readeck annotations should be restored from KOReader or kept local-only

Sync is paced for KOReader devices: article downloads can run with limited concurrency when a supported async backend is available, highlight sync before article sync is split across local files so progress can render, and the article-list request only uses KOReader's async HTTP client when its async looper is already active. Unsupported or failing backends safely fall back to the blocking request path. The sync progress popup can be dismissed, moved with KOReader's standard movable dialog gestures, and reopened from the Readeck menu while sync is still running.

### Ratings And Review Tags

* **“Like” entries in Readeck**: Mark entries as liked based on your KOReader star rating threshold
* **Label entries in Readeck with their star rating**: Add labels like `1-star` … `5-star`
* **Send review as tags**: Treat comma-separated content in the KOReader **Review** field as tags and send them to Readeck

## Development

The development tasks are defined in `mise.toml` (`mise tasks` lists them all):

* `mise run setup`: install Busted and Luacheck into a project-local LuaRocks tree and link a KOReader checkout at `references/koreader`
* `mise run check`: Luacheck, Stylua format check and the Busted spec suite
* `mise run emulator-build`: build the KOReader emulator
* `mise run emulator-smoke`: load the plugin and build its menus in a real KOReader runtime
* `mise run emulator-network-smoke`: drive the HTTP client against the mock Readeck server (`spec/mock_readeck_server.py`)
* `mise run e2e`: the headless end-to-end suite. It runs the plugin inside real KOReader against a disposable local Readeck server, drives it through menus, dialogs and the reader, and checks both the local files and the server. Set `READECK_VERSIONS="0.21.6 0.22.1 0.23.4"` to run it against several Readeck releases. See [`e2e/README.md`](e2e/README.md)
* `mise run emulator-seed` / `mise run emulator-run`: write the emulator's plugin settings from `READECK_URL` / `READECK_TOKEN` and start the emulator with the plugin symlinked in

The `Makefile` provides `make deps`, `make check`, `make koreader-build`, `make koreader-smoke`, `make koreader-runtime-smoke` and `make koreader-network-smoke`, which the GitHub Actions workflow uses.

The plugin does not depend on LuaRocks at runtime; it uses KOReader's bundled Lua modules and native libraries so it remains portable across Linux, Android, and e-reader builds.

CI:

* `.github/workflows/ci.yml` (GitHub Actions): lint, unit tests, and the KOReader runtime and network smoke tests on a KOReader emulator build
* `.forgejo/workflows/ci.yml` (Forgejo): `mise run check` and the end-to-end suite against several Readeck versions

## 🔍 Troubleshooting

* If downloads fail, double-check your server URL and authentication settings
* Ensure KOReader has active network access
* Verify that the download directory exists and is writable
* For advanced debugging, check `crash.log` or enable logcat on Android

## 🙏 Credits

* [iceyear/readeck.koplugin](https://github.com/iceyear/readeck.koplugin) by [@iceyear](https://github.com/iceyear) and contributors: the original plugin this repository is forked from
* Based on [wallabag2.koplugin by clach04](https://github.com/clach04/wallabag2.koplugin)
* [KOReader](https://github.com/koreader/koreader) — The best FOSS e-ink book reader
* [Readeck](https://readeck.org) — Making web content readable again

## 📄 License

This plugin is open source under the [MIT License](LICENSE), copyright Ice Year. Fork: [github.com/viktomas/readeck.koplugin](https://github.com/viktomas/readeck.koplugin). Original: [github.com/iceyear/readeck.koplugin](https://github.com/iceyear/readeck.koplugin).
