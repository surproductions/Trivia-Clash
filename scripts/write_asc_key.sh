#!/usr/bin/env bash
# Writes the App Store Connect API key from $ASC_KEY_P8 to the location altool
# and xcodebuild look in, accepting any of these secret formats:
#   1. full PEM text (-----BEGIN PRIVATE KEY----- ...)
#   2. base64 of the full PEM file
#   3. just the base64 key body (PEM without header/footer lines)
# Prints the key path. Never echoes key material.
set -euo pipefail
: "${ASC_KEY_ID:?}" "${ASC_KEY_P8:?}"
dir="$HOME/.appstoreconnect/private_keys"
mkdir -p "$dir" "$HOME/private_keys"
key="$dir/AuthKey_${ASC_KEY_ID}.p8"

if printf '%s' "$ASC_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then
  printf '%s\n' "$ASC_KEY_P8" > "$key"
else
  body=$(printf '%s' "$ASC_KEY_P8" | tr -d ' \r\n\t')
  decoded=$(printf '%s' "$body" | base64 --decode 2>/dev/null | head -c 40 || true)
  if printf '%s' "$decoded" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s' "$body" | base64 --decode > "$key"
  else
    { echo "-----BEGIN PRIVATE KEY-----"; printf '%s\n' "$body" | fold -w 64; echo "-----END PRIVATE KEY-----"; } > "$key"
  fi
fi
chmod 600 "$key"
cp "$key" "$HOME/private_keys/"
openssl pkey -in "$key" -noout 2>/dev/null && echo "ASC key: valid EC private key" >&2 || { echo "ASC key: could not parse" >&2; exit 1; }
echo "$key"
