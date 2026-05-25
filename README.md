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

## Settings

Caff persists menu bar density and launch behavior. The menu bar can show icon-only, `CAFF`, compact countdown, or source labels, and the control window can be disabled on launch.

## Agent Launcher

Caff can launch named commands from the control window and tie the wake assertion to the child process. Built-in examples include `codex`, `claude`, `npm test`, and `cargo test`; custom commands can define an executable, arguments, working directory, and environment assignments. When a launched process exits, Caff releases the assertion and records its exit status in local history.

## CLI and URL Control

The same executable accepts `start`, `stop`, and `status` commands. `start` supports `--minutes`, `--reason`, `--display-awake`, and `--source`; `status` prints proof fields including source, assertions, reason, timestamps, display-awake state, and errors. The app bundle registers `caff://start?...` and `caff://stop` for equivalent URL-driven control.

For long-running interactive agent CLIs, `agent-touch` refreshes a last-activity cooldown without relying on the `codex` or `claude` process exiting:

```bash
caff agent-touch --source codex --cooldown-seconds 1800
```

Hook `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop` to run that command. Caff keeps the Mac awake until 30 minutes after the latest agent event, then releases the assertion so macOS can follow its normal sleep policy. The equivalent URL form is `caff://agent-touch?source=codex&cooldownSeconds=1800`.

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
swift test
swift build
swift run caff-core-checks
./scripts/build_app.sh
```
