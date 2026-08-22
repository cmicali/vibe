#!/usr/bin/env bash
#
# Summarize an xcodebuild .xcresult test run as a markdown table.
#
# Usage: scripts/test-summary.sh [path/to/TestResults.xcresult]
#   path defaults to build/TestResults.xcresult (what `make test` writes).
#
# The table goes to $GITHUB_STEP_SUMMARY when set (the run's summary page),
# otherwise to stdout. Under Actions each failure is also emitted as an
# ::error:: annotation, which is why the table never goes to stdout there.
#
# The Expected column is XCTExpectFailure tests — a known-failing test pinning
# an open bug. It is its own column because it is neither passed nor failed and
# xcresulttool counts it in neither: leaving it out made the four numbers not
# add up (946 + 0 + 0 against a total of 948) with nothing on the page saying
# why, so a run carrying known failures read as unqualified green. The sum check
# below is what keeps that from happening again for some later state.
#
# Exit status reflects only whether the summary could be produced — the test
# run's own pass/fail is `make test`'s to report.
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

# `get test-results summary` is Xcode 16+. The pre-16 spelling needs --legacy
# and a different schema; the deployment floor here is Xcode 26, so no fallback.
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

# Annotations: surfaced on the run's summary page and against the PR.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    jq -r '.testFailures[]?
      | "::error title=\(.targetName)/\(.testIdentifierString // .testName)::"
        + ((.failureText // "test failed") | gsub("\n"; "%0A"))' <<<"$SUMMARY"
fi
