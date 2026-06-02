#!/usr/bin/env bash
# render_report.sh — run swift test and produce docs/reports/<date>.md
#
# Usage:
#   scripts/render_report.sh           # run tests and write today's report
#   scripts/render_report.sh --collect # only render from an existing log
#
# Output:
#   docs/reports/<YYYY-MM-DD>/log.txt
#   docs/reports/<YYYY-MM-DD>/summary.json
#   docs/reports/<YYYY-MM-DD>/report.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

TODAY="$(date +%Y-%m-%d)"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
REPORT_DIR="$REPO_ROOT/docs/reports/$TODAY"
LOG_FILE="$REPORT_DIR/log.txt"
SUMMARY_FILE="$REPORT_DIR/summary.json"
REPORT_FILE="$REPORT_DIR/report.md"

mkdir -p "$REPORT_DIR"

COLLECT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --collect) COLLECT_ONLY=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ $COLLECT_ONLY -eq 0 ]]; then
    echo "running: swift test --parallel" >&2
    set +e
    swift test --parallel 2>&1 | tee "$LOG_FILE"
    SWIFT_EXIT=${PIPESTATUS[0]}
    set -e
else
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "error: $LOG_FILE not found for --collect" >&2
        exit 2
    fi
    SWIFT_EXIT=0
fi

# Parse log into a summary. Log format from swift test is lines like:
#   ✔ Test foo() passed after 0.001 seconds.
#   ✘ Test bar() failed after 0.002 seconds with 1 issue.
#   ✘ Test baz() recorded an issue at Path.swift:10:5: ...
TOTAL=$(grep -cE '^(✔|✘) Test [^()]+\(' "$LOG_FILE" || true)
PASSED=$(grep -cE '^✔ Test [^()]+\(' "$LOG_FILE" || true)
FAILED=$(grep -cE '^✘ Test [^()]+\(' "$LOG_FILE" || true)

# Pull out the failing test names for the report. macOS ships bash 3.2 (no mapfile),
# so use a temp file and a here-string read loop.
FAILING_TESTS_TMP="$(mktemp)"
trap 'rm -f "$FAILING_TESTS_TMP"' EXIT
grep -E '^✘ Test ' "$LOG_FILE" | sed -E 's/^✘ Test ([^(]+).*/\1/' > "$FAILING_TESTS_TMP" || true
FAILING_TESTS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && FAILING_TESTS+=("$line")
done < "$FAILING_TESTS_TMP"

# Classify failing tests by naming convention. Output is a small JSON file
# that we then merge into summary.json. See scripts/classify_failures.py.
CLASSIFY_FILE="$REPORT_DIR/classify.json"
python3 "$REPO_ROOT/scripts/classify_failures.py" --in "$LOG_FILE" --out "$CLASSIFY_FILE" \
    >/dev/null 2>&1 || echo '{}' > "$CLASSIFY_FILE"

# Try to extract the run-summary line. swift test may print it as either
#   "Test run with 74 tests passed after 0.005 seconds."
# or, when stderr is interleaved,
#   "✔ Test run with 74 tests passed after 0.005 seconds."
RUN_LINE=$(grep -E 'Test run with .* tests? ' "$LOG_FILE" | tail -1 | sed -E 's/^[✔✘] //' || true)
[[ -z "$RUN_LINE" ]] && RUN_LINE="(no summary line found)"

# Write a small JSON summary. Use python3 for safe JSON encoding.
python3 -c '
import json, sys
summary_path, classify_path = sys.argv[1], sys.argv[2]
total, passed, failed, exit_code, run_line = sys.argv[3:8]
with open(summary_path, "w", encoding="utf-8") as f:
    body = {
        "total": int(total),
        "passed": int(passed),
        "failed": int(failed),
        "exit_code": int(exit_code),
        "run_line": run_line,
    }
    try:
        with open(classify_path, "r", encoding="utf-8") as cf:
            cls = json.load(cf)
        body["failures_by_class"] = cls.get("failures_by_class", {})
        body["failures_grouped"] = cls.get("failures_grouped", {})
    except (OSError, ValueError):
        body["failures_by_class"] = {}
        body["failures_grouped"] = {}
    json.dump(body, f, indent=2, ensure_ascii=False)
' "$SUMMARY_FILE" "$CLASSIFY_FILE" "$TOTAL" "$PASSED" "$FAILED" "$SWIFT_EXIT" "$RUN_LINE"


# Render the markdown report.
{
    echo "# Caff Test Report — $TODAY $TIMESTAMP"
    echo
    echo "**Result:** $([[ $SWIFT_EXIT -eq 0 ]] && echo "✅ PASS" || echo "❌ FAIL (exit $SWIFT_EXIT)")"
    echo
    echo "**Summary:** $RUN_LINE"
    echo
    echo "**Counts:** total=$TOTAL passed=$PASSED failed=$FAILED"
    echo
    if [[ ${#FAILING_TESTS[@]} -gt 0 && ${FAILING_TESTS[0]} != "" ]]; then
        echo "## Failing tests"
        echo
        for t in "${FAILING_TESTS[@]}"; do
            echo "- \`$t\`"
        done
        echo
        # Failures by class (from classify_failures.py).
        if [[ -s "$CLASSIFY_FILE" ]]; then
            echo "## Failures by class"
            echo
            echo '```json'
            cat "$CLASSIFY_FILE"
            echo
            echo '```'
            echo
        fi
    fi
    echo "## Artifacts"
    echo
    echo "- Raw log: \`docs/reports/$TODAY/log.txt\`"
    echo "- JSON summary: \`docs/reports/$TODAY/summary.json\`"
} > "$REPORT_FILE"

echo >&2
echo "wrote:" >&2
echo "  $LOG_FILE" >&2
echo "  $SUMMARY_FILE" >&2
echo "  $REPORT_FILE" >&2

exit "$SWIFT_EXIT"
