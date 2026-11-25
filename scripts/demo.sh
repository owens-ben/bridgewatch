#!/bin/bash
# Builds the app and launches it on a simulator with a handful of invented boats and trains, so you can look around
# without a relay, an API key or any network. The positions are around the Brooklyn waterfront and the report times
# are "now", so they stay on screen for about ten minutes (run it again for fresh ones).
#
#   scripts/demo.sh [<simulator name or UDID>]       default: iPhone 18 Pro
#
# Nothing here is live data: the boats (MMSIs 3670000xx) and the train trips are made up, and the app's location is
# pinned to the Brooklyn Bridge Park waterfront with the camera facing north-east, which is how the UI tests run it.
# For the unit and UI tests use scripts/ui-test.sh instead (docs/DEVELOPMENT.md).
#
# bash 3.2 compatible (the macOS system bash).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE/.."

target=${1:-iPhone 18 Pro}
bundle_id=com.bsowens.BoatAR
derived=build/demo

case "$target" in
  *-*-*-*-*) destination="id=$target" ;;
  *) destination="platform=iOS Simulator,name=$target" ;;
esac

echo "building for $target"
xcodebuild -scheme BoatAR -destination "$destination" -derivedDataPath "$derived" build -quiet

app=$derived/Build/Products/Debug-iphonesimulator/BoatAR.app
[ -d "$app" ] || { echo "error: $app was not built" >&2; exit 1; }

xcrun simctl boot "$target" 2>/dev/null || true
# Xcode 27.1 ships Device Hub in place of Simulator. The app runs without a window, so a failure here only warns.
if [ "${DEMO_NO_OPEN:-0}" != 1 ]; then
  open -a Simulator 2>/dev/null \
    || open "$(xcode-select -p)/../Applications/DeviceHub.app" 2>/dev/null \
    || echo "warning: found neither Simulator nor Device Hub to open; the app is launched anyway" >&2
fi
xcrun simctl bootstatus "$target" >/dev/null
xcrun simctl install "$target" "$app"

stamp() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z; }
boat() { # mmsi name shipType lat lon speed secondsAgo
  printf '{"id":"vessel:%s","kind":"vessel","source":"aisstream","name":"%s","lat":%s,"lon":%s,"speed":%s,"course":45,"timestamp":"%s","vessel":{"mmsi":%s,"shipType":%s}}' \
    "$1" "$2" "$4" "$5" "$6" "$(stamp "$7")" "$1" "$3"
}
train() { # id route direction destination lat lon altitude speed course underground
  printf '{"id":"train:demo:%s","kind":"train","source":"mta-subway","lat":%s,"lon":%s,"altitude":%s,"speed":%s,"course":%s,"timestamp":"%s","train":{"route":"%s","direction":"%s","destination":"%s","underground":%s,"altitudeEstimated":true}}' \
    "$1" "$5" "$6" "$7" "$8" "$9" "$(stamp 5)" "$2" "$3" "$4" "${10}"
}

feed='[{"type":"snapshot","targets":['
feed+=$(boat 367000001 "HARBOR LARK" 60 40.7062 -73.9931 14.2 8),
feed+=$(boat 367000002 "ANNABEL K" 52 40.7068 -73.9890 6.8 20),
feed+=$(boat 367000003 "WREN" 36 40.7054 -73.9971 4.1 30),
feed+=$(boat 367000005 "MIDNIGHT FERRY" 60 40.7010 -73.9955 9.5 12),
feed+=$(train 1 B N "145 St" 40.703181 -73.988208 34.8 24.2 337.2 false),
feed+=$(train 2 A N "Inwood-207 St" 40.692338 -73.987342 8.2 0 2.1 true)
feed+=']}]'

echo "launching with fixture data"
SIMCTL_CHILD_BOATAR_REPLAY_FEED=$feed \
SIMCTL_CHILD_BOATAR_FAKE_SENSORS="40.7046,-73.9913,36,0,5" \
  xcrun simctl launch --terminate-running-process "$target" "$bundle_id" -onboardingDone YES
