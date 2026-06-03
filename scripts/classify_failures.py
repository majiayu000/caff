#!/usr/bin/env python3
"""
classify_failures.py — categorize failing tests by naming convention.

Borrowed from aitest-kit's failure-class taxonomy but adapted to Swift
Testing's naming style. The classifier is rule-based on the test name:
it does not read the test body. That keeps it deterministic and cheap,
at the cost of misclassifying a few cases. The trade-off is documented
in docs/knowledge/L2_equivalence_classes.md.

Usage:
    classify_failures.py <log_file>        # print JSON to stdout
    classify_failures.py --in <log> --out <json>
    classify_failures.py --self-test       # run unit tests and exit

The seven-class taxonomy (matches aitest-kit where possible):
    EXPECTED_FAILURE    — test verifies the function rejects something;
                          failure here means a guard went missing.
    ASSERTION_FAILURE   — the real failure; the function under test did
                          the wrong thing.
    TEST_SCAFFOLD       — fixture/setup/teardown is broken.
    ENVIRONMENT_ERROR   — the test depends on a missing system resource.
    PRECONDITION_MISSING — a required env var / file is missing.
    IO_BACKEND          — failure traced to the IOKit backend.
    UNKNOWN             — fallback.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unittest
from collections import Counter
from typing import Iterable

# Order matters: more specific patterns first.
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # EXPECTED_FAILURE: the test is verifying the system rejects something.
    (
        "EXPECTED_FAILURE",
        re.compile(
            r"("
            r"Reject(s|ing|ed)?"
            r"|Refus(e|ing|ed)"
            r"|ErrorContains"
            r"|WithInvalid"
            r"|NonNumeric"
            r"|DataCorrupted"
            r"|InvalidDuration|InvalidSource|InvalidCooldown|InvalidJSON|UnsupportedRoot"
            r"|LongSessionOnBattery"
            r"|Rejects?Unrecognized|RejectsUnknown"
            r")"
        ),
    ),
    # ENVIRONMENT_ERROR: known to depend on a live system reading.
    (
        "ENVIRONMENT_ERROR",
        re.compile(
            r"("
            r"PowerSourceMonitor"
            r")"
        ),
    ),
    # IO_BACKEND: real IOKit. The real PowerAssertionController test surface
    # after Phase 5 will gain a FakeBackend suite; those names will start
    # with `fakeBackend` / `withFakeBackend` and we want them classified
    # ASSERTION_FAILURE (default) so a regression there is loud.
    (
        "IO_BACKEND",
        re.compile(
            r"("
            r"^powerAssertion(Start|Stop|IsIdempotent|Lifecycle|Inactive|AssertionsAppear)"
            r")"
        ),
    ),
]

DEFAULT_CLASS = "ASSERTION_FAILURE"
FALLBACK_CLASS = "UNKNOWN"


def extract_failing_names(log_text: str) -> list[str]:
    """Pull failing test names out of a swift test log, deduplicated.

    Recognised lines:
        ✘ Test foo() failed after 0.001 seconds with 1 issue.
        ✘ Test bar() recorded an issue at Path.swift:10:5: ...

    Swift Testing may emit two ✘ lines per failing test (one for the
    recorded issue, one for the failure summary). We dedupe while keeping
    the first-seen order so callers see one entry per failing test.
    """
    rx = re.compile(r"^✘\s+Test\s+([^(]+?)\s*\(", re.MULTILINE)
    seen: dict[str, None] = {}
    for m in rx.finditer(log_text):
        name = m.group(1).strip()
        if name not in seen:
            seen[name] = None
    return list(seen.keys())


def classify(name: str) -> str:
    for label, rx in PATTERNS:
        if rx.search(name):
            return label
    return DEFAULT_CLASS


def classify_all(names: Iterable[str]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for n in names:
        out.setdefault(classify(n), []).append(n)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("log_pos", nargs="?", help="Log file path (positional)")
    parser.add_argument("--in", dest="log", help="Log file path")
    parser.add_argument(
        "--out",
        help="Output JSON file (default: stdout)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run internal unit tests and exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        runner = unittest.TextTestRunner(verbosity=2)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestClassifier)
        result = runner.run(suite)
        return 0 if result.wasSuccessful() else 1

    log_path = args.log or args.log_pos
    if not log_path:
        print("error: log file required", file=sys.stderr)
        return 2

    with open(log_path, "r", encoding="utf-8") as f:
        log_text = f.read()

    names = extract_failing_names(log_text)
    grouped = classify_all(names)
    counts = Counter({label: len(items) for label, items in grouped.items()})

    payload = {
        "failures": names,
        "failures_by_class": dict(counts),
        "failures_grouped": grouped,
    }

    encoded = json.dumps(payload, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(encoded)
            f.write("\n")
    else:
        print(encoded)
    return 0


class TestClassifier(unittest.TestCase):
    def test_extracts_names(self) -> None:
        log = """
