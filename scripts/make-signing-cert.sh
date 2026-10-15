#!/bin/zsh
# Creates a personal, self-signed code-signing certificate ("RematchBridge Code Signing")
# in your login keychain. build.sh signs with it automatically when it exists.
#
# Why: ad-hoc signed builds get a new identity on every build, so macOS forgets the
# Accessibility permission after each update. Builds signed with the same certificate
# keep it. The private key never leaves your keychain.
set -euo pipefail
NAME="RematchBridge Code Signing"
# macOS's own openssl (LibreSSL). Homebrew's OpenSSL 3 writes PKCS#12 files with
# algorithms the macOS keychain can't import ("MAC verification failed").
OPENSSL=/usr/bin/openssl
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your keychain."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf"
PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" \
  -passout "pass:$PASS" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
security find-certificate -c "$NAME" >/dev/null
echo "Created \"$NAME\". Run ./build.sh to sign with it."
