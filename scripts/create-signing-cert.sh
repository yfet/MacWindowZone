#!/usr/bin/env bash
set -euo pipefail

# Creates a self-signed code-signing identity in a dedicated keychain.
#
# Why: ad-hoc signatures are identified by the binary's hash, which changes
# on every build, so macOS forgets the Accessibility permission each time.
# Signed with a stable certificate, the app's designated requirement becomes
# "this identifier + this certificate" and the permission survives rebuilds.
#
# The identity lives in its own keychain (not the login keychain), unlocked
# with an empty password and with codesign pre-authorised, so builds never
# prompt. Trade-off: any process running as you can sign with it — the same
# exposure as clicking "Always Allow" for codesign on a login-keychain key.
# Nothing leaves this Mac.
#
# Remove later with:  security delete-keychain "$HOME/Library/Keychains/macwindowzone-signing.keychain-db"
# (that also drops it from the keychain search list)

NAME="${MWZ_SIGN_IDENTITY:-MacWindowZone Local Signing}"
KEYCHAIN="${MWZ_SIGN_KEYCHAIN:-$HOME/Library/Keychains/macwindowzone-signing.keychain-db}"
OPENSSL=/usr/bin/openssl   # system LibreSSL: its PKCS#12 output imports cleanly

# codesign only finds identities in keychains on the user search list.
ensure_on_search_list() {
    if ! security list-keychains -d user | grep -qF "$KEYCHAIN"; then
        echo "▶ Adding $KEYCHAIN to the keychain search list..."
        eval "security list-keychains -d user -s $(security list-keychains -d user | tr -d '\n') \"\$KEYCHAIN\""
    fi
}

if [ -f "$KEYCHAIN" ] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    ensure_on_search_list
    echo "✓ Signing identity '$NAME' already exists in $KEYCHAIN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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
EOF

echo "▶ Generating self-signed code-signing certificate '$NAME'..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Throwaway password, only for the hand-off to `security import`.
export P12_PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout env:P12_PASS

echo "▶ Creating dedicated keychain $KEYCHAIN..."
[ -f "$KEYCHAIN" ] || security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "" "$KEYCHAIN"

echo "▶ Importing identity (codesign pre-authorised)..."
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null

ensure_on_search_list

echo "✓ Created '$NAME'. Rebuild with ./scripts/build-app.sh"
