#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_FILE="${POLICY_FILE:-$ROOT_DIR/policies/trading-policy.v1.json}"
PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-$ROOT_DIR/policies/dev-private.pem}"
SIGNATURE_FILE="${SIGNATURE_FILE:-$ROOT_DIR/policies/trading-policy.v1.sig}"
META_FILE="${META_FILE:-$ROOT_DIR/policies/trading-policy.v1.meta.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-file)
      POLICY_FILE="$2"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY_FILE="$2"
      shift 2
      ;;
    --signature-file)
      SIGNATURE_FILE="$2"
      shift 2
      ;;
    --meta-file)
      META_FILE="$2"
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
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "private key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$SIGNATURE_FILE")"
mkdir -p "$(dirname "$META_FILE")"

openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" -out "$SIGNATURE_FILE" "$POLICY_FILE"

POLICY_SHA="$(
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$POLICY_FILE" | awk '{print $1}'
  else
    shasum -a 256 "$POLICY_FILE" | awk '{print $1}'
  fi
)"

python3 - "$META_FILE" "$POLICY_FILE" "$SIGNATURE_FILE" "$POLICY_SHA" <<'PY'
import json
import os
import pathlib
import sys
from datetime import datetime, timezone

meta_file = pathlib.Path(sys.argv[1])
policy_file = sys.argv[2]
signature_file = sys.argv[3]
policy_sha = sys.argv[4]

payload = {
    "signedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "policyFile": policy_file,
    "signatureFile": signature_file,
    "policySha256": policy_sha,
}

with open(meta_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "policy_sign_ok=true"
echo "policy_file=$POLICY_FILE"
echo "policy_signature=$SIGNATURE_FILE"
echo "policy_meta=$META_FILE"
