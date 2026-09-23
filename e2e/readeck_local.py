#!/usr/bin/env python3
"""Provision and run a throwaway local Readeck server for e2e and manual testing.

    e2e/readeck_local.py start [--version 0.23.4] [--port 18900] [--dir DIR] [--bin PATH]
    e2e/readeck_local.py stop  [--dir DIR]
    e2e/readeck_local.py env   [--dir DIR]          # print `export ...` lines
    e2e/readeck_local.py seed  [--dir DIR] [--count N] [--labels a,b]
    e2e/readeck_local.py approve-device --code ABCD-EFGH [--deny]   # OAuth device flow

`start` gives you, from nothing and in a few seconds:

  * a Readeck binary (a release download cached under references/readeck-bin/,
    or whatever --bin / $READECK_BIN points at - e.g. a build of ../readeck);
  * a fresh data dir, config and user (e2e / e2e-password);
  * an API token, obtained the way a person gets one: sign in on the web form
    and create a token on /profile/tokens (Readeck has no password->token API);
  * a fixture site (e2e/fixtures/server.py serving e2e/fixtures/site, plus
    generated /gen/<slug>.html articles and ?delay=N slow pages) Readeck can
    bookmark, because the config empties extractor.denied_ips so Readeck may
    fetch 127.0.0.1;
  * DIR/env, a shell file with READECK_URL, READECK_TOKEN, READECK_USER,
    READECK_PASSWORD, READECK_FIXTURE_URL, READECK_VERSION.

Everything is local and disposable. This never touches a real server.
Only the standard library is used, so it runs on a bare CI image.
"""

import argparse
import http.cookiejar
import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_CACHE = os.path.join(ROOT, "references", "readeck-bin")
FIXTURE_SITE = os.path.join(ROOT, "e2e", "fixtures", "site")
FIXTURE_SERVER = os.path.join(ROOT, "e2e", "fixtures", "server.py")
DEFAULT_DIR = os.path.join(ROOT, "references", "readeck-local")
DEFAULT_VERSION = "0.23.4"
USER = "e2e"
PASSWORD = "e2e-password"


def log(*args):
    print("[readeck-local]", *args, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Binary
# --------------------------------------------------------------------------


def release_asset_name(version):
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "arm64": "arm64", "aarch64": "arm64"}.get(machine)
    if not arch:
        raise SystemExit("unsupported architecture: " + machine)
    os_name = {"darwin": "macos", "linux": "linux"}.get(system)
    if not os_name:
        raise SystemExit("unsupported OS: " + system)
    return "readeck-%s-%s-%s" % (version, os_name, arch)


def ensure_binary(version, explicit_bin):
    if explicit_bin:
        path = os.path.abspath(explicit_bin)
        if not os.access(path, os.X_OK):
            raise SystemExit("not an executable: " + path)
        return path
    os.makedirs(BIN_CACHE, exist_ok=True)
    asset = release_asset_name(version)
    # Keyed by OS/arch too: the cache dir may be shared with a Linux container.
    path = os.path.join(BIN_CACHE, asset)
    if os.access(path, os.X_OK):
        return path
    url = "https://codeberg.org/readeck/readeck/releases/download/%s/%s" % (version, asset)
    log("downloading", url)
    tmp = path + ".part"
    with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out)
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)
    return path


def binary_version(path):
    out = subprocess.run([path, "version"], capture_output=True, text=True).stdout.strip()
    return out.split()[-1] if out else "unknown"


# --------------------------------------------------------------------------
# Processes
# --------------------------------------------------------------------------


def port_is_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def wait_for_http(url, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=2)
            return True
        except urllib.error.HTTPError:
            return True  # any HTTP answer means it is up
        except Exception:
            time.sleep(0.2)
    return False


def spawn(cmd, logfile, cwd=None):
    out = open(logfile, "ab")
    proc = subprocess.Popen(
        cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd, start_new_session=True
    )
    return proc.pid


