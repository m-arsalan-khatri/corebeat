#!/bin/bash
# What CI runs, and what to run before committing.
#
# A menu bar app needs a logged-in GUI session, so the app itself cannot be
# clicked here. Everything short of clicking is covered: the compiler runs with
# warnings as errors, tools/verify exercises the sampler, the change detector
# and the resume guarantee against this machine's real process table, and
# tools/menudump builds the actual menu from a real sample.
set -euo pipefail

cd "$(dirname "$0")"

SOURCES=(
	Sources/Sampling.swift
	Sources/Diagnosis.swift
	Sources/KnownCauses.swift
	Sources/Interventions.swift
	Sources/StatusBar.swift
	Sources/main.swift
)
# Everything except main.swift, whose top-level code is its own entry point and
# cannot be linked into the test tools.
LIB=("${SOURCES[@]:0:5}")
# The behaviour tests are AppKit-free, so they take everything but StatusBar.
HEADLESS=("${SOURCES[@]:0:4}")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> shell"
if command -v shellcheck > /dev/null; then
	shellcheck build.sh test.sh install.sh
	echo "shellcheck clean"
else
	for script in build.sh test.sh install.sh; do bash -n "$script"; done
	echo "shellcheck not installed; syntax-checked only"
fi

echo
echo "==> compile, warnings as errors"
swiftc \
	-swift-version 6 \
	-target arm64-apple-macos13.0 \
	-warnings-as-errors \
	-framework AppKit \
	-framework ServiceManagement \
	-o "$TMP/app" \
	"${SOURCES[@]}"
echo "no warnings"

echo
echo "==> behaviour"
swiftc -swift-version 6 -target arm64-apple-macos13.0 -warnings-as-errors \
	-o "$TMP/verify" "${HEADLESS[@]}" tools/verify/main.swift
"$TMP/verify"

echo
echo "==> menu"
swiftc -swift-version 6 -target arm64-apple-macos13.0 -warnings-as-errors \
	-framework AppKit -framework ServiceManagement \
	-o "$TMP/menudump" "${LIB[@]}" tools/menudump/main.swift
"$TMP/menudump" > "$TMP/menu.txt" || { cat "$TMP/menu.txt"; exit 1; }
tail -3 "$TMP/menu.txt"

echo
echo "==> bundle"
./build.sh > /dev/null
BUNDLE="build/CoreBeat.app"
test -x "$BUNDLE/Contents/MacOS/CoreBeat" || { echo "missing executable"; exit 1; }
codesign --verify --strict "$BUNDLE"
# LSUIElement is what keeps it out of the Dock and the app switcher; without it
# the app is a different product.
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$BUNDLE/Contents/Info.plist" | grep -q true \
	|| { echo "LSUIElement missing — the app would show a Dock icon"; exit 1; }
lipo -archs "$BUNDLE/Contents/MacOS/CoreBeat" | grep -q x86_64 \
	|| { echo "not universal"; exit 1; }
echo "bundle ok: $(lipo -archs "$BUNDLE/Contents/MacOS/CoreBeat")"

echo
echo "all tests passed"
