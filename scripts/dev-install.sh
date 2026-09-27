#!/usr/bin/env bash
# Build, sign, and install a local parrot for testing.
#   scripts/dev-install.sh
#
# macOS keys the Accessibility and Microphone grants to the binary's code
# identity. An ad-hoc signature changes on every build, so each rebuild
# silently loses the grants. Signing with a Developer ID certificate and a
# fixed identifier keeps one identity across rebuilds.
#
# Override with PARROT_SIGN_IDENTITY, PARROT_IDENTIFIER, or PARROT_INSTALL_DIR.

set -euo pipefail

IDENTITY="${PARROT_SIGN_IDENTITY:-Developer ID Application: Andrew Jones (T4H3QX65LN)}"
IDENTIFIER="${PARROT_IDENTIFIER:-com.humanitas.parrot}"
INSTALL_DIR="${PARROT_INSTALL_DIR:-/usr/local/bin}"
# The LaunchAgent label keeps its old name until #40 replaces the agent with SMAppService.
LABEL="com.digimata.parrot"

cd "$(dirname "$0")/.."

echo "→ building"
swift build -c release

BIN=".build/release/parrot"

echo "→ signing as $IDENTIFIER"
codesign --force --timestamp=none --identifier "$IDENTIFIER" --sign "$IDENTITY" "$BIN"
codesign --verify --strict "$BIN"

echo "→ installing to $INSTALL_DIR"
SUDO=""
[ -w "$INSTALL_DIR" ] || SUDO="sudo"
$SUDO install -m 0755 "$BIN" "$INSTALL_DIR/parrot"

# Restart the LaunchAgent if one is loaded, so it runs the new build.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "→ restarting $LABEL"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
fi

echo "✓ installed $("$INSTALL_DIR/parrot" --version 2>/dev/null || echo parrot)"
