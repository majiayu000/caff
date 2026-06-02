#!/usr/bin/env bash
# check_drift.sh — flag public symbols in Sources/CaffCore/ that are not
# documented in docs/knowledge/L1_modules.md.
#
# Usage:
#   scripts/check_drift.sh                  # full check, exit 1 if drift
#   scripts/check_drift.sh --changed        # only .swift files in git diff
#
# Maintenance: when a new public symbol is added, edit L1_modules.md (and/or
# add it to the L1_BASELINE list below) so the warning goes away.
#
# Notes:
#   - Pure POSIX-ish bash, no associative arrays, no mapfile. macOS bash 3.2
#     compatible.
#   - Coarse regex: catches public struct/class/enum/protocol and public
#     func/init/static func at the top level. L1 documents public API at the
#     type level, so this is sufficient for drift detection.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/Sources/CaffCore"
L1_FILE="$REPO_ROOT/docs/knowledge/L1_modules.md"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "error: $SRC_DIR not found" >&2
    exit 2
fi
if [[ ! -f "$L1_FILE" ]]; then
    echo "error: $L1_FILE not found" >&2
    exit 2
fi

CHANGED_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --changed) CHANGED_ONLY=1 ;;
        -h|--help)
            sed -n '3,22p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/extracted.txt"
LIST_OF_FILES="$WORK/files.txt"
> "$EXTRACTED"
> "$LIST_OF_FILES"

# Decide which .swift files to scan.
if [[ $CHANGED_ONLY -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "error: --changed requires a git repo" >&2
        exit 2
    fi
    {
        git -C "$REPO_ROOT" diff --name-only -- 'Sources/CaffCore/*.swift' 2>/dev/null || true
        git -C "$REPO_ROOT" diff --cached --name-only -- 'Sources/CaffCore/*.swift' 2>/dev/null || true
        git -C "$REPO_ROOT" ls-files --others --exclude-standard -- 'Sources/CaffCore/*.swift' 2>/dev/null || true
    } | sort -u | grep -E '\.swift$' > "$LIST_OF_FILES"
    if [[ ! -s "$LIST_OF_FILES" ]]; then
        echo "no changed CaffCore .swift files; nothing to check"
        exit 0
    fi
else
    # All CaffCore swift files.
    ls "$SRC_DIR"/*.swift | sed "s|^$REPO_ROOT/||" > "$LIST_OF_FILES"
fi

# Extract public top-level symbols: "<rel_path>:<Name>".
# Use awk so we avoid BSD sed parentheses/pipe interactions.
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    f="$REPO_ROOT/$rel"
    [[ -f "$f" ]] || continue

    awk -v rel="$rel" '
        function ident(s) {
            # Strip everything after the first non-identifier char
            # (e.g. trailing ":", "<", "(", etc.).
            n = split(s, _, "[^A-Za-z0-9_]")
            return _[1]
        }
        # public struct/class/enum/protocol Name
        /^public[[:space:]]+(struct|class|enum|protocol)[[:space:]]+[A-Z][A-Za-z0-9_]*/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "struct" || $i == "class" || $i == "enum" || $i == "protocol") {
                    print rel ":" ident($(i+1))
                    break
                }
            }
            next
        }
        # public func Name / public static func Name / public init
        /^public[[:space:]]+(static[[:space:]]+)?(func|init)[[:space:]]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "func" || $i == "init") {
                    print rel ":" ident($(i+1))
                    break
                }
            }
        }
    ' "$f" >> "$EXTRACTED" 2>/dev/null || true
done < "$LIST_OF_FILES"

# Sorted unique names extracted from sources.
EXTRACTED_NAMES="$WORK/names.txt"
sed -E 's|^[^:]+:||' "$EXTRACTED" | sort -u > "$EXTRACTED_NAMES"

# Sorted unique identifiers appearing in L1 (strip code fences and backticks first).
L1_NAMES="$WORK/l1_names.txt"
sed -E 's/```[^`]*```//g' "$L1_FILE" \
    | tr -cs 'A-Za-z0-9_' '\n' \
    | sort -u > "$L1_NAMES"

# Baseline: symbols that are deliberately undocumented in L1 (e.g., trivial
# accessors the regex catches but the L1 table doesn't enumerate by name).
# Add a name here ONLY if it is genuinely not worth documenting in L1.
L1_BASELINE_RAW='
PowerAssertionKind
PowerAssertionError
AgentHookTarget
AgentHookChange
AgentHookManagerError
AgentHookManager
RemoteControlError
RemoteControlParser
AgentActivityState
AgentActivityEvaluation
AgentActivityTouch
AgentActivityCooldown
SessionDuration
RemainingTimeFormatter
SessionHistoryResult
SessionHistoryEntry
PowerSourceState
SafetyPolicyError
SafetyPolicy
PowerSourceMonitor
SessionOptions
SessionSource
WakeSession
'
BASELINE_NAMES="$WORK/baseline_names.txt"
printf '%s' "$L1_BASELINE_RAW" | tr -d ' ' | grep -E '^[A-Z][A-Za-z0-9_]+$' | sort -u > "$BASELINE_NAMES"

# Known = (L1 names) union (baseline names).
KNOWN="$WORK/known.txt"
cat "$L1_NAMES" "$BASELINE_NAMES" | sort -u > "$KNOWN"

# Missing = extracted names minus known.
MISSING="$WORK/missing.txt"
comm -23 "$EXTRACTED_NAMES" "$KNOWN" > "$MISSING"

TOTAL=$(wc -l < "$EXTRACTED_NAMES" | tr -d ' ')
NUM_MISSING=$(wc -l < "$MISSING" | tr -d ' ')

echo "scanned $TOTAL public symbol(s) across $(wc -l < "$LIST_OF_FILES" | tr -d ' ') file(s)"

if [[ "$NUM_MISSING" -eq 0 ]]; then
    echo "drift: clean ✅"
    exit 0
fi

echo "drift: $NUM_MISSING public symbol(s) not in L1_modules.md or baseline:"
# Show file:line for each missing name by joining back with EXTRACTED.
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    grep -E ":${name}$" "$EXTRACTED" | head -3 | sed 's/^/  - /'
done < "$MISSING"
echo
echo "Fix: add the symbol to docs/knowledge/L1_modules.md (or update the"
echo "     L1_BASELINE list in scripts/check_drift.sh if it is intentionally"
echo "     undocumented)."
exit 1
