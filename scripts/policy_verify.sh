#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_FILE="${POLICY_FILE:-$ROOT_DIR/policies/trading-policy.v1.json}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-$ROOT_DIR/policies/dev-public.pem}"
SIGNATURE_FILE="${SIGNATURE_FILE:-$ROOT_DIR/policies/trading-policy.v1.sig}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-file)
      POLICY_FILE="$2"
      shift 2
      ;;
    --public-key)
      PUBLIC_KEY_FILE="$2"
      shift 2
      ;;
    --signature-file)
      SIGNATURE_FILE="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "policy file not found: $POLICY_FILE" >&2
  exit 1
fi
if [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "public key file not found: $PUBLIC_KEY_FILE" >&2
  exit 1
fi
if [[ ! -f "$SIGNATURE_FILE" ]]; then
  echo "signature file not found: $SIGNATURE_FILE" >&2
  exit 1
fi

VERIFY_OUTPUT="$(openssl dgst -sha256 -verify "$PUBLIC_KEY_FILE" -signature "$SIGNATURE_FILE" "$POLICY_FILE" 2>&1 || true)"
if ! grep -q "Verified OK" <<<"$VERIFY_OUTPUT"; then
  echo "policy verification failed: $VERIFY_OUTPUT" >&2
  exit 1
fi

echo "policy_verify_ok=true"
echo "policy_file=$POLICY_FILE"
echo "policy_signature=$SIGNATURE_FILE"
echo "policy_public_key=$PUBLIC_KEY_FILE"
