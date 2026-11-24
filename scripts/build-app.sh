#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-speaker-worker.sh
./scripts/build-managed-runtimes.sh
swift build -c release
APP="$PWD/dist/SpikDoum.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SpikDoum "$APP/Contents/MacOS/SpikDoum.new"
mv -f "$APP/Contents/MacOS/SpikDoum.new" "$APP/Contents/MacOS/SpikDoum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
ditto .worker-build/SpeakerWorker "$APP/Contents/Resources/SpeakerWorker"
mkdir -p "$APP/Contents/Resources/ManagedRuntime"
ditto .runtime-build/bin "$APP/Contents/Resources/ManagedRuntime"
cp Resources/ManagedRuntimeNotice.md "$APP/Contents/Resources/ManagedRuntime/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Models/speaker.onnx "$APP/Contents/Resources/"
cp worker/NOTICE.md "$APP/Contents/Resources/"
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
        echo "경고: 유효한 코드 서명 인증서가 없어 임시 서명(-)을 사용합니다. ./scripts/setup-signing.sh 로 인증서를 1회 설정하면 리빌드 시 권한이 유지됩니다." >&2
    fi
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Signed with: $SIGN_IDENTITY"
echo "$APP"
