#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-app.sh
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SpikDoum-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto dist/SpikDoum.app "$STAGING_DIR/SpikDoum.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname SpikDoum -srcfolder "$STAGING_DIR" -ov -format UDZO dist/SpikDoum.dmg
hdiutil verify dist/SpikDoum.dmg
