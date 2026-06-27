#!/bin/bash
# Create a persistent self-signed code-signing identity in the login keychain.
#
# Signing the app with a stable identity (instead of ad-hoc `--sign -`) keeps the
# app's "designated requirement" constant across rebuilds, so macOS TCC grants
# (Full Disk Access, Photos) survive rebuilds instead of re-prompting every time.
#
# Idempotent: does nothing if the identity already exists.
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-Downpour Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Authorize codesign to use the key without prompting. Fixes the
# `errSecInternalComponent` / repeated-prompt behavior. Needs the login keychain
# password: read interactively, or from $KEYCHAIN_PASSWORD. If neither is
# available, the first `codesign` will instead show a one-time "Always Allow"
# dialog you can click.
authorize_key() {
  local pw="${KEYCHAIN_PASSWORD:-}"
  if [[ -z "$pw" && -t 0 ]]; then
    read -r -s -p "Login keychain password (to authorize codesign, leave blank to skip): " pw
    echo
  fi
  if [[ -z "$pw" ]]; then
    echo "Skipped key authorization — the first 'make app' will show a keychain"
    echo "dialog; click \"Always Allow\"."
    return 0
  fi
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$KEYCHAIN" >/dev/null 2>&1 \
    && echo "Authorized codesign to use the signing key (no future prompts)." \
    || echo "warning: could not set key partition list (wrong password?). The first build may prompt."
}

if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "Signing identity '$IDENTITY' already exists:"
  security find-identity -p codesigning | grep -F "$IDENTITY"
  authorize_key
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

# -legacy: write 3DES/RC2 + SHA1-MAC so Apple's `security` importer can read it
# (OpenSSL 3 defaults to AES/SHA-256, which fails MAC verification on import).
P12PASS="downpour-import"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12PASS" -name "$IDENTITY" >/dev/null 2>&1

# -A lets codesign use the key without a per-build keychain prompt.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign

echo "Imported '$IDENTITY' into the login keychain."
security find-identity -p codesigning | grep -F "$IDENTITY" || {
  echo "warning: identity not listed by find-identity; signing may still work by name." >&2
}
authorize_key
