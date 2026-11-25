#!/bin/bash
# Films the README's demo clip: the UI test `testDemoWalkthrough` (list, a boat selected on the map, the camera, with
# fixture data) on the reserved iPhone 18 Pro simulator, recorded with `simctl io recordVideo`. Run it under the machine
# lock, which also does the preflight; the script won't start the simulators without it:
#
#   scripts/ui-test.sh hold --wait 90 -- scripts/record-demo.sh <output.mp4>
#
# Then, for a GIF: ffmpeg -i <output.mp4> -vf "fps=12,scale=320:-1:flags=lanczos" demo.gif   (docs/DEVELOPMENT.md)
# bash 3.2 compatible (the macOS system bash).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE/.."

out=${1:?usage: scripts/record-demo.sh <output.mp4>}
case "$out" in /*) ;; *) out=$PWD/$out ;; esac
[ -d "${UITEST_LOCK_DIR:-$HOME/Library/Caches/sim-test.lock}" ] || { echo "run this through: scripts/ui-test.sh hold -- $0 <output.mp4>" >&2; exit 64; }

name="BW Test iPhone 18 Pro"
udid=$(xcrun simctl list devices available | grep -F "$name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$udid" ] || { echo "error: no simulator named '$name'; run scripts/ui-test.sh smoke once to create it" >&2; exit 1; }

dd=$(mktemp -d "${TMPDIR:-/tmp}/record-demo.XXXXXX")
rec=""
cleanup() {
  [ -z "$rec" ] || kill -INT "$rec" 2>/dev/null || true
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  rm -rf "$dd"
}
trap cleanup EXIT

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl ui "$udid" appearance light

xcodebuild build-for-testing -scheme BoatAR -destination "id=$udid" -derivedDataPath "$dd" -quiet

rm -f "$out"
xcrun simctl io "$udid" recordVideo --codec h264 --force "$out" &
rec=$!
sleep 2
TEST_RUNNER_BOATAR_DEMO=1 xcodebuild test-without-building -scheme BoatAR -destination "id=$udid" -derivedDataPath "$dd" \
  -only-testing:BoatARUITests/BoatARUITests/testDemoWalkthrough -quiet || true
sleep 1
kill -INT "$rec" 2>/dev/null || true
wait "$rec" 2>/dev/null || true
rec=""
xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
ls -l "$out"
