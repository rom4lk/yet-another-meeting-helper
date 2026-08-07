#!/usr/bin/env bash
# Regenerates the Xcode project, builds the app, and restarts it.
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="Debug"
if [ "${1:-}" = "--release" ]; then
  CONFIGURATION="Release"
fi

if [ ! -f Config/LocalSigning.xcconfig ]; then
  echo "error: Config/LocalSigning.xcconfig is missing." >&2
  echo "Copy Config/LocalSigning.xcconfig.example and put your Apple Developer team ID in it." >&2
  exit 1
fi

echo "==> Generating MeetingHelper.xcodeproj"
xcodegen generate

echo "==> Building ($CONFIGURATION)"
xcodebuild \
  -project MeetingHelper.xcodeproj \
  -scheme MeetingHelper \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  -allowProvisioningUpdates \
  -quiet \
  build

echo "==> Restarting MeetingHelper"
pkill -x MeetingHelper 2>/dev/null || true

# LaunchServices keeps the old instance registered slightly longer than the process itself
# lives, and activating that dying registration fails with error -600. Waiting for the
# process to disappear is not enough, so retry the launch until the registration clears.
for attempt in $(seq 1 20); do
  if open ".build/Build/Products/$CONFIGURATION/MeetingHelper.app" 2>/dev/null; then
    exit 0
  fi
  sleep 0.25
done

echo "error: could not launch MeetingHelper." >&2
open ".build/Build/Products/$CONFIGURATION/MeetingHelper.app"
