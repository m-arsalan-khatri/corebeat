#!/bin/bash
# CoreBeat installer.
#
#   curl -fsSL https://raw.githubusercontent.com/m-arsalan-khatri/corebeat/main/install.sh | bash
#
# Builds the app locally with the Xcode Command Line Tools and installs it.
# Building on your own machine is deliberate: locally compiled apps are never
# quarantined, so there is no Gatekeeper warning to click through and no paid
# Apple Developer account propping the whole thing up.
#
# Works two ways on purpose. Run from a checkout it builds the working copy in
# front of it, which is what you want while developing; piped from curl there is
# no checkout, so it fetches the tarball first. Anything else would mean either
# a dev script that silently installs main, or a one-liner that cannot work.
set -euo pipefail

REPO="m-arsalan-khatri/corebeat"
APP_NAME="CoreBeat"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "CoreBeat is macOS only."

if ! /usr/bin/xcrun --find swiftc > /dev/null 2>&1; then
	say "The Xcode Command Line Tools are required but not installed."
	say "Starting the installer — rerun this command once it finishes."
	xcode-select --install > /dev/null 2>&1 || true
	exit 1
fi

# Install somewhere writable without needing sudo. CoreBeat never escalates —
# see invariant 2 — and that starts with its own installer.
if [ -w /Applications ]; then
	DEST="/Applications"
else
	DEST="$HOME/Applications"
	mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# $0 is "bash" when piped, so this is also the test for which mode we are in —
# dirname then resolves to the working directory rather than a checkout.
# Sources/main.swift is checked as well as build.sh precisely because of that:
# without it, running the one-liner from a directory that happens to contain
# some other build.sh would execute that instead.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2> /dev/null && pwd || true)"
if [ -n "$SELF" ] && [ -x "$SELF/build.sh" ] && [ -f "$SELF/Sources/main.swift" ]; then
	# Braced deliberately: bash 3.2 (what macOS ships) reads the UTF-8 bytes of
	# the ellipsis as part of the identifier, so "$SELF…" looks up a variable
	# that does not exist and set -u aborts the install.
	say "Building the checkout in ${SELF}…"
	SOURCE="$SELF"
else
	say "Fetching the source…"
	curl -fsSL "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" \
		| tar xz -C "$TMP" --strip-components=1
	SOURCE="$TMP"
fi

say "Compiling…"
# Quiet on success, but keep the log: a build failure is the most likely way
# this script fails, and "it didn't work" with no output is useless.
if ! (cd "$SOURCE" && ./build.sh) > "$TMP/build.log" 2>&1; then
	cat "$TMP/build.log" >&2
	die "Build failed — the output above should say why."
fi

# Nothing below this point is reversible, so confirm the build actually produced
# something before going near an existing install.
[ -d "$SOURCE/build/${APP_NAME}.app" ] || die "Build finished but produced no app bundle."

# Replacing a running app leaves a zombie in the menu bar, so quit it first.
# "ChipCrawl" is this app's former name — cleared out too, so upgraders do not
# end up with two identical-looking sparklines up there. Patterns are full
# bundle paths rather than bare binary names: pkill -f matches whole command
# lines, and a bare name would also match, say, an editor with the file open.
for APP in "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
	"ChipCrawl.app/Contents/MacOS/ChipCrawl"; do
	if pgrep -f "$APP" > /dev/null 2>&1; then
		pkill -f "$APP" || true
		sleep 1
	fi
done

# The old name is removed rather than left running: a paused process is resumed
# by the app's own SIGTERM handler above, so this is safe by the time we get
# here, and leaving it installed means two menu bar items doing the same job.
for DIR in "${DEST:?}" "${HOME:?}/Applications"; do
	rm -rf "${DIR:?}/ChipCrawl.app"
done

say "Installing…"
rm -rf "${DEST:?}/${APP_NAME}.app"
cp -R "$SOURCE/build/${APP_NAME}.app" "$DEST/"
open "$DEST/${APP_NAME}.app"

printf '\n\033[1;32mInstalled.\033[0m Look for the trace in your menu bar.\n'
printf 'It needs a minute of watching before it can tell you what changed.\n\n'
