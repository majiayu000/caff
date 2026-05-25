# Caff

Caff is a small macOS menu bar app that keeps the machine awake while long-running agent tasks are active.

It uses the official IOKit power assertion API:

- `PreventUserIdleSystemSleep` keeps macOS from sleeping because the user is idle.
- `NoDisplaySleepAssertion` is optional and keeps the display awake when enabled.

## Current Scope

This MVP implements an idle-sleep/display-sleep assertion controller and a menu bar UI. It does not claim reliable lid-closed operation on every MacBook setup. Lid-close behavior depends on hardware, power, external display state, and macOS policy, so it should be validated separately before treating it as production behavior.

## Safety Policy

Caff keeps display sleep prevention opt-in and applies a visible safety policy before starting sessions:

- manual sessions are capped at 4 hours, including the "Indefinitely" action
- trigger-driven stop behavior has a 60 second grace-period setting
- long sessions are blocked while on battery unless the user explicitly enables them
- assertion and policy failures stay visible in the menu bar, menu, and control window

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