def _alive(pid):
    """True while pid runs. A zombie counts as dead: in a CI container PID 1
    is often `tail -f /dev/null`, which never reaps orphans, so a killed
    server lingers as a zombie and `kill(pid, 0)` keeps succeeding."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True  # no procfs (macOS): kill(pid, 0) is the answer


def kill_pidfile(pidfile):
    try:
        with open(pidfile) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        os.kill(pid, signal.SIGTERM)
    # Readeck shuts down gracefully and waits for in-flight extractions (e.g.
    # a slow fixture page); it is disposable, so do not wait long for it.
    for i in range(50):
        if not _alive(pid):
            break
        if i == 10:
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        time.sleep(0.1)
    os.remove(pidfile)


# --------------------------------------------------------------------------
# Token: sign in on the web form, create a token on /profile/tokens
# --------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def web_session(base_url):
    """Sign in on the web form; returns (opener, post) sharing the session cookie."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), _NoRedirect())
    headers = {"Origin": base_url, "Content-Type": "application/x-www-form-urlencoded"}

    def post(path, fields):
        req = urllib.request.Request(
            base_url + path,
            data=urllib.parse.urlencode(fields).encode(),
            headers=headers,
            method="POST",
        )
        try:
            opener.open(req, timeout=10)
        except urllib.error.HTTPError as err:
            if err.code in (302, 303):
                return err.headers.get("Location", "")
            raise
        raise RuntimeError("expected a redirect from " + path)

    location = post("/login", {"username": USER, "password": PASSWORD})
    if "/login" in location:
        raise RuntimeError("web sign-in failed")
    return opener, post


def create_token(base_url, application="readeck.koplugin e2e"):
    opener, post = web_session(base_url)
    location = post("/profile/tokens", {"application": application})
    match = re.search(r"/profile/tokens/([A-Za-z0-9]+)", location)
    if not match:
        raise RuntimeError("token creation did not redirect to the token page: " + location)
    page = opener.open(base_url + "/profile/tokens/" + match.group(1), timeout=10).read().decode()
    token = re.search(r'value="Authorization: Bearer ([^"]+)"', page)
    if not token:
        raise RuntimeError("could not find the token on its page")
    return token.group(1)


# --------------------------------------------------------------------------
# API helpers (used by `seed`)
# --------------------------------------------------------------------------


