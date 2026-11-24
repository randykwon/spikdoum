#!/bin/zsh
set -euo pipefail

CERT_NAME="${SPIKDOUM_SIGN_IDENTITY:-SpikDoum Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "\"$CERT_NAME\""; then
    echo "이미 유효한 코드 서명 인증서가 있습니다: $CERT_NAME"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 \
    -config "$TMP_DIR/openssl.cnf" \
    -extensions v3_codesign 2>/dev/null

# Use macOS Keychain-compatible PKCS#12 encryption across LibreSSL and OpenSSL 3.
P12_PASS="$(uuidgen)"
if openssl version | grep -qi "OpenSSL 3"; then
    openssl pkcs12 -export -legacy \
        -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
        -passout "pass:$P12_PASS" -out "$TMP_DIR/cert.p12"
else
    openssl pkcs12 -export \
        -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
        -passout "pass:$P12_PASS" -out "$TMP_DIR/cert.p12"
fi

security import "$TMP_DIR/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
echo "macOS 키체인 신뢰 확인 창이 뜨면 Touch ID 또는 로그인 암호로 승인해 주세요..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$CERT_NAME\""
echo "완료: $CERT_NAME 코드 서명 인증서가 준비되었습니다."
