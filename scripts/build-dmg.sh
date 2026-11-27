#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

# Build or reuse bundled runtimes (whisper-server, llama-server, SpeakerWorker)
if [[ "${SPIKDOUM_REBUILD_RUNTIMES:-0}" == "1" || ! -x ".worker-build/SpeakerWorker/SpeakerWorker" || ! -f "Models/speaker.onnx" ]]; then
    ./scripts/build-speaker-worker.sh
fi
if [[ "${SPIKDOUM_REBUILD_RUNTIMES:-0}" == "1" || ! -x ".runtime-build/bin/whisper-server" || ! -x ".runtime-build/bin/llama-server" ]]; then
    ./scripts/build-managed-runtimes.sh
fi

swift build -c release

# Refresh local dist/SpikDoum.app (preserving local dev signature for TCC on this Mac)
APP="$PWD/dist/SpikDoum.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ManagedRuntime"
cp .build/release/SpikDoum "$APP/Contents/MacOS/SpikDoum.new"
mv -f "$APP/Contents/MacOS/SpikDoum.new" "$APP/Contents/MacOS/SpikDoum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto .worker-build/SpeakerWorker "$APP/Contents/Resources/SpeakerWorker"
ditto .runtime-build/bin "$APP/Contents/Resources/ManagedRuntime"
cp Resources/ManagedRuntimeNotice.md "$APP/Contents/Resources/ManagedRuntime/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Models/speaker.onnx "$APP/Contents/Resources/speaker.onnx"
cp worker/NOTICE.md "$APP/Contents/Resources/NOTICE.md"

LOCAL_SIGN="${SPIKDOUM_SIGN_IDENTITY:-${SPEAKHELPER_SIGN_IDENTITY:-}}"
if [[ -z "$LOCAL_SIGN" ]]; then
    if security find-identity -v -p codesigning | grep -Fq '"SpikDoum Dev"'; then
        LOCAL_SIGN="SpikDoum Dev"
    elif security find-identity -v -p codesigning | grep -Fq '"SpeakHelper Dev"'; then
        LOCAL_SIGN="SpeakHelper Dev"
    else
        LOCAL_SIGN="-"
    fi
fi
codesign --force --deep --sign "$LOCAL_SIGN" "$APP"

# Stage a clean, portable copy for distribution on other Macs
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SpikDoum-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/SpikDoum.app"
ditto --norsrc "$APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

# Portability check: fail if any Mach-O binary depends on Homebrew, /usr/local, or /Users paths
NON_PORTABLE="$(find "$STAGED_APP" -type f | while read -r f; do
    if file -b "$f" | grep -q "Mach-O"; then
        otool -L "$f" | tail -n +2 | grep -E '^[[:space:]]+(/opt/homebrew|/usr/local|/Users|/Library/Frameworks)' && echo "  in: $f"
    fi
done || true)"
if [[ -n "$NON_PORTABLE" ]]; then
    echo "오류: 다른 Mac에서 동작하지 않는 비이식 라이브러리 참조가 발견되었습니다:" >&2
    echo "$NON_PORTABLE" >&2
    exit 1
fi

# Portable signing for other Macs:
# Use Developer ID Application if installed (or SPIKDOUM_DMG_SIGN_IDENTITY),
# otherwise use clean ad-hoc signing (-) rather than a machine-local self-signed dev cert.
DMG_SIGN="${SPIKDOUM_DMG_SIGN_IDENTITY:-}"
SIGN_ARGS=(--force)
if [[ -z "$DMG_SIGN" ]]; then
    DEV_ID="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application:' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    if [[ -n "$DEV_ID" ]]; then
        DMG_SIGN="$DEV_ID"
        SIGN_ARGS+=(--options runtime --timestamp)
    else
        DMG_SIGN="-"
    fi
else
    if [[ "$DMG_SIGN" == "Developer ID Application:"* ]]; then
        SIGN_ARGS+=(--options runtime --timestamp)
    fi
fi

echo "Signing staged DMG app for portability with: $DMG_SIGN"
# Sign all nested Mach-O binaries/dylibs/frameworks bottom-up first
find "$STAGED_APP/Contents/Resources" -type f | while read -r f; do
    if file -b "$f" | grep -q "Mach-O"; then
        codesign "${SIGN_ARGS[@]}" --sign "$DMG_SIGN" "$f"
    fi
done
find "$STAGED_APP/Contents/Resources" -type d -name "*.framework" | while read -r fw; do
    codesign "${SIGN_ARGS[@]}" --sign "$DMG_SIGN" "$fw"
done
codesign "${SIGN_ARGS[@]}" --sign "$DMG_SIGN" "$STAGED_APP/Contents/MacOS/SpikDoum"
codesign "${SIGN_ARGS[@]}" --sign "$DMG_SIGN" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/설치 및 처음 실행 안내.txt" <<'EOF'
SpikDoum 설치 및 다른 Mac에서 처음 실행하는 방법
================================================

[권장 환경]
- Apple Silicon Mac (M1 / M2 / M3 / M4 / M5)
- macOS 26.0 이상

[설치 방법]
1. SpikDoum.app을 Applications 폴더로 드래그해 복사합니다.
2. Applications 폴더에서 SpikDoum을 실행합니다.

[다른 Mac에서 "확인되지 않은 개발자" 또는 "열 수 없음" 경고가 뜰 때]
Apple 공증(Developer ID) 없이 배포된 로컬 빌드이므로 처음 1회만 허용이 필요합니다.

방법 1 (GUI):
  1) SpikDoum을 한 번 실행해 경고가 뜨면 '완료/취소'를 누릅니다.
  2) 시스템 설정 → 개인정보 보호 및 보안 → 아래쪽 '보안' 항목에서
     SpikDoum 옆의 [확인 없이 열기]를 클릭합니다.

방법 2 (터미널 1줄 명령 — 가장 빠름):
  xattr -dr com.apple.quarantine /Applications/SpikDoum.app

[첫 실행 시 권장 권한 허용]
- 마이크 / 음성 인식: 내 목소리 실시간 STT
- 화면 및 시스템 오디오 기록: Zoom · Meet · 유튜브 등 Mac 재생음 실시간 STT 및 강의 화면 캡처
- 자동화(PowerPoint / Keynote): 프레젠테이션 모드 슬라이드 원격 제어 및 발표자 노트 연동
EOF

rm -f dist/SpikDoum.dmg
hdiutil create \
    -volname "SpikDoum" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    dist/SpikDoum.dmg

hdiutil verify dist/SpikDoum.dmg
echo "Portable DMG built successfully: $PWD/dist/SpikDoum.dmg"
ls -lh dist/SpikDoum.dmg
