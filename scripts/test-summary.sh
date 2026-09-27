#!/usr/bin/env bash
#
# Summarize an xcodebuild .xcresult test run as a markdown table.
#
# Usage: scripts/test-summary.sh [path/to/TestResults.xcresult]
#   path defaults to build/TestResults.xcresult (what `make test` writes).
#
# The table goes to $GITHUB_STEP_SUMMARY when set, otherwise to stdout; under
# Actions each failure is also an ::error:: annotation on stdout.
#
# Expected counts XCTExpectFailure tests, which xcresulttool counts as neither
# passed nor failed; without the column a run carrying known failures reads as
# unqualified green. The sum check flags any state the table does not name.
#
# Exit status says only whether the summary could be produced.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE="${1:-build/TestResults.xcresult}"

if [[ ! -d "$BUNDLE" ]]; then
    echo "error: no result bundle at '$BUNDLE' — run \`make test\` first" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq not found — install with: brew install jq" >&2
    exit 1
fi

# Xcode 16+ spelling; nothing here builds with an older Xcode.
SUMMARY="$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json)"

emit() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        cat >>"$GITHUB_STEP_SUMMARY"
    else
        cat
    fi
}

emit <<EOF
$(jq -r '
  def plural(n; word): "\(n) \(word)\(if n == 1 then "" else "s" end)";
  "### " + (if .result == "Passed" then "✅" else "❌" end) + " " + .result
  + " — " + plural(.totalTestCount; "test")
  + " in " + ((.finishTime - .startTime) | . * 10 | round / 10 | tostring) + "s"
  + "\n\n"
  + "| ✅ Passed | ❌ Failed | ⏭️ Skipped | 🔶 Expected | Total |\n"
  + "| --------: | --------: | ---------: | ----------: | ----: |\n"
  + "| \(.passedTests) | \(.failedTests) | \(.skippedTests) | \(.expectedFailures // 0) | \(.totalTestCount) |\n"
  + (if ((.passedTests + .failedTests + .skippedTests + (.expectedFailures // 0)) != .totalTestCount) then
      "\n> ⚠️ The counts above do not sum to the total — xcresulttool reported a state this table does not name.\n"
    else "" end)
  + (if (.testFailures | length) > 0 then
      "\n#### Failures\n\n"
      + "| Test | Message |\n| --- | --- |\n"
      + ([.testFailures[]
          | "| `\(.targetName)/\(.testIdentifierString // .testName)` | "
            + ((.failureText // "") | gsub("\\|"; "\\\\|") | gsub("\n"; " ")) + " |"]
         | join("\n"))
      + "\n"
    else "" end)
' <<<"$SUMMARY")
EOF

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    jq -r '.testFailures[]?
      | "::error title=\(.targetName)/\(.testIdentifierString // .testName)::"
        + ((.failureText // "test failed") | gsub("\n"; "%0A"))' <<<"$SUMMARY"
fi
