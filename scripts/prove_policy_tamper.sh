#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/policy}"
POLICY_SOURCE="${POLICY_SOURCE:-$ROOT_DIR/policies/trading-policy.v1.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --policy-file)
      POLICY_SOURCE="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$POLICY_SOURCE" ]]; then
  echo "policy file not found: $POLICY_SOURCE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/prove-policy-tamper-$TS_ID"
REPORT_FILE="$OUT_DIR/prove-policy-tamper-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-policy-tamper-latest.json"
mkdir -p "$RUN_DIR"

SIGNED_POLICY_FILE="$RUN_DIR/policy.signed.json"
cp "$POLICY_SOURCE" "$SIGNED_POLICY_FILE"

PRIVATE_KEY_FILE="$RUN_DIR/dev-private.pem"
PUBLIC_KEY_FILE="$RUN_DIR/dev-public.pem"
SIGNATURE_FILE="$RUN_DIR/policy.sig"
META_FILE="$RUN_DIR/policy.meta.json"
TAMPERED_POLICY_FILE="$RUN_DIR/policy.tampered.json"

openssl genpkey -algorithm RSA -out "$PRIVATE_KEY_FILE" -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE" >/dev/null 2>&1

"$ROOT_DIR/scripts/policy_sign.sh" \
  --policy-file "$SIGNED_POLICY_FILE" \
  --private-key "$PRIVATE_KEY_FILE" \
  --signature-file "$SIGNATURE_FILE" \
  --meta-file "$META_FILE" >/dev/null

set +e
BASE_VERIFY_OUTPUT="$(
  "$ROOT_DIR/scripts/policy_verify.sh" \
    --policy-file "$SIGNED_POLICY_FILE" \
    --public-key "$PUBLIC_KEY_FILE" \
    --signature-file "$SIGNATURE_FILE" 2>&1
)"
BASE_VERIFY_CODE=$?
set -e

cp "$SIGNED_POLICY_FILE" "$TAMPERED_POLICY_FILE"
python3 - "$TAMPERED_POLICY_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).resolve()
payload = json.loads(path.read_text(encoding="utf-8"))
if isinstance(payload, dict):
    payload["_tamper_probe"] = "modified"
else:
    payload = {"value": payload, "_tamper_probe": "modified"}
path.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n", encoding="utf-8")
PY

set +e
TAMPER_VERIFY_OUTPUT="$(
  "$ROOT_DIR/scripts/policy_verify.sh" \
    --policy-file "$TAMPERED_POLICY_FILE" \
    --public-key "$PUBLIC_KEY_FILE" \
    --signature-file "$SIGNATURE_FILE" 2>&1
)"
TAMPER_VERIFY_CODE=$?
set -e

python3 - "$REPORT_FILE" "$POLICY_SOURCE" "$SIGNED_POLICY_FILE" "$TAMPERED_POLICY_FILE" "$SIGNATURE_FILE" "$PUBLIC_KEY_FILE" "$BASE_VERIFY_CODE" "$TAMPER_VERIFY_CODE" "$BASE_VERIFY_OUTPUT" "$TAMPER_VERIFY_OUTPUT" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
policy_source = pathlib.Path(sys.argv[2]).resolve()
signed_policy = pathlib.Path(sys.argv[3]).resolve()
tampered_policy = pathlib.Path(sys.argv[4]).resolve()
signature_file = pathlib.Path(sys.argv[5]).resolve()
public_key_file = pathlib.Path(sys.argv[6]).resolve()
base_code = int(sys.argv[7])
tamper_code = int(sys.argv[8])
base_output = sys.argv[9]
tamper_output = sys.argv[10]

baseline_verify_ok = base_code == 0
tamper_detected = tamper_code != 0
ok = baseline_verify_ok and tamper_detected

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "baseline_verify_ok": baseline_verify_ok,
    "tamper_detected": tamper_detected,
    "baseline_verify_exit_code": base_code,
    "tamper_verify_exit_code": tamper_code,
    "baseline_verify_output": base_output,
    "tamper_verify_output": tamper_output,
    "policy_source": str(policy_source),
    "signed_policy_file": str(signed_policy),
    "tampered_policy_file": str(tampered_policy),
    "signature_file": str(signature_file),
    "public_key_file": str(public_key_file),
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

RESULT_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_policy_tamper_report=$REPORT_FILE"
echo "prove_policy_tamper_latest=$LATEST_FILE"
echo "prove_policy_tamper_ok=$RESULT_OK"

if [[ "$RESULT_OK" != "true" ]]; then
  exit 1
fi
