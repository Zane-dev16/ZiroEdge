#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DESTINATION="platform=iOS Simulator,name=ZiroEdge Validation iPhone 17 Pro,OS=26.5"
EVIDENCE_FILE="$PROJECT_DIR/docs/release-evidence/automated-ios/evidence.json"
OUTPUT_DIR="$PROJECT_DIR/test-output/release-automated"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--destination)
		DESTINATION="$2"
		shift 2
		;;
	--evidence)
		EVIDENCE_FILE="$2"
		shift 2
		;;
	--output-dir)
		OUTPUT_DIR="$2"
		shift 2
		;;
	*)
		echo "Unknown arg: $1" >&2
		echo "Usage: $0 [--destination <xcode destination>] [--evidence <json>] [--output-dir <path>]" >&2
		exit 2
		;;
	esac
done

if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)" ]]; then
	echo "Refusing to record release evidence from a dirty source tree." >&2
	exit 1
fi

mkdir -p "$(dirname "$EVIDENCE_FILE")"
EVIDENCE_DIR="$(cd "$(dirname "$EVIDENCE_FILE")" && pwd)"
EVIDENCE_FILE="$EVIDENCE_DIR/$(basename "$EVIDENCE_FILE")"
ARCHIVE_DIR="$EVIDENCE_DIR/xcresults"
rm -rf "$OUTPUT_DIR" "$ARCHIVE_DIR"
mkdir -p "$OUTPUT_DIR/xcresults" "$ARCHIVE_DIR"

PROJECT="$PROJECT_DIR/ZiroEdge.xcodeproj"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
BUILD_REVISION=$(git -C "$PROJECT_DIR" rev-parse HEAD)
RECORDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SUITES=(
	SubmissionReadinessTests
	DownloadDiagnosticTests
	ModelMigrationTests
	DurableTransferStateTests
	StoreRecoveryTests
)

BUILD_COMMAND=(
	xcodebuild build-for-testing
	-project "$PROJECT"
	-scheme ZiroEdge
	-destination "$DESTINATION"
	-derivedDataPath "$DERIVED_DATA"
	CODE_SIGN_IDENTITY=
	CODE_SIGNING_REQUIRED=NO
	CODE_SIGNING_ALLOWED=NO
)
printf '%q ' "${BUILD_COMMAND[@]}" >"$OUTPUT_DIR/build-command.txt"
printf '\n' >>"$OUTPUT_DIR/build-command.txt"
"${BUILD_COMMAND[@]}" | tee "$OUTPUT_DIR/build.log"

SUITES_TSV="$OUTPUT_DIR/suites.tsv"
: >"$SUITES_TSV"
overall_exit=0
for suite in "${SUITES[@]}"; do
	result_bundle="$OUTPUT_DIR/xcresults/$suite.xcresult"
	command=(
		xcodebuild test-without-building
		-project "$PROJECT"
		-scheme ZiroEdge
		-destination "$DESTINATION"
		-derivedDataPath "$DERIVED_DATA"
		-resultBundlePath "$result_bundle"
		CODE_SIGN_IDENTITY=
		CODE_SIGNING_REQUIRED=NO
		CODE_SIGNING_ALLOWED=NO
		-only-testing:"ZiroEdgeTests/$suite"
	)
	printf -v command_text '%q ' "${command[@]}"
	exit_code=0
	"${command[@]}" | tee "$OUTPUT_DIR/$suite.log" || exit_code=$?
	outcome=pass
	if [[ "$exit_code" -ne 0 ]]; then
		outcome=fail
		overall_exit=1
	fi
	archive="$ARCHIVE_DIR/$suite.xcresult.tar"
	archive_hash=""
	archive_relative="xcresults/$suite.xcresult.tar"
	if [[ -d "$result_bundle" ]]; then
		COPYFILE_DISABLE=1 tar -cf "$archive" -C "$(dirname "$result_bundle")" "$(basename "$result_bundle")"
		archive_hash=$(shasum -a 256 "$archive" | awk '{print $1}')
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$outcome" "$exit_code" "$archive_hash" "$command_text" "$archive_relative" >>"$SUITES_TSV"
done

BUILT_PLIST=$(find "$DERIVED_DATA/Build/Products" -path '*/ZiroEdge.app/Info.plist' -print -quit)
BUILT_CATALOG_VERSION=""
if [[ -n "$BUILT_PLIST" ]]; then
	BUILT_CATALOG_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ModelCatalogVersion' "$BUILT_PLIST" 2>/dev/null || true)
fi
EXPECTED_CATALOG_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ModelCatalogVersion' "$PROJECT_DIR/Config/Info.plist" 2>/dev/null || true)

python3 - "$EVIDENCE_FILE" "$RECORDED_AT" "$BUILD_REVISION" "$DESTINATION" "$OUTPUT_DIR/build-command.txt" "$SUITES_TSV" "$BUILT_PLIST" "$BUILT_CATALOG_VERSION" "$EXPECTED_CATALOG_VERSION" <<'PY'
import json
import sys
from pathlib import Path

(
    evidence_path,
    recorded_at,
    revision,
    destination,
    build_command_file,
    suites_file,
    built_plist,
    built_version,
    expected_version,
) = sys.argv[1:]

suites = []
for line in Path(suites_file).read_text().splitlines():
    name, outcome, exit_code, archive_hash, command, archive_path = line.split("\t", 5)
    suites.append(
        {
            "name": name,
            "outcome": outcome,
            "exit_code": int(exit_code),
            "xcresult_archive_sha256": archive_hash or None,
            "xcresult_archive_path": archive_path,
            "xcodebuild_command": command.strip(),
        }
    )

record = {
    "recorded_at": recorded_at,
    "build_revision": revision,
    "source_tree_clean": True,
    "destination": destination,
    "build_xcodebuild_command": Path(build_command_file).read_text().strip(),
    "built_app_info_plist": built_plist or None,
    "expected_catalog_version": expected_version or None,
    "built_catalog_version": built_version or None,
    "unit_test_suites": suites,
}
Path(evidence_path).write_text(json.dumps(record, indent=2) + "\n")
PY

if [[ -z "$BUILT_CATALOG_VERSION" || "$BUILT_CATALOG_VERSION" != "$EXPECTED_CATALOG_VERSION" ]]; then
	echo "Built ModelCatalogVersion is missing or does not match Config/Info.plist." >&2
	overall_exit=1
fi
if ! awk -F '\t' 'NF != 6 || $2 != "pass" || $3 != 0 || $4 == "" || $5 == "" || $6 == "" { bad=1 } END { exit bad }' "$SUITES_TSV"; then
	echo "One or more named suites lack an individual passing outcome, exact command, or retained xcresult archive hash." >&2
	overall_exit=1
fi

if [[ "$overall_exit" -ne 0 ]]; then
	echo "Automated release evidence is incomplete or failing: $EVIDENCE_FILE" >&2
	exit 1
fi

echo "Automated release evidence recorded: $EVIDENCE_FILE"
