#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${TMP_DIR:-$ROOT_DIR/build/policy-smoke}}"
POLICY_FILE="${POLICY_FILE:-$ROOT_DIR/policies/trading-policy.v1.json}"
PRIVATE_KEY_FILE="$OUT_DIR/dev-private.pem"
PUBLIC_KEY_FILE="$OUT_DIR/dev-public.pem"
SIGNATURE_FILE="$OUT_DIR/trading-policy.v1.sig"
META_FILE="$OUT_DIR/trading-policy.v1.meta.json"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/policy-smoke-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/policy-smoke-latest.json"

mkdir -p "$OUT_DIR"

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

python3 - "$REPORT_FILE" "$POLICY_FILE" "$SIGNATURE_FILE" "$PUBLIC_KEY_FILE" "$PRIVATE_KEY_FILE" "$META_FILE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "policy_file": sys.argv[2],
    "signature_file": sys.argv[3],
    "public_key_file": sys.argv[4],
    "private_key_file": sys.argv[5],
    "meta_file": sys.argv[6],
}
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "policy_smoke_ok=true"
echo "policy_smoke_private_key=$PRIVATE_KEY_FILE"
echo "policy_smoke_public_key=$PUBLIC_KEY_FILE"
echo "policy_smoke_signature=$SIGNATURE_FILE"
echo "policy_smoke_meta=$META_FILE"
echo "policy_smoke_report=$REPORT_FILE"
echo "policy_smoke_latest=$LATEST_FILE"