def api(env, method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        env["READECK_URL"] + path,
        data=body,
        method=method,
        headers={
            "Authorization": "Bearer " + env["READECK_TOKEN"],
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        return resp.status, dict(resp.headers), (json.loads(raw) if raw else None)


def fixture_pages():
    pages = []
    for name in sorted(os.listdir(FIXTURE_SITE)):
        if name.endswith(".html") and name != "index.html":
            pages.append(name)
    return pages


def wait_loaded(env, bookmark_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        _, _, bm = api(env, "GET", "/api/bookmarks/" + bookmark_id)
        if bm.get("loaded") and bm.get("state") == 0:
            return bm
        if bm.get("state") == 1:
            raise RuntimeError("bookmark %s failed to load: %s" % (bookmark_id, bm.get("errors")))
        time.sleep(0.3)
    raise RuntimeError("bookmark %s never finished loading" % bookmark_id)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def read_env(state_dir):
    env = {}
    path = os.path.join(state_dir, "env")
    if not os.path.exists(path):
        raise SystemExit("no running local Readeck in %s (run `start` first)" % state_dir)
    with open(path) as f:
        for line in f:
            m = re.match(r"export (\w+)='(.*)'$", line.strip())
            if m:
                env[m.group(1)] = m.group(2)
    return env


def cmd_start(args):
    state_dir = os.path.abspath(args.dir)
    cmd_stop(args, quiet=True)
    if os.path.exists(state_dir):
        shutil.rmtree(state_dir)
    os.makedirs(os.path.join(state_dir, "data"))

    port, fixture_port = args.port, args.port + 1
    for p in (port, fixture_port):
        if not port_is_free(p):
            raise SystemExit("port %d is busy (pick another with --port)" % p)

    binary = ensure_binary(args.version, args.bin or os.environ.get("READECK_BIN"))
    version = binary_version(binary)
    base_url = "http://127.0.0.1:%d" % port
    fixture_url = "http://127.0.0.1:%d" % fixture_port

    config = os.path.join(state_dir, "config.toml")
    with open(config, "w") as f:
        f.write(
            "\n".join(
                [
                    "[main]",
                    'log_level = "%s"' % args.log_level,
                    'secret_key = "readeck-koplugin-e2e-not-a-secret-000000"',
                    'data_directory = "%s"' % os.path.join(state_dir, "data"),
                    "[server]",
                    'host = "127.0.0.1"',
                    "port = %d" % port,
                    "[database]",
                    'source = "sqlite3:%s"' % os.path.join(state_dir, "data", "db.sqlite3"),
                    "[extractor]",
                    "# Allow bookmarking the local fixture site.",
                    "denied_ips = []",
                    "",
                ]
            )
        )

    subprocess.run(
        [binary, "user", "-config", config, "-u", USER, "-p", PASSWORD, "-email", "e2e@example.com"],
        check=True,
        capture_output=True,
    )

    pid = spawn([binary, "serve", "-config", config], os.path.join(state_dir, "readeck.log"))
    with open(os.path.join(state_dir, "readeck.pid"), "w") as f:
        f.write(str(pid))
    pid = spawn(
        [sys.executable, FIXTURE_SERVER, str(fixture_port)],
        os.path.join(state_dir, "fixtures.log"),
        cwd=FIXTURE_SITE,
    )
    with open(os.path.join(state_dir, "fixtures.pid"), "w") as f:
        f.write(str(pid))

    if not wait_for_http(base_url + "/api/info") or not wait_for_http(fixture_url + "/"):
        cmd_stop(args, quiet=True)
        raise SystemExit("servers did not come up; see %s/*.log" % state_dir)

    token = create_token(base_url)
    lines = {
        "READECK_URL": base_url,
        "READECK_TOKEN": token,
        "READECK_USER": USER,
        "READECK_PASSWORD": PASSWORD,
        "READECK_FIXTURE_URL": fixture_url,
        "READECK_VERSION": version,
        "READECK_LOCAL_DIR": state_dir,
    }
    with open(os.path.join(state_dir, "env"), "w") as f:
        f.write("# Written by e2e/readeck_local.py - a disposable local server.\n")
        for key, value in lines.items():
            f.write("export %s='%s'\n" % (key, value))
    log("Readeck %s on %s (fixtures on %s), state in %s" % (version, base_url, fixture_url, state_dir))
    cmd_env(args)


def cmd_stop(args, quiet=False):
    state_dir = os.path.abspath(args.dir)
    for name in ("readeck.pid", "fixtures.pid"):
        kill_pidfile(os.path.join(state_dir, name))
    if not quiet:
        log("stopped servers in", state_dir)


def cmd_env(args):
    path = os.path.join(os.path.abspath(args.dir), "env")
    with open(path) as f:
        sys.stdout.write("".join(l for l in f if l.startswith("export ")))


def cmd_seed(args):
    env = read_env(os.path.abspath(args.dir))
    pages = fixture_pages()
    labels = [l for l in (args.labels or "").split(",") if l]
    ids = []
    for i in range(args.count):
        page = pages[i % len(pages)]
        url = "%s/%s" % (env["READECK_FIXTURE_URL"], page)
        if i >= len(pages):
            url += "?copy=%d" % i
        status, headers, _ = api(env, "POST", "/api/bookmarks", {"url": url, "labels": labels})
        bookmark_id = headers.get("Bookmark-Id")
        if status != 202 or not bookmark_id:
            raise RuntimeError("unexpected create response %s %s" % (status, headers))
        ids.append(bookmark_id)
    for bookmark_id in ids:
        wait_loaded(env, bookmark_id)
    log("seeded %d bookmark(s)" % len(ids))
    print("\n".join(ids))


def cmd_approve_device(args):
    """Approve (or deny) an OAuth device code as the signed-in web user would."""
    env = read_env(os.path.abspath(args.dir))
    _, post = web_session(env["READECK_URL"])
    fields = {"user_code": args.code, "granted": "0" if args.deny else "1"}
    location = post("/device", fields)
    log("device code %s %s -> %s" % (args.code, "denied" if args.deny else "granted", location))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--dir", default=os.environ.get("READECK_LOCAL_DIR", DEFAULT_DIR))

    p = sub.add_parser("start")
    common(p)
    p.add_argument("--version", default=os.environ.get("READECK_LOCAL_VERSION", DEFAULT_VERSION))
    p.add_argument("--port", type=int, default=int(os.environ.get("READECK_LOCAL_PORT", "18900")))
    p.add_argument("--bin", help="use this readeck binary instead of a release download")
    p.add_argument("--log-level", default="warn")
    p.set_defaults(func=cmd_start)

    p = sub.add_parser("stop")
    common(p)
    p.set_defaults(func=cmd_stop)

    p = sub.add_parser("env")
    common(p)
    p.set_defaults(func=cmd_env)

    p = sub.add_parser("seed")
    common(p)
    p.add_argument("--count", type=int, default=3)
    p.add_argument("--labels", default="")
    p.set_defaults(func=cmd_seed)

    p = sub.add_parser("approve-device")
    common(p)
    p.add_argument("--code", required=True, help="the user code shown on the device (dashes are fine)")
    p.add_argument("--deny", action="store_true")
    p.set_defaults(func=cmd_approve_device)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
