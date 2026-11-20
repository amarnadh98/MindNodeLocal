#!/bin/bash
# Runs the Arbor scheme's tests, guarding against a test host that never
# exits after its tests finish. If xcodebuild is still running a grace
# period after the "Test run with" summary, the stuck processes are
# sampled into the log (so the hang can be diagnosed) and killed.
set -uo pipefail

GRACE_SECONDS="${GRACE_SECONDS:-120}"
LOG="$(mktemp -t xcodebuild-test)"

xcodebuild -scheme Arbor -destination 'platform=macOS' test >"$LOG" 2>&1 &
XCB_PID=$!
tail -f "$LOG" &
TAIL_PID=$!

finished_at=""
while kill -0 "$XCB_PID" 2>/dev/null; do
    sleep 5
    if [[ -z "$finished_at" ]] && grep -q "Test run with .* tests" "$LOG"; then
        finished_at=$(date +%s)
    fi
    if [[ -n "$finished_at" ]] && (($(date +%s) - finished_at > GRACE_SECONDS)); then
        echo "::error::xcodebuild still running ${GRACE_SECONDS}s after the tests finished; sampling"
        ps -axo pid,ppid,stat,etime,command | grep -Ei "arbor|xctest|xcodebuild" | grep -v grep
        for pid in $(pgrep -f "Arbor.app/Contents/MacOS/Arbor"); do
            echo "=== sample $pid"
            sample "$pid" 5 2>&1 | head -400
        done
        pkill -f "Arbor.app/Contents/MacOS/Arbor"
        sleep 10
        kill "$XCB_PID" 2>/dev/null
        break
    fi
done

wait "$XCB_PID"
status=$?
sleep 1
kill "$TAIL_PID" 2>/dev/null
if grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"; then
    exit 0
fi
if [[ -n "$finished_at" ]] && grep -q "✔ Test run with .* passed" "$LOG" && ! grep -q "✘" "$LOG"; then
    echo "::warning::tests passed but the test host did not exit (see the sample above)"
    exit 1
fi
exit "$status"
