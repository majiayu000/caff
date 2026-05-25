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

## Verify

```bash
swift run caff-core-checks
swift build
```
