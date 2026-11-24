#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

osascript -e 'tell application id "dev.spikdoum.app" to quit' 2>/dev/null || true
osascript -e 'tell application id "dev.speakhelper.app" to quit' 2>/dev/null || true
for i in {1..20}; do pgrep -x SpikDoum >/dev/null || break; sleep 0.25; done
pkill -TERM -x SpikDoum 2>/dev/null || true
pkill -TERM -x SpeakHelper 2>/dev/null || true
sleep 0.3

swift build -c release
APP="$PWD/dist/SpikDoum.app"
if [[ ! -d "$APP/Contents/Resources/ManagedRuntime" ]]; then
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    if [[ -d ".worker-build/SpeakerWorker" ]]; then ditto .worker-build/SpeakerWorker "$APP/Contents/Resources/SpeakerWorker"; fi
    if [[ -d ".runtime-build/bin" ]]; then mkdir -p "$APP/Contents/Resources/ManagedRuntime"; ditto .runtime-build/bin "$APP/Contents/Resources/ManagedRuntime"; fi
    cp Resources/ManagedRuntimeNotice.md "$APP/Contents/Resources/ManagedRuntime/"
    cp Models/speaker.onnx "$APP/Contents/Resources/"
    cp worker/NOTICE.md "$APP/Contents/Resources/"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpikDoum "$APP/Contents/MacOS/SpikDoum.new"
mv -f "$APP/Contents/MacOS/SpikDoum.new" "$APP/Contents/MacOS/SpikDoum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_IDENTITY="${SPIKDOUM_SIGN_IDENTITY:-${SPEAKHELPER_SIGN_IDENTITY:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    if security find-identity -v -p codesigning | grep -Fq '"SpikDoum Dev"'; then
        SIGN_IDENTITY="SpikDoum Dev"
    elif security find-identity -v -p codesigning | grep -Fq '"SpeakHelper Dev"'; then
        SIGN_IDENTITY="SpeakHelper Dev"
    elif APPLE_DEV="$(security find-identity -v -p codesigning | grep -m1 'Apple Development:' | sed -E 's/.*"([^"]+)".*/\1/')" && [[ -n "$APPLE_DEV" ]]; then
        SIGN_IDENTITY="$APPLE_DEV"
    else
        SIGN_IDENTITY="-"
    fi
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Signed with: $SIGN_IDENTITY"
open "$APP"
