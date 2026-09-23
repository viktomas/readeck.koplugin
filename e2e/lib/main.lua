-- Entry point: `cd $KOREADER_BUILD_DIR && ./luajit <repo>/e2e/lib/main.lua <test file>`.
-- e2e/run.sh sets up the environment (KO_HOME, READECK_LOCAL_*, E2E_*) and
-- calls this once per test file, in a fresh KOReader process.

local test_file = assert(arg[1], "usage: main.lua <test file>")
local repo = assert(os.getenv("E2E_REPO"), "E2E_REPO is required")

-- Note: READECK_URL / READECK_TOKEN from the environment are never read. The
-- harness only uses the env printed by the local server it starts itself
-- (H.fresh_server), and ReadeckApi refuses non-loopback URLs.

package.path = repo .. "/e2e/lib/?.lua;" .. package.path

local Bootstrap = require("bootstrap")
local koreader = Bootstrap.init({
    plugin_dir = assert(os.getenv("READECK_PLUGIN_DIR"), "READECK_PLUGIN_DIR is required"),
    koreader_log_level = os.getenv("E2E_KOREADER_LOG_LEVEL") or "info",
})

local H = require("harness")
H.init(koreader)

local chunk = assert(loadfile(test_file))
chunk(H)

local failures = H.run()
H.stop_server()
-- Skip KOReader's atexit handlers (SDL teardown etc.), just report.
os.exit(failures == 0 and 0 or 1)
