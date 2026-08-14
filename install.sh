#!/bin/bash
# Builds from source and installs to /Applications.
#
# Building on your machine rather than shipping a binary is deliberate: locally
# built apps are never quarantined, so there is no Gatekeeper warning and no
# paid Apple Developer account needed to distribute this.
set -euo pipefail

APP_NAME="CoreBeat"
DEST="/Applications/${APP_NAME}.app"

if ! command -v swiftc > /dev/null; then
	echo "Xcode Command Line Tools are required. Install them with:"
	echo "  xcode-select --install"
	exit 1
fi

cd "$(dirname "$0")"
./build.sh

# A running copy cannot be replaced in place.
if pgrep -x CoreBeat > /dev/null; then
	echo "Quitting the running copy…"
	pkill -x CoreBeat || true
	sleep 1
fi

# This app was called ChipCrawl until the rename. An old copy is a different
# bundle id and a different executable name, so it survives everything above
# and sits in the menu bar next to the new one looking identical. Stopped, but
# not deleted — removing something from /Applications is the user's call.
STALE="/Applications/ChipCrawl.app"
if pgrep -x ChipCrawl > /dev/null; then
	echo "Quitting ChipCrawl, the previous name for this app…"
	pkill -x ChipCrawl || true
	sleep 1
fi

rm -rf "$DEST"
cp -R "build/${APP_NAME}.app" "$DEST"
open "$DEST"

echo
echo "Installed to $DEST and launched."
echo "Look for the CPU trace in your menu bar."
if [ -d "$STALE" ]; then
	echo
	echo "$STALE is still there from before the rename. Drag it to the Bin —"
	echo "nothing here uses it any more."
fi
