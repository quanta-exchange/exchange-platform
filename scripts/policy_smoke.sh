#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="${TMP_DIR:-$ROOT_DIR/build/policy-smoke}"
POLICY_FILE="${POLICY_FILE:-$ROOT_DIR/policies/trading-policy.v1.json}"
PRIVATE_KEY_FILE="$TMP_DIR/dev-private.pem"
PUBLIC_KEY_FILE="$TMP_DIR/dev-public.pem"
SIGNATURE_FILE="$TMP_DIR/trading-policy.v1.sig"
META_FILE="$TMP_DIR/trading-policy.v1.meta.json"

mkdir -p "$TMP_DIR"

openssl genpkey -algorithm RSA -out "$PRIVATE_KEY_FILE" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE" >/dev/null 2>&1

"$ROOT_DIR/scripts/policy_sign.sh" \
  --policy-file "$POLICY_FILE" \
  --private-key "$PRIVATE_KEY_FILE" \
  --signature-file "$SIGNATURE_FILE" \
  --meta-file "$META_FILE" >/dev/null

"$ROOT_DIR/scripts/policy_verify.sh" \
  --policy-file "$POLICY_FILE" \
  --public-key "$PUBLIC_KEY_FILE" \
  --signature-file "$SIGNATURE_FILE" >/dev/null

echo "policy_smoke_ok=true"
echo "policy_smoke_private_key=$PRIVATE_KEY_FILE"
echo "policy_smoke_public_key=$PUBLIC_KEY_FILE"
echo "policy_smoke_signature=$SIGNATURE_FILE"
echo "policy_smoke_meta=$META_FILE"
