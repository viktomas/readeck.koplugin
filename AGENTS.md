# Agent notes for readeck.koplugin (fork)

- Start with `work.md` (fork log: architecture, fixes, open work).
- Skills in `.agents/skills/`:
  - `readeck-plugin-dev` - the feedback loop: `mise run check`, `mise run e2e`
    (headless KOReader + disposable local Readeck), local Readeck, live probes.
  - `koreader-manual-testing` - drive the real emulator GUI with `tools/kodrive`
    (screenshots, taps, text selection).
  - `forgejo-ci` - the pipeline on http://n:3000/tomas/readeck.koplugin and
    `tools/ci-logs`.
- Gate: `mise run check` for every change, plus `mise run e2e` for anything
  touching sync, network, auth, annotations or UI.
- `READECK_URL`/`READECK_TOKEN` in the environment point at the user's
  production server. Tests and tools never use them; don't point anything that
  writes at them without explicit permission.