✔ Test a() passed after 0.001 seconds.
✘ Test foo() failed after 0.002 seconds with 1 issue.
✘ Test bar() recorded an issue at Path.swift:10:5: ...
"""
        self.assertEqual(
            extract_failing_names(log),
            ["foo", "bar"],
        )

    def test_extracts_names_dedupes_duplicate_failure_lines(self) -> None:
        # swift test may print two ✘ lines per failing test:
        #   ✘ Test foo() recorded an issue at ...
        #   ✘ Test foo() failed after ... with 1 issue.
        # We want exactly one entry per failing test, first-seen wins.
        log = """
✘ Test foo() recorded an issue at Path.swift:1:1: ...
✘ Test foo() failed after 0.001 seconds with 1 issue.
✘ Test bar() recorded an issue at Path.swift:2:2: ...
✘ Test bar() failed after 0.001 seconds with 1 issue.
"""
        self.assertEqual(
            extract_failing_names(log),
            ["foo", "bar"],
        )

    def test_extracts_names_preserves_order_across_duplicates(self) -> None:
        log = """
✘ Test z() recorded an issue at ...
✘ Test a() failed after ... with 1 issue.
✘ Test z() failed after ... with 1 issue.
"""
        # First-seen order: z, a (z's duplicate is dropped).
        self.assertEqual(
            extract_failing_names(log),
            ["z", "a"],
        )

    def test_classify_expected_failure_rejects(self) -> None:
        self.assertEqual(
            classify("remoteControlDurationRejectsZero"),
            "EXPECTED_FAILURE",
        )
        self.assertEqual(
            classify("sessionHistoryRejectsUnknownResult"),
            "EXPECTED_FAILURE",
        )
        self.assertEqual(
            classify("remoteControlSourceWithInvalidValue"),
            "EXPECTED_FAILURE",
        )

    def test_classify_expected_failure_error_keys(self) -> None:
        for n in [
            "agentHookManagerReturnsInvalidJSON",
            "agentHookManagerReturnsUnsupportedRoot",
            "remoteControlDurationInvalidDuration",
            "safetyPolicyLongSessionOnBattery",
        ]:
            self.assertEqual(
                classify(n),
                "EXPECTED_FAILURE",
                msg=f"expected EXPECTED_FAILURE for {n!r}",
            )

    def test_classify_scaffold(self) -> None:
        # AgentHookManager test names default to ASSERTION_FAILURE because
        # most of them are behavior tests, not setup tests. We document this
        # rather than carve out a TEST_SCAFFOLD bucket that would be too
        # broad and would hide real regressions.
        self.assertEqual(
            classify("agentHookManagerInstallsAndRemovesHooks"),
            "ASSERTION_FAILURE",
        )

    def test_classify_io_backend(self) -> None:
        for n in [
            "powerAssertionLifecycle",
            "powerAssertionIsIdempotentAcrossRepeatedStarts",
            "powerAssertionStartWithoutDisplaySleepOnlyAcquiresIdleAssertion",
            "powerAssertionInactiveStateHasEmptyActiveAssertions",
        ]:
            self.assertEqual(
                classify(n),
                "IO_BACKEND",
                msg=f"expected IO_BACKEND for {n!r}",
            )

    def test_classify_default(self) -> None:
        # A safety policy happy-path test name should NOT match any pattern
        # other than the default ASSERTION_FAILURE.
        self.assertEqual(
            classify("safetyPolicyAtBatteryThresholdEdgeAccepts59Minutes"),
            "ASSERTION_FAILURE",
        )

    def test_classify_all(self) -> None:
        names = [
            "remoteControlDurationRejectsZero",
            "powerAssertionLifecycle",
            "agentHookManagerInstallsAndRemovesHooks",
            "safetyPolicySomeTest",
        ]
        grouped = classify_all(names)
        self.assertIn("EXPECTED_FAILURE", grouped)
        self.assertIn("IO_BACKEND", grouped)
        self.assertIn("ASSERTION_FAILURE", grouped)
        # AgentHookManager behavior test is now ASSERTION_FAILURE, not
        # a separate scaffold bucket.
        self.assertIn("agentHookManagerInstallsAndRemovesHooks",
                      grouped["ASSERTION_FAILURE"])

    def test_payload_counts_each_failure(self) -> None:
        names = [
            "remoteControlDurationRejectsZero",
            "remoteControlDurationRejectsNegative",
            "powerAssertionLifecycle",
        ]
        grouped = classify_all(names)
        counts = Counter({label: len(items) for label, items in grouped.items()})
        self.assertEqual(counts["EXPECTED_FAILURE"], 2)
        self.assertEqual(counts["IO_BACKEND"], 1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
