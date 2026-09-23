#!/usr/bin/env bash
# Headless end-to-end suite: the real plugin, in a real KOReader runtime,
# against a real (local, disposable) Readeck server.
#
#   e2e/run.sh                      # every e2e/tests/*_test.lua
#   e2e/run.sh sync                 # only test files whose name contains "sync"
#   e2e/run.sh -k "bad token" auth  # only tests whose name contains "bad token"
#
# Environment:
#   KOREADER_BUILD_DIR  KOReader emulator build or extracted release tarball
#                       (default: references/koreader/koreader-emulator-*/koreader)
#   READECK_VERSIONS    space-separated Readeck versions to run the suite on (default: 0.23.4)
#   READECK_LOCAL_PORT  port of the local Readeck; fixtures use port+1 (default: 18920)
#   E2E_ARTIFACTS       artifacts root (default: references/e2e-artifacts)
#   E2E_TIMEOUT         per test file timeout in seconds (default: 300)
#   E2E_SCREENSHOTS=0   skip PNG screenshots
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Never talk to whatever server the calling shell points at: the suite only
# ever uses the env of the local server the harness starts itself.
unset READECK_URL READECK_TOKEN READECK_FIXTURE_URL READECK_USER READECK_PASSWORD

name_filter=""
file_filters=()
while [ $# -gt 0 ]; do
    case "$1" in
        -k) name_filter="$2"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) file_filters+=("$1"); shift ;;
    esac
done

if [ -z "${KOREADER_BUILD_DIR:-}" ]; then
    KOREADER_BUILD_DIR="$(echo "$REPO"/references/koreader/koreader-emulator-*/koreader | awk '{print $1}')"
fi
KOREADER_BUILD_DIR="$(cd "$KOREADER_BUILD_DIR" 2>/dev/null && pwd || true)"
if [ -z "$KOREADER_BUILD_DIR" ] || [ ! -x "$KOREADER_BUILD_DIR/luajit" ] || [ ! -f "$KOREADER_BUILD_DIR/setupkoenv.lua" ]; then
    echo "No KOReader build found. Set KOREADER_BUILD_DIR to an emulator build or an extracted release" >&2
    echo "tarball (a dir with luajit, setupkoenv.lua, frontend/), or run 'mise run emulator-build'." >&2
    exit 2
fi

PYTHON="${PYTHON:-python3}"
VERSIONS="${READECK_VERSIONS:-0.23.4}"
PORT="${READECK_LOCAL_PORT:-18920}"
if [ "$PORT" -lt 18900 ] || [ "$PORT" -gt 18998 ]; then
    echo "READECK_LOCAL_PORT must be within 18900-18998 (fixtures use port+1)" >&2
    exit 2
fi
TIMEOUT="${E2E_TIMEOUT:-300}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
ARTIFACTS_ROOT="${E2E_ARTIFACTS:-$REPO/references/e2e-artifacts}"
RUN_DIR="$ARTIFACTS_ROOT/$RUN_ID"
RESULTS="$RUN_DIR/results.tsv"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/readeck-e2e.XXXXXX")"
mkdir -p "$RUN_DIR"
: > "$RESULTS"
ln -sfn "$RUN_ID" "$ARTIFACTS_ROOT/latest"

tests=()
for file in "$REPO"/e2e/tests/*_test.lua; do
    base="$(basename "$file")"
    if [ ${#file_filters[@]} -gt 0 ]; then
        keep=0
        for f in "${file_filters[@]}"; do
            case "$base" in *"$f"*) keep=1 ;; esac
        done
        [ $keep -eq 1 ] || continue
    fi
    tests+=("$file")
done
if [ ${#tests[@]} -eq 0 ]; then
    echo "No test files match: ${file_filters[*]}" >&2
    exit 2
fi

cleanup() {
    for dir in "$WORK_ROOT"/*/readeck; do
        [ -d "$dir" ] && "$PYTHON" e2e/readeck_local.py stop --dir "$dir" >/dev/null 2>&1
    done
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT
trap 'echo "interrupted" >&2; exit 130' INT TERM

