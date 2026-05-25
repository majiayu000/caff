# Caff

Caff is a small macOS menu bar app that keeps the machine awake while long-running agent tasks are active.

It uses the official IOKit power assertion API:

- `PreventUserIdleSystemSleep` keeps macOS from sleeping because the user is idle.
- `NoDisplaySleepAssertion` is optional and keeps the display awake when enabled.

## Current Scope

This MVP implements an idle-sleep/display-sleep assertion controller and a menu bar UI. It does not claim reliable lid-closed operation on every MacBook setup. Lid-close behavior depends on hardware, power, external display state, and macOS policy, so it should be validated separately before treating it as production behavior.

## Run

```bash
swift run caff
```

## Build an App Bundle

```bash
./scripts/build_app.sh
open dist/Caff.app
```

The generated app opens a small control window and also keeps a `CAFF` menu bar item.
The menu includes `Show Caff` if the window is closed.

## Status Proof

When a wake session is active, Caff shows:

- session source, currently `Manual`
- active assertion types
- assertion reason
- start time
- remaining time for timed sessions

The first agent-first trigger should reuse this proof model instead of adding a separate on/off state.

## Naming

`Caff` is intentionally short and CLI-friendly. It keeps the connection to macOS `caffeinate` without using the generic name `Cafe`.

## Verify

```bash
swift run caff-core-checks
swift build
```
