#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/safety-case"
RUN_CHECKS=false
RUN_EXTENDED_CHECKS=false
UPLOAD_MINIO=false
MINIO_ALIAS="local"
MINIO_URL="http://localhost:29002"
MINIO_ACCESS_KEY="minio"
MINIO_SECRET_KEY="minio123"
MINIO_BUCKET="exchange-archive"
PROVE_DETERMINISM_RUNS="${PROVE_DETERMINISM_RUNS:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --run-checks)
      RUN_CHECKS=true
      shift
      ;;
    --run-extended-checks)
      RUN_EXTENDED_CHECKS=true
      shift
      ;;
    --upload-minio)
      UPLOAD_MINIO=true
      shift
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
REPORTS_DIR="$RUN_DIR/reports"
CHECK_SUMMARY="$RUN_DIR/check-summary.tsv"

mkdir -p "$REPORTS_DIR"
: >"$CHECK_SUMMARY"

relpath() {
  python3 - "$1" "$2" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
    return
  fi
  shasum -a 256 "$file"
}

run_cmd() {
  local name="$1"
  shift
  local logfile="$REPORTS_DIR/$name.log"
  echo "running=$name"
  if "$@" >"$logfile" 2>&1; then
    echo "result=$name:pass"
    echo "${name}	pass	$(relpath "$ROOT_DIR" "$logfile")" >>"$CHECK_SUMMARY"
    return 0
  fi
  echo "result=$name:fail"
  echo "${name}	fail	$(relpath "$ROOT_DIR" "$logfile")" >>"$CHECK_SUMMARY"
  return 1
}

if [[ "$RUN_CHECKS" == "true" ]]; then
  run_cmd "buf-lint" buf lint
  run_cmd "buf-generate" buf generate
  run_cmd "cargo-test" cargo test -p trading-core
  run_cmd "go-test" go test ./...
  run_cmd "gradle-test" ./gradlew test
  run_cmd "load-smoke" ./scripts/load_smoke.sh
  run_cmd "dr-rehearsal" ./scripts/dr_rehearsal.sh
  run_cmd "invariants" ./scripts/invariants.sh
fi

if [[ "$RUN_EXTENDED_CHECKS" == "true" ]]; then
  run_cmd "exactly-once-stress" ./scripts/exactly_once_stress.sh
  run_cmd "reconciliation-smoke" ./scripts/smoke_reconciliation_safety.sh
  run_cmd "chaos-replay" ./scripts/chaos_replay.sh
  run_cmd "prove-determinism" env RUNS="${PROVE_DETERMINISM_RUNS}" ./scripts/prove_determinism.sh
  run_cmd "prove-breakers" ./scripts/prove_breakers.sh
fi

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if command -v go >/dev/null 2>&1; then
  GO_VERSION="$(go version)"
else
  GO_VERSION="unknown"
fi
if command -v rustc >/dev/null 2>&1; then
  RUST_VERSION="$(rustc --version)"
else
  RUST_VERSION="unknown"
fi
if command -v java >/dev/null 2>&1; then
  JAVA_VERSION="$(java -version 2>&1 | head -n 1)"
else
  JAVA_VERSION="unknown"
fi

declare -a REQUIRED_EVIDENCE=(
  "build/load/load-smoke.json"
  "build/dr/dr-report.json"
  "build/invariants/ledger-invariants.json"
)

declare -a OPTIONAL_EXTENDED_EVIDENCE=(
  "build/exactly-once/exactly-once-stress.json"
  "build/reconciliation/smoke-reconciliation-safety.json"
  "build/chaos/chaos-replay.json"
  "build/ws/ws-smoke.json"
  "build/determinism/prove-determinism-latest.json"
  "build/breakers/prove-breakers-latest.json"
)

declare -a EVIDENCE_FILES=()
for file in "${REQUIRED_EVIDENCE[@]}"; do
  if [[ ! -f "$ROOT_DIR/$file" ]]; then
    echo "missing required evidence: $file"
    exit 1
  fi
  EVIDENCE_FILES+=("$file")
done

for file in "${OPTIONAL_EXTENDED_EVIDENCE[@]}"; do
  if [[ -f "$ROOT_DIR/$file" ]]; then
    EVIDENCE_FILES+=("$file")
    continue
  fi
  if [[ "$RUN_EXTENDED_CHECKS" == "true" ]]; then
    echo "missing extended evidence after --run-extended-checks: $file"
    exit 1
  fi
done

MANIFEST="$RUN_DIR/manifest.json"
python3 - "$MANIFEST" "$TS" "$COMMIT" "$BRANCH" "$GO_VERSION" "$RUST_VERSION" "$JAVA_VERSION" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$CHECK_SUMMARY" "${EVIDENCE_FILES[@]}" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
generated_at = sys.argv[2]
git_commit = sys.argv[3]
git_branch = sys.argv[4]
go_version = sys.argv[5]
rust_version = sys.argv[6]
java_version = sys.argv[7]
run_checks = sys.argv[8].lower() == "true"
run_extended_checks = sys.argv[9].lower() == "true"
check_summary = sys.argv[10]
evidence_files = sys.argv[11:]

checks = []
with open(check_summary, "r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        parts = raw.split("\t")
        if len(parts) != 3:
            continue
        checks.append({"name": parts[0], "status": parts[1], "log": parts[2]})

manifest = {
    "generated_at_utc": generated_at,
    "git_commit": git_commit,
    "git_branch": git_branch,
    "checks": {
        "run_checks": run_checks,
        "run_extended_checks": run_extended_checks,
        "results": checks,
    },
    "build_metadata": {
        "go_version": go_version,
        "rust_version": rust_version,
        "java_version": java_version,
    },
    "evidence": evidence_files,
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
cp "$MANIFEST" "$OUT_DIR/manifest.json"

ARTIFACT_BASENAME="safety-case-${COMMIT:0:12}-${TS_ID}"
TARBALL="$OUT_DIR/${ARTIFACT_BASENAME}.tar.gz"
MANIFEST_REL="$(relpath "$ROOT_DIR" "$MANIFEST")"
REPORTS_REL="$(relpath "$ROOT_DIR" "$REPORTS_DIR")"
CHECK_SUMMARY_REL="$(relpath "$ROOT_DIR" "$CHECK_SUMMARY")"

declare -a TAR_INPUTS=("${EVIDENCE_FILES[@]}" "$MANIFEST_REL" "$REPORTS_REL" "$CHECK_SUMMARY_REL")
(
  cd "$ROOT_DIR"
  tar -czf "$TARBALL" "${TAR_INPUTS[@]}"
)

SHA_FILE="$TARBALL.sha256"
sha256_file "$TARBALL" > "$SHA_FILE"

if [[ "$UPLOAD_MINIO" == "true" ]]; then
  docker run --rm --network host minio/mc:RELEASE.2025-01-17T23-25-50Z \
    sh -c "mc alias set $MINIO_ALIAS $MINIO_URL $MINIO_ACCESS_KEY $MINIO_SECRET_KEY && \
           mc mb -p $MINIO_ALIAS/$MINIO_BUCKET >/dev/null 2>&1 || true && \
           mc cp '$TARBALL' '$MINIO_ALIAS/$MINIO_BUCKET/' && \
           mc cp '$SHA_FILE' '$MINIO_ALIAS/$MINIO_BUCKET/'"
fi

echo "safety_case_manifest=$MANIFEST"
echo "safety_case_run_dir=$RUN_DIR"
echo "safety_case_artifact=$TARBALL"
echo "safety_case_sha256=$SHA_FILE"
