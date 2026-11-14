#!/bin/bash
# Creates a self-signed code signing certificate called "Perch Local Signing" in
# the login keychain. build.sh signs Perch with it, so macOS remembers permissions
# such as Accessibility between builds. The certificate is valid only on this Mac
# and nobody else trusts it. To undo, delete it in Keychain Access.
set -euo pipefail
NAME="Perch Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "✓ \"$NAME\" already exists"
    exit 0
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

# The system LibreSSL writes a PKCS#12 file that the macOS keychain accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)" # protects only the temporary file below
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASSWORD" -out "$WORK/identity.p12"
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "✓ Created \"$NAME\". build.sh signs with it from now on."
