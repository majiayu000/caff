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

## Process Trigger

Caff can watch a configurable comma-separated list of process names or bundle identifiers.
The default list is `codex, claude, node, python, cargo, swift`.
When a matching process exists, Caff starts a process-sourced keep-awake session and shows the triggering process in the status proof.
When no match remains, Caff keeps the session alive for the configured grace period before stopping it.

## Workspace Trigger

Caff can watch configured workspace paths for deterministic activity signals:

- `.git/index.lock`
- recently modified regular files

Workspace triggers are opt-in and require explicit paths. When activity stops, Caff keeps the session alive for the configured grace period before stopping it.

## Notifications and History

Notifications are opt-in. When enabled, Caff can notify on session start, stop, timeout, policy stop, and errors.
Local history is stored in Application Support and records source, reason, duration, assertion kinds, timestamps, and result.
History starts empty and can be cleared from the menu or control window.

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
