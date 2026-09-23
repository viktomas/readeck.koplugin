---
name: forgejo-ci
description: This repo's CI on the user's Forgejo (http://n:3000/tomas/readeck.koplugin) - what the pipeline runs, how to push to it, list runs, read job logs (tools/ci-logs), wait for a result, and debug or change the workflow safely. Use when asked about CI, a red/green pipeline, pushing to forgejo, or editing .forgejo/workflows.
---

# Forgejo CI for readeck.koplugin

Repo: `http://n:3000/tomas/readeck.koplugin` (private), remote `forgejo`
(`ssh://fg/tomas/readeck.koplugin.git`) for pushing, remote `fgh` (HTTP) for
`fj` commands that infer the repo. General `fj` usage: skill `fj`.
Workflow: `.forgejo/workflows/ci.yml`. (`.github/workflows/ci.yml` is upstream's
GitHub CI and is not run here.)

## What runs

On every push, PR and manual dispatch, two parallel jobs:

| Job | Container | Does | Time |
| --- | --- | --- | --- |
| `lint + unit tests` | debian:trixie-slim + mise | `mise install && mise run setup && mise run check` | ~2 min (mostly building Lua 5.1) |
| `e2e` | debian:trixie-slim | downloads the KOReader **release** tarball (`KOREADER_VERSION`), runs `e2e/run.sh` with `KOREADER_BUILD_DIR=/opt/koreader/lib/koreader` across `READECK_VERSIONS` | ~3-4 min |

Versions are pinned in the workflow's top-level `env:`; bump them deliberately
and run the suite locally first
(`READECK_VERSIONS=… mise run e2e`; for a KOReader bump, extract the new tarball
and point `KOREADER_BUILD_DIR` at `<dir>/lib/koreader` - the arm64/x86_64
tarballs share a layout).

## Runner facts (why the workflow looks the way it does)

- The only general runner label is **`pi-agent`** (the @ai agent's runner,
  owner-scoped, capacity 4, 4 GB RAM, 30 min max). `container: image:` replaces
  its image with a stock one, so CI does not depend on the agent image. The
  other label, `builder`, has the podman socket and is for image builds only -
  never use it here.
- **network=host**: job containers share the host `n`'s ports. The e2e job uses
  `READECK_LOCAL_PORT=18940` (fixtures 18941) to stay clear of local defaults.
  Keep anything new inside 18900-18999.
- PID 1 in the job container is `tail -f /dev/null`, which never reaps
  orphans; killed servers become zombies. `e2e/readeck_local.py` treats zombies
  as dead (a 10 s-per-test slowdown came from this).
- There is **no cache server**: `actions/cache` would miss every time. Downloads
  are cheap on the LAN; don't add caching.
- `actions/checkout@v4` needs `nodejs` in the container (installed in the first
  step). `actions/upload-artifact@v3` is the version Forgejo supports.
- mise builds Lua 5.1 from source, hence `build-essential libreadline-dev`.
- The job runs as root; `$HOME` is `/root`.

## Push and watch

```bash
git push forgejo <branch>              # CI starts within a second or two
tools/ci-logs                          # latest runs: task id, job, status, branch, sha
tools/ci-logs wait                     # block until all jobs for HEAD finish; exit 1 if any failed
tools/ci-logs wait <sha>
tools/ci-logs <task-id>                # full log of one job
tools/ci-logs last                     # log of the newest job
tools/ci-logs <task-id> | grep -E '^(  )?(PASS|FAIL|XFAIL|XPASS|CRASH)'   # e2e results
```

Forgejo has no API for job logs and the web log route needs a browser session,
so `tools/ci-logs` reads them from the server's store over `ssh n`
(`~/backedup/forgejo/data/actions_log/tomas/readeck.koplugin/<id % 256 as hex>/<id>.log.zst`).
Run status comes from `GET /api/v1/repos/tomas/readeck.koplugin/actions/tasks`
(needs `$FORGEJO_TOKEN`, which is set). When the remote shell is fish, wrap
multi-statement commands in `bash -c`.

On an e2e failure the job prints the failing lines of `results.tsv` and the tail
of each failing file's KOReader log. The artifacts (screenshots, dialogs.txt)
are uploaded as `e2e-artifacts`; download them from the run page in the web UI.
To see a failure's screenshots locally, rerun that test locally instead:
`mise run e2e -- -k "<test name>"`.

## Changing the workflow without committing on the user's branch

Test workflow changes from a scratch clone on a throwaway branch, so nothing
lands in the user's working tree or history:

```bash
git clone -q http://n:3000/tomas/readeck.koplugin.git /tmp/cirun && cd /tmp/cirun
git checkout -b ci-wip
# copy in the working tree to test (tracked + untracked, not ignored):
(cd ~/workspace/third-party/readeck.koplugin && git ls-files -co --exclude-standard -z | xargs -0 tar -cf -) | tar -xf -
git add -A . && git -c user.name=ci -c user.email=ci@localhost commit -qm "ci wip"
git push -qf "http://tomas:$FORGEJO_TOKEN@n:3000/tomas/readeck.koplugin.git" HEAD:ci-wip
~/workspace/third-party/readeck.koplugin/tools/ci-logs wait "$(git rev-parse HEAD)"
# when done:
git push -q "http://tomas:$FORGEJO_TOKEN@n:3000/tomas/readeck.koplugin.git" --delete ci-wip
```

To probe the runner itself (what is installed, env, timings), push a tiny
workflow on such a branch with a single `run:` step.
