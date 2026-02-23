#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/external-replay}"
ARTIFACT="${ARTIFACT:-}"
SHA_FILE="${SHA_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)
      ARTIFACT="$2"
      shift 2
      ;;
    --sha-file)
      SHA_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$ARTIFACT" ]]; then
  ARTIFACT="$(ls -1t "$ROOT_DIR"/build/safety-case/safety-case-*.tar.gz 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$SHA_FILE" && -n "$ARTIFACT" ]]; then
  SHA_FILE="${ARTIFACT}.sha256"
fi

if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
  echo "artifact not found (use --artifact): $ARTIFACT" >&2
  exit 1
fi
if [[ -z "$SHA_FILE" || ! -f "$SHA_FILE" ]]; then
  echo "sha file not found (use --sha-file): $SHA_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
mkdir -p "$RUN_DIR"
REPORT_FILE="$RUN_DIR/external-replay-demo.json"

if command -v sha256sum >/dev/null 2>&1; then
  EXPECTED_SHA="$(awk '{print $1}' "$SHA_FILE")"
  ACTUAL_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
else
  EXPECTED_SHA="$(awk '{print $1}' "$SHA_FILE")"
  ACTUAL_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
fi

if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "artifact sha mismatch" >&2
  exit 1
fi

MANIFEST_REL="$(tar -tzf "$ARTIFACT" | grep -E '(^|/)manifest\.json$' | head -n 1 || true)"
if [[ -z "$MANIFEST_REL" ]]; then
  echo "manifest.json not found in artifact" >&2
  exit 1
fi

tar -xzf "$ARTIFACT" -C "$RUN_DIR" "$MANIFEST_REL"

python3 - "$ARTIFACT" "$RUN_DIR/$MANIFEST_REL" "$REPORT_FILE" "$EXPECTED_SHA" <<'PY'
import json
import tarfile
import pathlib
import sys
from datetime import datetime, timezone

artifact = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2]).resolve()
report_path = pathlib.Path(sys.argv[3]).resolve()
artifact_sha = sys.argv[4]

with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)

with tarfile.open(artifact, "r:gz") as tf:
    names = set(tf.getnames())

missing = []
for evidence in manifest.get("evidence", []):
    if evidence not in names:
        missing.append(evidence)

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(missing) == 0,
    "artifact": str(artifact),
    "artifact_sha256": artifact_sha,
    "manifest_path": str(manifest_path),
    "git_commit": manifest.get("git_commit"),
    "evidence_count": len(manifest.get("evidence", [])),
    "missing_evidence": missing,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
with open(report_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

DEMO_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "external_replay_demo_report=${REPORT_FILE}"
echo "external_replay_demo_ok=${DEMO_OK}"

if [[ "${DEMO_OK}" != "true" ]]; then
  exit 1
fi
