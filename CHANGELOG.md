# Changelog

All notable changes to Caff are documented here.

## Unreleased

- Added launch-readiness repository metadata, templates, CI, license, and visual proof.
- Added `IOPowerAssertionBackend` protocol and `SystemIOPowerAssertionBackend` so `PowerAssertionController` can be exercised under a fake backend in tests. Existing call sites are source-compatible because the new `init` parameter has a default value.
- Added CaffCore test coverage: dedicated suites for `PowerAssertionController`, `SafetyPolicy`, `SessionHistory`, `RemoteControlParser`, and `SessionDuration`.
- Added a closed test-development loop: `scripts/check_drift.sh` (L1 drift detection), `scripts/classify_failures.py` (failure classification by naming convention), `scripts/render_report.sh` (markdown + JSON report), `.githooks/pre-commit` (block undocumented public symbols), and `.github/workflows/test.yml` (macOS CI).
- Added `docs/knowledge/` (L0/L1/L2 module contract notes) and `docs/spec/closed-loop.md`.
- Fixed failure classifier counting each failing test twice when Swift Testing emitted both a "recorded an issue" line and a "failed after" line.

## 0.1.3 - 2026-05-29

- Added English and Simplified Chinese app UI localization.
- Removed process and workspace automatic triggers from the MVP scope.
- Fixed source install and release checksum script behavior.

## 0.1.2 - 2026-05-28

- Added Codex and Claude agent hook management.
- Documented release download and Homebrew install paths.

## 0.1.1 - 2026-05-28

- Fixed launched app delegate lifetime so the app remains active correctly.

## 0.1.0 - 2026-05-28

- Added simple release packaging and source install flow.
- Added the first public Caff app bundle path.
