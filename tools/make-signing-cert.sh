#!/bin/bash
# Create the fixed self-signed code-signing identity for OmniStats releases.
#
# macOS keys privacy grants (Accessibility, Full Disk Access, …) to the app's
# designated requirement. Signed with this certificate it is
#   identifier "io.github.suool.omnistats" and certificate leaf = H"<sha1>"
# which stays the same for every release that uses the same certificate.
#
# Usage: bash tools/make-signing-cert.sh [output-dir]   (default ~/OmniStats-signing)
#
# Keep the output directory out of the repository and back up the .p12: a new
# certificate means every user re-grants permissions once more.
set -euo pipefail

NAME="OmniStats Release"
DAYS=7300   # 20 years; renewing would change the requirement.
OUT="${1:-$HOME/OmniStats-signing}"
P12="$OUT/omnistats-release.p12"
# The system LibreSSL writes PKCS#12 files that `security import` accepts;
# OpenSSL 3 defaults (e.g. from Homebrew) can be rejected.
OPENSSL=/usr/bin/openssl

if [[ -e "$P12" ]]; then
    echo "error: $P12 already exists — refusing to replace the release identity." >&2
    exit 1
fi
umask 077
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
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
EOF

"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days "$DAYS" -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$OUT/omnistats-release.cer.pem" 2>/dev/null
PASSWORD="$("$OPENSSL" rand -base64 24)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$OUT/omnistats-release.cer.pem" \
    -out "$P12" -passout "pass:$PASSWORD"
printf '%s\n' "$PASSWORD" > "$OUT/omnistats-release.p12.password"

SHA1="$("$OPENSSL" x509 -in "$OUT/omnistats-release.cer.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
cat <<EOF
Created "$NAME" (SHA-1 $SHA1) in $OUT
  omnistats-release.p12           certificate + private key — back this up, never commit it
  omnistats-release.p12.password  its password
  omnistats-release.cer.pem       public certificate

Add the release secrets (run from the repository):
  base64 -i "$P12" | gh secret set MACOS_SIGN_P12
  gh secret set MACOS_SIGN_P12_PASSWORD < "$OUT/omnistats-release.p12.password"

Optional, to sign local builds the same way:
  security import "$P12" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -P "\$(cat "$OUT/omnistats-release.p12.password")"
  make SIGN_ID="$NAME"
EOF