# Fetch the Readeck binaries up front (including versions single tests pin
# with server_version = "...") so downloads do not count against timeouts.
pinned=$(grep -ho 'server_version = "[0-9.]*"' "${tests[@]}" | grep -o '[0-9][0-9.]*' | sort -u)
for version in $VERSIONS $pinned; do
    "$PYTHON" -c "import sys; sys.path.insert(0, 'e2e'); import readeck_local as r; r.ensure_binary('$version', None)" \
        || { echo "could not get Readeck $version" >&2; exit 2; }
done

echo "KOReader: $KOREADER_BUILD_DIR"
echo "Readeck:  $VERSIONS (port $PORT)"
echo "Artifacts: $RUN_DIR"
echo

suite_start=$(date +%s)
for version in $VERSIONS; do
    for file in "${tests[@]}"; do
        base="$(basename "$file" .lua)"
        work="$WORK_ROOT/$version-$base"
        mkdir -p "$work/home"
        log_dir="$RUN_DIR/$version"
        mkdir -p "$log_dir"
        log="$log_dir/$base.log"
        before=$(wc -l < "$RESULTS")
        printf '%-8s %-40s ' "$version" "$base"
        file_start=$(date +%s)
        (
            cd "$KOREADER_BUILD_DIR" && exec env \
                E2E_REPO="$REPO" \
                E2E_TEST_FILE="$base" \
                E2E_TEST_FILTER="$name_filter" \
                E2E_ARTIFACT_DIR="$log_dir" \
                E2E_RESULTS="$RESULTS" \
                KO_HOME="$work/home" \
                READECK_PLUGIN_DIR="$REPO/readeck.koplugin" \
                READECK_LOCAL_VERSION="$version" \
                READECK_LOCAL_PORT="$PORT" \
                READECK_LOCAL_DIR="$work/readeck" \
                PYTHON="$PYTHON" \
                ./luajit "$REPO/e2e/lib/main.lua" "$file"
        ) > "$log" 2>&1 &
        pid=$!
        # The watchdog must not hold our stdout open, or `run.sh | tail` hangs.
        ( sleep "$TIMEOUT" && kill -9 "$pid" 2>/dev/null && echo "[e2e] TIMEOUT after ${TIMEOUT}s" >> "$log" ) \
            </dev/null >/dev/null 2>&1 &
        watchdog=$!
        wait "$pid"
        status=$?
        pkill -P "$watchdog" 2>/dev/null
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        "$PYTHON" e2e/readeck_local.py stop --dir "$work/readeck" >/dev/null 2>&1
        after=$(wc -l < "$RESULTS")
        # A clean exit without results under -k just means no test in this file matched.
        if [ "$after" -eq "$before" ] && [ $status -eq 0 ] && [ -n "$name_filter" ]; then
            echo "no test matches -k ($(( $(date +%s) - file_start ))s)"
            continue
        fi
        if [ "$after" -eq "$before" ] || { [ $status -ne 0 ] && ! tail -n +"$((before + 1))" "$RESULTS" | grep -qE '^(FAIL|XPASS)'; }; then
            printf 'CRASH\t%s\t%s\t(whole file)\t0\texit status %s, see %s\n' "$version" "$base" "$status" "$log" >> "$RESULTS"
        fi
        summary=$(tail -n +"$((before + 1))" "$RESULTS" | cut -f1 | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}')
        echo "$summary($(( $(date +%s) - file_start ))s)"
    done
done

echo
echo "Results ($(( $(date +%s) - suite_start ))s total):"
awk -F'\t' '{ printf "  %-6s %-7s %-28s %-58s %5ss  %s\n", $1, $2, $3, $4, $5, $6 }' "$RESULTS"
echo
echo "Artifacts: $RUN_DIR  (screenshots, dialogs.txt and log.txt per test; <version>/<file>.log per file)"

if grep -qE '^(FAIL|XPASS|CRASH)' "$RESULTS"; then
    exit 1
fi
exit 0
