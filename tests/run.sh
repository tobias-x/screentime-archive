#!/bin/zsh
# Integration tests: runs the archiver against synthetic fixtures and checks the archive.
# Usage: tests/run.sh   (builds first if needed)
set -uo pipefail
cd "${0:A:h}/.."

[[ -x build/screentime-archiver ]] || ./build.sh >/dev/null
BIN=$PWD/build/screentime-archiver
WORK=$(mktemp -d -t screentime-tests)
trap 'rm -rf "$WORK"' EXIT
python3 -I tests/make_fixtures.py "$WORK"
export TZ=UTC

failures=0
check() {  # check <description> <expected> <sql> [archive]
    local got
    got=$(sqlite3 "${4:-$WORK/a.sqlite}" "$3")
    if [[ "$got" == "$2" ]]; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1: expected [$2] got [$got]"
        failures=$((failures + 1))
    fi
}
archive() {  # archive <archive> <biome dir>; prints exit code
    "$BIN" --archive "$1" --biome-dir "$2" --knowledge-db "$WORK/knowledgeC.db" > "$1.log" 2>&1
    echo $?
}

echo "Biome (modern) + knowledgeC local"
check "exit code" 0 "SELECT $(archive "$WORK/a.sqlite" "$WORK/biome")"
check "iPhone platform from DevicePeer" "ios|iPhone" "SELECT platform, name FROM devices WHERE device_id = '11111111-2222-3333-4444-555555555555'"
check "iPhone sessions (overlay, deleted, bad CRC, open all skipped)" \
    "com.example.alpha|1800.0
com.example.beta|1200.0" \
    "SELECT bundle_id, end_ts - start_ts FROM sessions WHERE device_id LIKE '1111%' ORDER BY start_ts"
check "hour split across boundary" \
    "com.example.alpha|10|1800.0
com.example.beta|10|600.0
com.example.beta|11|600.0" \
    "SELECT bundle_id, local_hour, seconds FROM hourly_usage WHERE device_id LIKE '1111%' ORDER BY bundle_id, local_hour"
check "local date" "2026-01-15" "SELECT DISTINCT local_date FROM hourly_usage"
check "Mac sessions (zero-length and other streams skipped)" "2|3600.0" \
    "SELECT COUNT(*), SUM(end_ts - start_ts) FROM sessions s JOIN devices d USING (device_id) WHERE d.platform = 'macos'"
check "legacy synced rows ignored when Biome has devices" 0 "SELECT COUNT(*) FROM sessions WHERE bundle_id = 'com.example.oldphone'"
check "hourly matches sessions" 1 "SELECT (SELECT SUM(seconds) FROM hourly_usage) = (SELECT SUM(end_ts - start_ts) FROM sessions)"

echo "Second run is idempotent"
check "exit code" 0 "SELECT $(archive "$WORK/a.sqlite" "$WORK/biome")"
check "no duplicate sessions" 4 "SELECT COUNT(*) FROM sessions"
check "one ok run row per device, nothing new" "2|0" "SELECT COUNT(*), SUM(sessions_new) FROM runs WHERE rowid > 2 AND status = 'ok'"

echo "Renamed devices are kept"
sqlite3 "$WORK/a.sqlite" "UPDATE devices SET name = 'My Phone' WHERE platform = 'ios'"
archive "$WORK/a.sqlite" "$WORK/biome" >/dev/null
check "name not overwritten" "My Phone" "SELECT name FROM devices WHERE platform = 'ios'"

echo "Older macOS fallback (no Biome remote devices)"
check "exit code" 0 "SELECT $(archive "$WORK/b.sqlite" "$WORK/biome-empty")" "$WORK/b.sqlite"
check "synced device from knowledgeC" "ios|iPhone14,5|1200.0" \
    "SELECT d.platform, d.os_build, SUM(end_ts - start_ts) FROM sessions s JOIN devices d USING (device_id) WHERE d.device_id LIKE 'AAAA%'" "$WORK/b.sqlite"

echo "Unsupported SEGB v1 fails cleanly"
check "exit code" 1 "SELECT $(archive "$WORK/c.sqlite" "$WORK/biome-v1")" "$WORK/c.sqlite"
check "error recorded" 1 "SELECT COUNT(*) FROM runs WHERE status = 'error' AND message LIKE '%SEGB v1%'" "$WORK/c.sqlite"
check "Mac still archived" 2 "SELECT COUNT(*) FROM sessions s JOIN devices d USING (device_id) WHERE d.platform = 'macos'" "$WORK/c.sqlite"

echo "Diagnose runs"
"$BIN" --diagnose --biome-dir "$WORK/biome" --knowledge-db "$WORK/knowledgeC.db" > "$WORK/diag.txt" 2>&1
check "reports decoded Biome sessions" 1 "SELECT $(grep -c 'sessions=2  range=' "$WORK/diag.txt")"
check "contains no bundle ids" 0 "SELECT $(grep -c 'com.example' "$WORK/diag.txt")"

echo
if (( failures )); then echo "$failures test(s) failed"; exit 1; fi
echo "All tests passed"
